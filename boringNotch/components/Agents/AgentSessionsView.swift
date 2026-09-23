//
//  AgentSessionsView.swift
//  boringNotch
//

import SwiftUI
import UniformTypeIdentifiers

struct AgentSessionsView: View {
    @ObservedObject private var manager = AgentSessionManager.shared
    @State private var draft = ""
    @State private var detailSessionID: String?
    @State private var showsDirectoryPicker = false
    @FocusState private var composerFocused: Bool

    private var selectedClaudeSession: AgentSession? {
        manager.sessions.first {
            $0.id == manager.selectedSessionID && $0.source.lowercased() == "claude"
        }
    }

    private var detailSession: AgentSession? {
        guard let detailSessionID else { return nil }
        return manager.sessions.first(where: { $0.id == detailSessionID })
    }

    var body: some View {
        Group {
            if let detailSession {
                taskDetail(session: detailSession)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                taskList
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.snappy(duration: 0.2), value: detailSessionID)
        .fileImporter(
            isPresented: $showsDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let directory = urls.first else { return }
            manager.newConversation(cwd: directory.path)
            composerFocused = true
        }
        .onChange(of: manager.sessions.map(\.id)) { _, identifiers in
            if let detailSessionID, !identifiers.contains(detailSessionID) {
                self.detailSessionID = nil
            }
        }
    }

    private var taskList: some View {
        VStack(spacing: 7) {
            sessionStrip
                .frame(height: 74)

            claudeComposer(for: selectedClaudeSession, showsTarget: true)
                .frame(height: 32)
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
                            isSelected: manager.selectedSessionID == session.id,
                            isClosing: manager.closingSessionIDs.contains(session.id)
                        ) {
                            openSession(session)
                        }
                    }

                    NewClaudeTaskButton {
                        manager.newConversation()
                        composerFocused = true
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
        return "Monitor Claude Code tasks or start a new conversation below."
    }

    private func taskDetail(session: AgentSession) -> some View {
        VStack(spacing: 6) {
            detailHeader(session: session)
                .frame(height: 26)

            AgentConversationTimeline(sessionID: session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if session.status.needsAttention {
                attentionBar(session: session)
            }

            if session.source.lowercased() == "claude" {
                claudeComposer(for: session, showsTarget: false)
                    .frame(height: 32)
            }
        }
    }

    private func detailHeader(session: AgentSession) -> some View {
        HStack(spacing: 6) {
            Button {
                detailSessionID = nil
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                    Text("Tasks")
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(height: 24)
                .padding(.horizontal, 6)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("Back to task list")

            Image(systemName: sourceIcon(for: session.source))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(session.status.color)

            Text(session.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                if session.status == .active || session.status == .inProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.72)
                } else {
                    Circle()
                        .fill(session.status.color)
                        .frame(width: 5, height: 5)
                }
                Text(session.status.label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(session.status.color)
                    .lineLimit(1)
            }

            if !session.isManaged {
                Button {
                    manager.jumpToTerminal(session)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 23, height: 23)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Open this Claude task in its terminal")
            }

            Button {
                closeSession(session)
            } label: {
                if manager.closingSessionIDs.contains(session.id) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 23, height: 23)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 23, height: 23)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .buttonStyle(.plain)
            .disabled(manager.closingSessionIDs.contains(session.id))
            .help(
                session.isManaged
                    ? "Close this task and stop its managed Claude process"
                    : "Remove this task from Agent center; the terminal Claude process keeps running"
            )
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func attentionBar(session: AgentSession) -> some View {
        if session.status == .waitingForAnswer {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(session.status.color)

                Text(session.questionTitle ?? "Claude needs an answer")
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                ForEach(session.questionOptions.prefix(3)) { option in
                    Button(option.label) {
                        manager.answer(session, value: option.value)
                    }
                    .buttonStyle(AgentActionButtonStyle(prominent: true))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(session.status.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else if session.status == .waitingForApproval {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(session.status.color)

                Text(session.detail)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button("Deny") { manager.deny(session) }
                    .buttonStyle(AgentActionButtonStyle(prominent: false))
                Button("Allow") { manager.allow(session) }
                    .buttonStyle(AgentActionButtonStyle(prominent: true))
                Button("Always") { manager.allow(session, always: true) }
                    .buttonStyle(AgentActionButtonStyle(prominent: false))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(session.status.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func claudeComposer(for target: AgentSession?, showsTarget: Bool) -> some View {
        HStack(spacing: 6) {
            Menu {
                Button("New conversation") {
                    manager.newConversation()
                    detailSessionID = nil
                }
                Button("New in folder…") { showsDirectoryPicker = true }

                if target != nil {
                    Divider()
                    Button("Open conversation") {
                        if let target { openSession(target) }
                    }
                    Button("Clear and start over") { submitCommand("/clear", to: target) }
                    Button("Stop current run") { submitCommand("/stop", to: target) }
                    Button("Compact context") { submitCommand("/compact", to: target) }
                    Divider()
                    Button("Current session") { submitCommand("/current", to: target) }
                    Button("List conversations") { submitCommand("/list", to: target) }
                    Button("Command help") { submitCommand("/help", to: target) }
                }

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

            if showsTarget {
                if let target {
                    Button {
                        openSession(target)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(target.status.color)
                                .frame(width: 5, height: 5)
                            Text(target.displayName)
                                .lineLimit(1)
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 92)
                    }
                    .buttonStyle(.plain)
                    .help("Open current task")
                } else {
                    Text("New Claude")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            TextField(composerPlaceholder(for: target), text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($composerFocused)
                .onSubmit {
                    sendDraft(to: target)
                }

            Button {
                sendDraft(to: target)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(canSend ? .black : .secondary)
                    .frame(width: 25, height: 25)
                    .background(canSend ? Color.white : Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(target == nil ? "Start a Claude Code conversation" : "Send to this Claude Code task")
        }
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func composerPlaceholder(for target: AgentSession?) -> String {
        if target?.status == .waitingForAnswer { return "Answer Claude…" }
        return target == nil ? "Start Claude Code…" : "Message this task…"
    }

    private func sendDraft(to target: AgentSession?) {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draft = ""

        if message == "/history", let target {
            openSession(target)
            composerFocused = true
            return
        }

        if let target, target.status == .waitingForAnswer {
            manager.answer(target, value: message)
        } else if let target {
            manager.sendMessage(message, to: target.id)
        } else {
            manager.newConversation(prompt: message)
        }
        composerFocused = true
    }

    private func submitCommand(_ command: String, to target: AgentSession?) {
        if let target {
            manager.sendMessage(command, to: target.id)
        } else if command == "/new" {
            manager.newConversation()
        }
        composerFocused = true
    }

    private func openSession(_ session: AgentSession) {
        detailSessionID = session.id
        if session.source.lowercased() == "claude" {
            manager.select(session)
            composerFocused = true
        }
    }

    private func closeSession(_ session: AgentSession) {
        if detailSessionID == session.id {
            detailSessionID = nil
        }
        manager.close(session)
    }

    private func sourceIcon(for source: String) -> String {
        switch source.lowercased() {
        case "claude": return "c.circle.fill"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "gemini": return "sparkles"
        case "cursor": return "cursorarrow.rays"
        case "opencode": return "curlybraces.square.fill"
        default: return "terminal.fill"
        }
    }
}

private struct AgentConversationTimeline: View {
    let sessionID: String
    @ObservedObject private var manager = AgentSessionManager.shared

    private var session: AgentSession? {
        manager.sessions.first(where: { $0.id == sessionID })
    }

    var body: some View {
        Group {
            if let session {
                if session.messages.isEmpty {
                    ContentUnavailableView(
                        "No messages yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(session.detail)
                    )
                    .font(.system(size: 9))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 6) {
                                ForEach(session.messages) { message in
                                    AgentMessageRow(
                                        message: message,
                                        isStreaming: message.id == session.messages.last?.id
                                            && message.role == "assistant"
                                            && (session.status == .active || session.status == .inProgress)
                                    )
                                    .id(message.id)
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 1)
                        }
                        .onAppear {
                            scrollToLatest(session: session, using: proxy, animated: false)
                        }
                        .onChange(of: session.messages.count) { _, _ in
                            scrollToLatest(session: session, using: proxy, animated: true)
                        }
                        .onChange(of: session.messages.last?.text) { _, _ in
                            scrollToLatest(session: session, using: proxy, animated: false)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Task unavailable",
                    systemImage: "bubble.left.and.exclamationmark.bubble.right"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToLatest(session: AgentSession, using proxy: ScrollViewProxy, animated: Bool) {
        guard let identifier = session.messages.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(identifier, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(identifier, anchor: .bottom)
        }
    }
}

private struct AgentMessageRow: View {
    let message: AgentMessage
    let isStreaming: Bool

    private var isUser: Bool { message.role == "user" }
    private var isSystem: Bool { message.role == "system" }
    private var isError: Bool { message.role == "error" }

    var body: some View {
        if isSystem {
            HStack {
                Spacer(minLength: 20)
                Text(message.text)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Spacer(minLength: 20)
            }
            .padding(.vertical, 2)
        } else {
            HStack(alignment: .bottom, spacing: 5) {
                if isUser { Spacer(minLength: 52) }

                VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(roleLabel)
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(roleColor)
                        if isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                            Text("Live")
                                .font(.system(size: 7, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(message.text.isEmpty ? "…" : message.text)
                        .font(.system(size: 9.5))
                        .foregroundStyle(isError ? Color.red : Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 9))

                if !isUser { Spacer(minLength: 52) }
            }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case "user": return "You"
        case "assistant": return "Claude"
        case "error": return "Error"
        default: return message.role.capitalized
        }
    }

    private var roleColor: Color {
        switch message.role {
        case "user": return .blue
        case "assistant": return .green
        case "error": return .red
        default: return .secondary
        }
    }

    private var bubbleColor: Color {
        if isUser { return Color.blue.opacity(0.13) }
        if isError { return Color.red.opacity(0.09) }
        return Color.white.opacity(0.055)
    }
}

private struct AgentSessionCard: View {
    let session: AgentSession
    let isSelected: Bool
    let isClosing: Bool
    let onOpen: () -> Void

    private var cardWidth: CGFloat { session.status.needsAttention ? 214 : 180 }

    var body: some View {
        Button(action: onOpen) {
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

                    if isClosing {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.65)
                    } else {
                        Circle()
                            .fill(session.status.color)
                            .frame(width: 5, height: 5)
                    }

                    Text(isClosing ? "Closing" : session.status.label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(isClosing ? Color.secondary : session.status.color)
                        .lineLimit(1)
                }

                Text(session.status == .waitingForAnswer
                     ? (session.questionTitle ?? session.detail)
                     : session.detail)
                    .font(session.status == .waitingForApproval
                          ? .system(size: 8, design: .monospaced)
                          : .system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 0)

                HStack(spacing: 5) {
                    if session.status.needsAttention {
                        Image(systemName: session.status == .waitingForAnswer ? "questionmark.bubble.fill" : "hand.raised.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(session.status.color)
                        Text("Open to respond")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(session.status.color)
                    } else if session.source.lowercased() == "claude" {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.tertiary)
                        Text("\(session.messages.count) messages")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 0)

                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(session.elapsedLabel(at: context.date))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
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
        }
        .buttonStyle(.plain)
        .disabled(isClosing)
        .help(session.source.lowercased() == "claude" ? "Open live Claude conversation" : "Open task details")
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

private struct NewClaudeTaskButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.08), in: Circle())
                Text("New")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 62, height: 72)
            .background(Color(nsColor: .secondarySystemFill).opacity(0.46), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.04), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Start a new Claude Code task")
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
