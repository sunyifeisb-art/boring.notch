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
    @Published private(set) var isInstallingHooks = false
    @Published private(set) var closingSessionIDs = Set<String>()
    @Published var selectedSessionID: String?
    @Published var requestedOpenSessionID: String?

    private var pollingTask: Task<Void, Never>?
    private var attentionSessionIDs = Set<String>()

    var attentionSession: AgentSession? {
        agentSessions.first(where: { $0.status.needsAttention })
    }

    var activeSessionCount: Int {
        agentSessions.filter { $0.status != .completed }.count
    }

    var agentSessions: [AgentSession] {
        sessions.filter { ["claude", "codex"].contains($0.source.lowercased()) }
    }

    var claudeSessions: [AgentSession] {
        sessions.filter { $0.source.lowercased() == "claude" }
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
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        XPCHelperClient.shared.stopAgentBridge()
    }

    func refreshSessions() async {
        let data = await XPCHelperClient.shared.agentSessionsJSON()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let updatedSessions = try? decoder.decode([AgentSession].self, from: data) else { return }

        let previousActive = Set(agentSessions.filter { $0.status != .completed }.map(\.id))
        let updatedAgentSessions = updatedSessions.filter { ["claude", "codex"].contains($0.source.lowercased()) }
        let updatedClaudeSessions = updatedAgentSessions.filter { $0.source.lowercased() == "claude" }
        let updatedActive = Set(updatedAgentSessions.filter { $0.status != .completed }.map(\.id))
        let newActive = updatedActive.subtracting(previousActive)
        let updatedAttention = Set(updatedAgentSessions.filter { $0.status.needsAttention }.map(\.id))
        let newAttention = updatedAttention.subtracting(attentionSessionIDs)
        sessions = updatedSessions
        attentionSessionIDs = updatedAttention
        if let selectedSessionID,
           !updatedSessions.contains(where: { $0.id == selectedSessionID && $0.source.lowercased() == "claude" })
        {
            self.selectedSessionID = nil
        }

        let autoSelectNewest = UserDefaults.standard.object(forKey: "agentIslandAutoSelectNewest") as? Bool ?? true
        if autoSelectNewest,
           (selectedSessionID == nil || !newActive.isEmpty),
           let newest = updatedClaudeSessions.first(where: { $0.status != .completed })
        {
            selectedSessionID = newest.id
        }

        if !newAttention.isEmpty {
            NotificationCenter.default.post(name: .agentAttentionNeeded, object: nil)
        }
        if !newActive.isEmpty {
            NotificationCenter.default.post(name: .agentSessionStarted, object: nil)
        }
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
        Task { _ = await XPCHelperClient.shared.jumpToAgentTerminal(sessionID: session.id) }
    }

    func select(_ session: AgentSession) {
        guard session.source.lowercased() == "claude" else { return }
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

    func sendMessage(_ text: String, to sessionID: String? = nil, cwd: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let targetID = sessionID ?? selectedSessionID
        let selected = sessions.first(where: { $0.id == targetID && $0.source.lowercased() == "claude" })

        Task {
            let identifier = await XPCHelperClient.shared.sendAgentMessage(
                sessionID: selected?.id,
                source: "claude",
                cwd: selected?.cwd ?? cwd,
                message: trimmed
            )
            if let identifier { selectedSessionID = identifier }
            await refreshSessions()
        }
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
                selectedSessionID = sessions.first(where: { $0.source.lowercased() == "claude" })?.id
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
}
