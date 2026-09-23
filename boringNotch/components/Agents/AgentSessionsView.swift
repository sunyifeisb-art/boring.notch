//
//  AgentSessionsView.swift
//  boringNotch
//

import SwiftUI
import UniformTypeIdentifiers

struct AgentSessionsView: View {
    @ObservedObject private var manager = AgentSessionManager.shared
    @State private var draft = ""
    @State private var showsDirectoryPicker = false
    @State private var showsConversation = false
    @FocusState private var composerFocused: Bool

    private var selectedClaudeSession: AgentSession? {
        manager.sessions.first {
            $0.id == manager.selectedSessionID && $0.source.lowercased() == "claude"
        }
    }

    var body: some View {
        VStack(spacing: 7) {
            sessionStrip
                .frame(height: 74)

            claudeComposer
                .frame(height: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(
            isPresented: $showsDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let directory = urls.first else { return }
            manager.sendMessage("/new", cwd: directory.path)
            composerFocused = true
        }
    }

    @ViewBuilder
    private var sessionStrip: some View {
        if manager.sessions.isEmpty {
            emptyState
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(manager.sessions) { session in
                        AgentSessionCard(
                            session: session,
                            isSelected: manager.selectedSessionID == session.id
                        )
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: manager.bridgeError == nil ? "terminal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(manager.bridgeError == nil ? .blue : .orange)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(manager.bridgeError == nil ? "Agent center" : "Agent bridge unavailable")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text(emptyStateDetail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            Button {
                manager.installHooks()
            } label: {
                HStack(spacing: 5) {
                    if manager.isInstallingHooks {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                    Text(manager.isInstallingHooks ? "Installing" : "Install hooks")
                }
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(manager.isInstallingHooks || manager.bridgeError != nil)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .secondarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyStateDetail: String {
        if let bridgeError = manager.bridgeError { return bridgeError }
        if let result = manager.hookInstallMessages.last { return result }
        return "Monitor installed agents, approve tools, or start Claude Code below."
    }

    private var claudeComposer: some View {
        HStack(spacing: 6) {
            Menu {
                Button("New conversation") { submitCommand("/new") }
                Button("New in folder…") { showsDirectoryPicker = true }
                Divider()
                Button("Clear and start over") { submitCommand("/clear") }
                    .disabled(selectedClaudeSession == nil)
                Button("Stop current run") { submitCommand("/stop") }
                    .disabled(selectedClaudeSession == nil)
                Button("Compact context") { submitCommand("/compact") }
                    .disabled(selectedClaudeSession == nil)
                Divider()
                Button("Current session") { submitCommand("/current") }
                    .disabled(selectedClaudeSession == nil)
                Button("Recent history") { showsConversation = true }
                    .disabled(selectedClaudeSession == nil)
                Button("List conversations") { submitCommand("/list") }
                    .disabled(selectedClaudeSession == nil)
                Button("Command help") { submitCommand("/help") }
                    .disabled(selectedClaudeSession == nil)
                Divider()
                Button("Install or repair hooks") { manager.installHooks() }
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 28, height: 26)
                    .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Claude Code commands")

            if let selectedClaudeSession {
                HStack(spacing: 4) {
                    Circle()
                        .fill(selectedClaudeSession.status.color)
                        .frame(width: 5, height: 5)
                    Text(selectedClaudeSession.displayName)
                        .lineLimit(1)
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 92)
            } else {
                Text("New Claude")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TextField(composerPlaceholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($composerFocused)
                .onSubmit(sendDraft)

            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(canSend ? .black : .secondary)
                    .frame(width: 25, height: 25)
                    .background(canSend ? Color.white : Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send directly to Claude Code")
        }
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .popover(isPresented: $showsConversation, arrowEdge: .bottom) {
            if let selectedClaudeSession {
                ClaudeConversationHistory(sessionID: selectedClaudeSession.id)
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerPlaceholder: String {
        selectedClaudeSession?.status == .waitingForAnswer
            ? "Answer Claude…"
            : "Message Claude Code…"
    }

    private func sendDraft() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draft = ""
        if message == "/history", selectedClaudeSession != nil {
            showsConversation = true
            return
        }
        if let selectedClaudeSession, selectedClaudeSession.status == .waitingForAnswer {
            manager.answer(selectedClaudeSession, value: message)
        } else {
            manager.sendMessage(message)
        }
        composerFocused = true
    }

    private func submitCommand(_ command: String) {
        manager.sendMessage(command)
        composerFocused = true
    }
}

private struct ClaudeConversationHistory: View {
    let sessionID: String
    @ObservedObject private var manager = AgentSessionManager.shared

    private var session: AgentSession? {
        manager.sessions.first(where: { $0.id == sessionID })
    }

    var body: some View {
        Group {
            if let session {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(session.status.color)
                            .frame(width: 6, height: 6)
                        Text(session.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(session.status.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(session.status.color)
                    }

                    Divider()

                    if session.messages.isEmpty {
                        ContentUnavailableView(
                            "No messages yet",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text(session.detail)
                        )
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 7) {
                                    ForEach(session.messages) { message in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(message.role.capitalized)
                                                .font(.system(size: 8, weight: .semibold))
                                                .foregroundStyle(messageColor(message.role))
                                            Text(message.text.isEmpty ? "…" : message.text)
                                                .font(.system(size: 10))
                                                .textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .padding(7)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                                        .id(message.id)
                                    }
                                }
                            }
                            .onAppear { scrollToLatest(session: session, using: proxy) }
                            .onChange(of: session.messages.last?.text) {
                                scrollToLatest(session: session, using: proxy)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(width: 380, height: 280)
            } else {
                ContentUnavailableView("Conversation unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    .frame(width: 380, height: 280)
            }
        }
    }

    private func messageColor(_ role: String) -> Color {
        switch role {
        case "user": return .blue
        case "assistant": return .green
        case "error": return .red
        default: return .secondary
        }
    }

    private func scrollToLatest(session: AgentSession, using proxy: ScrollViewProxy) {
        guard let identifier = session.messages.last?.id else { return }
        proxy.scrollTo(identifier, anchor: .bottom)
    }
}

private struct AgentSessionCard: View {
    let session: AgentSession
    let isSelected: Bool
    @ObservedObject private var manager = AgentSessionManager.shared
    @State private var showsConversation = false

    private var cardWidth: CGFloat { session.status.needsAttention ? 236 : 180 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(session.status.color)
                Text(session.source.capitalized)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(session.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Circle()
                    .fill(session.status.color)
                    .frame(width: 5, height: 5)
                Text(session.status.label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(session.status.color)
                    .lineLimit(1)
            }

            if session.status == .waitingForAnswer, !session.questionOptions.isEmpty {
                Text(session.questionTitle ?? "Claude needs an answer")
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(session.questionOptions.prefix(3)) { option in
                        Button(option.label) { manager.answer(session, value: option.value) }
                            .buttonStyle(AgentActionButtonStyle(prominent: true))
                    }
                }
            } else if session.status == .waitingForApproval {
                Text(session.detail)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Button("Deny") { manager.deny(session) }
                        .buttonStyle(AgentActionButtonStyle(prominent: false))
                    Button("Allow") { manager.allow(session) }
                        .buttonStyle(AgentActionButtonStyle(prominent: true))
                    Button("Always") { manager.allow(session, always: true) }
                        .buttonStyle(AgentActionButtonStyle(prominent: false))
                }
            } else {
                HStack(spacing: 6) {
                    Text(session.detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(session.elapsedLabel(at: context.date))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        manager.jumpToTerminal(session)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open terminal")
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: cardWidth, height: 72, alignment: .topLeading)
        .background(Color(nsColor: .secondarySystemFill).opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: isSelected ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            if session.source.lowercased() == "claude" {
                manager.select(session)
                showsConversation = true
            } else if !session.status.needsAttention {
                manager.jumpToTerminal(session)
            }
        }
        .popover(isPresented: $showsConversation, arrowEdge: .bottom) {
            ClaudeConversationHistory(sessionID: session.id)
        }
        .help(session.source.lowercased() == "claude" ? "Open Claude conversation" : "Open terminal")
    }

    private var borderColor: Color {
        if isSelected { return .blue.opacity(0.85) }
        if session.status.needsAttention { return session.status.color.opacity(0.55) }
        return .white.opacity(0.05)
    }

    private var sourceIcon: String {
        switch session.source.lowercased() {
        case "claude": return "c.circle.fill"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "gemini": return "sparkles"
        case "cursor": return "cursorarrow.rays"
        case "opencode": return "curlybraces.square.fill"
        default: return "terminal.fill"
        }
    }
}

private struct AgentActionButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 8, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .foregroundStyle(prominent ? .black : .white)
            .background(
                prominent ? Color.white.opacity(configuration.isPressed ? 0.72 : 0.94)
                    : Color.white.opacity(configuration.isPressed ? 0.08 : 0.14),
                in: Capsule()
            )
    }
}

struct AgentLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    let session: AgentSession

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.source.capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(session.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .frame(width: 128, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width)

            HStack(spacing: 5) {
                Image(systemName: session.status == .waitingForAnswer ? "questionmark.bubble.fill" : "hand.raised.fill")
                Text(session.status == .waitingForAnswer ? "Answer" : "Review")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(session.status.color)
            .frame(width: 74, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
    }
}
