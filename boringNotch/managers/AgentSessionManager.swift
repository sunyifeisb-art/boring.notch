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
    @Published var selectedSessionID: String?

    private var pollingTask: Task<Void, Never>?
    private var attentionSessionIDs = Set<String>()

    var attentionSession: AgentSession? {
        sessions.first(where: { $0.status.needsAttention })
    }

    var activeSessionCount: Int {
        sessions.filter { $0.status != .completed }.count
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

        let updatedAttention = Set(updatedSessions.filter { $0.status.needsAttention }.map(\.id))
        let newAttention = updatedAttention.subtracting(attentionSessionIDs)
        sessions = updatedSessions
        attentionSessionIDs = updatedAttention
        if let selectedSessionID,
           !updatedSessions.contains(where: { $0.id == selectedSessionID && $0.source.lowercased() == "claude" })
        {
            self.selectedSessionID = nil
        }

        if !newAttention.isEmpty {
            NotificationCenter.default.post(name: .agentAttentionNeeded, object: nil)
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
        let question = session.questionHeader ?? "answer"
        sendResponse(
            sessionID: session.id,
            object: [
                "hookSpecificOutput": [
                    "decision": [
                        "updatedInput": ["answers": [question: [value]]]
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

    func sendMessage(_ text: String, cwd: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let selected = sessions.first(where: { $0.id == selectedSessionID && $0.source.lowercased() == "claude" })
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
}
