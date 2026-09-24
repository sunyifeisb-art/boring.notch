//
//  AgentSessionManager.swift
//  boringNotch
//

import Foundation

@MainActor
final class AgentSessionManager: ObservableObject {
    static let shared = AgentSessionManager()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var bridgeError: String?
    @Published private(set) var hookInstallMessages: [String] = []
    @Published private(set) var codexUsage: AgentUsageSnapshot?
    @Published private(set) var isRefreshingCodexUsage = false
    @Published private(set) var isInstallingHooks = false
    @Published private(set) var closingSessionIDs = Set<String>()
    @Published var selectedSessionID: String?
    @Published var requestedOpenSessionID: String?
    @Published var terminalOpenError: String?

    private var pollingTask: Task<Void, Never>?
    private var attentionSessionIDs = Set<String>()
    private var lastBridgeRevision: UInt64?
    private var refreshInProgress = false
    private var lastAutomaticCodexUsageRefresh: Date?
    private var lastAutomaticCodexUsageSessionIDs = Set<String>()

    var attentionSession: AgentSession? {
        agentSessions.first(where: { $0.status.needsAttention })
    }

    var activeSessionCount: Int {
        agentSessions.filter { $0.status != .completed }.count
    }

    var agentSessions: [AgentSession] {
        sessions.filter { ["claude", "codex"].contains($0.source.lowercased()) }
    }

    var selectedAgentSession: AgentSession? {
        agentSessions.first(where: { $0.id == selectedSessionID })
    }

    var hookInstallSummary: String? {
        guard !hookInstallMessages.isEmpty else { return nil }
        return hookInstallMessages.joined(separator: "；")
    }

    private init() {}

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            bridgeError = await XPCHelperClient.shared.startAgentBridge()
            while !Task.isCancelled {
                await refreshSessions()
                let activeSessions = agentSessions.filter { $0.status == .active || $0.status == .inProgress }
                let interval: Int
                if activeSessions.contains(where: \.isManaged) {
                    interval = 200
                } else if !activeSessions.isEmpty {
                    interval = 350
                } else {
                    interval = 1_000
                }
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        lastBridgeRevision = nil
        sessions.removeAll(keepingCapacity: false)
        attentionSessionIDs.removeAll(keepingCapacity: false)
        selectedSessionID = nil
        requestedOpenSessionID = nil
        codexUsage = nil
        XPCHelperClient.shared.stopAgentBridge()
    }

    func refreshSessions(force: Bool = false) async {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }

        let revision = await XPCHelperClient.shared.agentSessionsRevision()
        if !force, let revision, revision == lastBridgeRevision {
            return
        }

        let data = await XPCHelperClient.shared.agentSessionsJSON()
        guard let updatedSessions = await Task.detached(priority: .utility, operation: {
            autoreleasepool {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try? decoder.decode([AgentSession].self, from: data)
            }
        }).value else { return }

        lastBridgeRevision = revision
        guard updatedSessions != sessions else { return }

        let previousChromeSignature = chromeSignature(for: sessions)
        let previousActive = Set(agentSessions.filter { $0.status != .completed }.map(\.id))
        let updatedAgentSessions = updatedSessions.filter { ["claude", "codex"].contains($0.source.lowercased()) }
        let updatedActive = Set(updatedAgentSessions.filter { $0.status != .completed }.map(\.id))
        let newActive = updatedActive.subtracting(previousActive)
        let updatedAttention = Set(updatedAgentSessions.filter { $0.status.needsAttention }.map(\.id))
        let newAttention = updatedAttention.subtracting(attentionSessionIDs)
        sessions = updatedSessions
        attentionSessionIDs = updatedAttention
        if let selectedSessionID,
           !updatedSessions.contains(where: { $0.id == selectedSessionID && ["claude", "codex"].contains($0.source.lowercased()) })
        {
            self.selectedSessionID = nil
        }

        let autoSelectNewest = UserDefaults.standard.object(forKey: "agentIslandAutoSelectNewest") as? Bool ?? true
        if autoSelectNewest,
           (selectedSessionID == nil || !newActive.isEmpty),
           let newest = updatedAgentSessions.first(where: { $0.status != .completed })
        {
            selectedSessionID = newest.id
        }

        if !newAttention.isEmpty {
            NotificationCenter.default.post(name: .agentAttentionNeeded, object: nil)
        }
        if !newActive.isEmpty {
            NotificationCenter.default.post(name: .agentSessionStarted, object: nil)
        }
        if chromeSignature(for: updatedSessions) != previousChromeSignature {
            NotificationCenter.default.post(name: .agentChromeStateChanged, object: nil)
        }
    }

    func refreshCodexUsage() {
        guard !isRefreshingCodexUsage else { return }
        isRefreshingCodexUsage = true
        Task {
            let data = await XPCHelperClient.shared.codexUsageJSON()
            codexUsage = try? JSONDecoder().decode(AgentUsageSnapshot.self, from: data)
            isRefreshingCodexUsage = false
        }
    }

    func refreshCodexUsageIfNeeded(activeSessionIDs: [String]) {
        let activeIDs = Set(activeSessionIDs)
        guard !activeIDs.isEmpty else {
            lastAutomaticCodexUsageSessionIDs.removeAll(keepingCapacity: false)
            return
        }
        guard !isRefreshingCodexUsage else { return }
        let activeTasksChanged = activeIDs != lastAutomaticCodexUsageSessionIDs
        if !activeTasksChanged,
           let lastAutomaticCodexUsageRefresh,
           Date().timeIntervalSince(lastAutomaticCodexUsageRefresh) < 5 * 60
        {
            return
        }
        lastAutomaticCodexUsageSessionIDs = activeIDs
        lastAutomaticCodexUsageRefresh = Date()
        refreshCodexUsage()
    }

    private func chromeSignature(for sessions: [AgentSession]) -> [String] {
        sessions
            .filter { ["claude", "codex"].contains($0.source.lowercased()) }
            .map { session in
                [
                    session.id,
                    session.source,
                    session.status.rawValue,
                    session.cwd ?? "",
                    session.title ?? "",
                    session.toolName ?? "",
                    session.status.needsAttention ? (session.toolInput?.displayText ?? "") : ""
                ].joined(separator: "|")
            }
            .sorted()
    }

    func installHooks() {
        guard !isInstallingHooks else { return }
        isInstallingHooks = true
        Task {
            hookInstallMessages = await XPCHelperClient.shared.installAgentHooks()
            isInstallingHooks = false
        }
    }

    func allow(_ session: AgentSession, always: Bool = false) {
        let behavior = always ? "always" : "allow"
        sendResponse(
            sessionID: session.id,
            object: ["hookSpecificOutput": ["decision": ["behavior": behavior]]]
        )
    }

    func deny(_ session: AgentSession) {
        sendResponse(
            sessionID: session.id,
            object: ["hookSpecificOutput": ["decision": ["behavior": "deny"]]]
        )
    }

    func answer(_ session: AgentSession, value: String) {
        let question = session.questionTitle ?? session.questionHeader ?? "answer"
        sendResponse(
            sessionID: session.id,
            object: [
                "hookSpecificOutput": [
                    "decision": [
                        "updatedInput": ["answers": [question: value]]
                    ]
                ]
            ]
        )
    }

    func jumpToTerminal(_ session: AgentSession) {
        terminalOpenError = nil
        Task {
            let opened = await XPCHelperClient.shared.jumpToAgentTerminal(sessionID: session.id)
            if !opened {
                terminalOpenError = "无法恢复这个 Claude Code 会话。请确认已安装 Ghostty 与 Claude Code，并允许 Boring Notch 自动化控制 Ghostty。"
            }
        }
    }

    func dismissTerminalOpenError() {
        terminalOpenError = nil
    }

    func select(_ session: AgentSession) {
        guard ["claude", "codex"].contains(session.source.lowercased()) else { return }
        selectedSessionID = session.id
    }

    func requestOpen(_ session: AgentSession) {
        select(session)
        requestedOpenSessionID = session.id
    }

    func newConversation(cwd: String? = nil, prompt: String? = nil) {
        let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmedPrompt.map { $0.isEmpty ? "/new" : "/new \($0)" } ?? "/new"
        Task {
            let identifier = await XPCHelperClient.shared.sendAgentMessage(
                sessionID: nil,
                source: "claude",
                cwd: cwd,
                message: message
            )
            if let identifier { selectedSessionID = identifier }
            await refreshSessions()
        }
    }

    func sendMessage(
        _ text: String,
        to sessionID: String? = nil,
        cwd: String? = nil,
        source preferredSource: String? = nil,
        openInIsland: Bool = false
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let targetID = sessionID ?? selectedSessionID
        let selected = sessions.first(where: {
            $0.id == targetID
                && ["claude", "codex"].contains($0.source.lowercased())
                && (preferredSource == nil || $0.source.lowercased() == preferredSource?.lowercased())
        }) ?? preferredSource.flatMap { source in
            sessions.first(where: {
                $0.source.lowercased() == source.lowercased()
                    && [.active, .inProgress, .pending, .idle].contains($0.status)
            })
        }
        let source = selected?.source.lowercased() ?? preferredSource?.lowercased() ?? "claude"

        guard source != "codex" || selected != nil else {
            bridgeError = "没有可接收文件上下文的 Codex 桌面任务。请先启动一个 Codex 任务。"
            return
        }

        Task {
            let identifier = await XPCHelperClient.shared.sendAgentMessage(
                sessionID: selected?.id,
                source: source,
                cwd: selected?.cwd ?? cwd,
                message: trimmed
            )
            if let identifier {
                selectedSessionID = identifier
                if openInIsland {
                    requestedOpenSessionID = identifier
                    BoringViewCoordinator.shared.currentView = .agents
                }
            }
            await refreshSessions()
        }
    }

    func sendShelfItemsToAgent(_ items: [ShelfItem], source: String) {
        guard !items.isEmpty else { return }
        let references = items.compactMap { item -> String? in
            switch item.kind {
            case .file:
                guard let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) else { return nil }
                return "- 文件：\(url.path)"
            case .link(let url):
                return "- 链接：\(url.absoluteString)"
            case .text(let text):
                return "- 文本：\(String(text.prefix(2_000)))"
            }
        }
        guard !references.isEmpty else { return }
        let prompt = "请查看并处理以下来自文件储存器的内容，先阅读文件或链接，再按我的要求协助：\n\n\(references.joined(separator: "\n"))"
        let preferredItem = items.first(where: { if case .file = $0.kind { return true }; return false })
        let cwd = preferredItem.flatMap { item -> String? in
            guard let url = ShelfStateViewModel.shared.resolveFileURL(for: item) else { return nil }
            return url.deletingLastPathComponent().path
        }
        sendMessage(prompt, cwd: cwd, source: source, openInIsland: true)
    }

    func close(_ session: AgentSession) {
        let sessionID = session.id
        guard !closingSessionIDs.contains(sessionID) else { return }
        closingSessionIDs.insert(sessionID)

        Task {
            _ = await XPCHelperClient.shared.closeAgentSession(sessionID: sessionID)
            await refreshSessions()
            closingSessionIDs.remove(sessionID)
            if selectedSessionID == nil {
                selectedSessionID = sessions.first(where: { ["claude", "codex"].contains($0.source.lowercased()) })?.id
            }
        }
    }

    private func sendResponse(sessionID: String, object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        Task {
            _ = await XPCHelperClient.shared.respondToAgent(sessionID: sessionID, responseJSON: data)
            await refreshSessions()
        }
    }
}

extension Notification.Name {
    static let agentAttentionNeeded = Notification.Name("agentAttentionNeeded")
    static let agentSessionStarted = Notification.Name("agentSessionStarted")
    static let agentChromeStateChanged = Notification.Name("agentChromeStateChanged")
}
