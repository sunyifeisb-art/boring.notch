//
//  AgentSessionsView.swift
//  boringNotch
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentSessionsView: View {
    @ObservedObject private var manager = AgentSessionManager.shared
    @State private var draft = ""
    @State private var detailSessionID: String?
    @State private var showsDirectoryPicker = false
    @AppStorage("agentIslandShowCompleted") private var showCompleted = true
    @FocusState private var composerFocused: Bool

    private var displayedSessions: [AgentSession] {
        showCompleted ? manager.sessions : manager.sessions.filter { $0.status != .completed }
    }

    private var selectedClaudeSession: AgentSession? {
        displayedSessions.first {
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
        .onChange(of: manager.requestedOpenSessionID) { _, identifier in
            consumeOpenRequest(identifier)
        }
        .onAppear {
            consumeOpenRequest(manager.requestedOpenSessionID)
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
        if displayedSessions.isEmpty {
            emptyState
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(displayedSessions) { session in
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
                Text(manager.bridgeError == nil ? "Agent 中心" : "Agent 桥接不可用")
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
                    Text(manager.isInstallingHooks ? "安装中" : "安装或修复 Hooks")
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
        return !showCompleted && !manager.sessions.isEmpty
            ? "当前没有进行中的任务，可在下方新建 Claude 对话。"
            : "监控 Claude Code 任务，或在下方发起新对话。"
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
                    Text("任务")
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(height: 24)
                .padding(.horizontal, 6)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("返回任务列表")

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
                .help("在 Ghostty 中打开这个 Claude Code 对话")
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
                    ? "关闭任务并停止由灵动岛启动的 Claude 进程"
                    : "从 Agent 中心移除任务；终端中的 Claude 会继续运行"
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

                Text(session.questionTitle ?? "Claude 正在等待回答")
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

                Button("拒绝") { manager.deny(session) }
                    .buttonStyle(AgentActionButtonStyle(prominent: false))
                Button("允许") { manager.allow(session) }
                    .buttonStyle(AgentActionButtonStyle(prominent: true))
                Button("始终允许") { manager.allow(session, always: true) }
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
                Button("新建对话") {
                    manager.newConversation()
                    detailSessionID = nil
                }
                Button("在文件夹中新建…") { showsDirectoryPicker = true }

                if target != nil {
                    Divider()
                    Button("打开对话") {
                        if let target { openSession(target) }
                    }
                    Button("清空并重新开始") { submitCommand("/clear", to: target) }
                    Button("停止当前运行") { submitCommand("/stop", to: target) }
                    Button("压缩上下文") { submitCommand("/compact", to: target) }
                    Divider()
                    Button("当前会话") { submitCommand("/current", to: target) }
                    Button("查看对话列表") { submitCommand("/list", to: target) }
                    Button("命令帮助") { submitCommand("/help", to: target) }
                }

                Divider()
                Button("安装或修复 Hooks") { manager.installHooks() }
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 28, height: 26)
                    .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Claude Code 命令")

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
                    .help("打开当前任务")
                } else {
                    Text("新建 Claude")
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
            .help(target == nil ? "发起 Claude Code 对话" : "发送到这个 Claude Code 任务")
        }
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func composerPlaceholder(for target: AgentSession?) -> String {
        if target?.status == .waitingForAnswer { return "回复 Claude…" }
        return target == nil ? "发起 Claude Code 对话…" : "给当前任务发送消息…"
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

    private func consumeOpenRequest(_ identifier: String?) {
        guard let identifier,
              let session = manager.sessions.first(where: { $0.id == identifier })
        else { return }
        openSession(session)
        manager.requestedOpenSessionID = nil
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
                        "暂无消息",
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
                    "任务不可用",
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
                            Text("实时")
                                .font(.system(size: 7, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    AgentMarkdownContent(
                        text: message.text.isEmpty ? "…" : message.text,
                        isError: isError
                    )
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
        case "user": return "我"
        case "assistant": return "Claude"
        case "error": return "错误"
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

private struct AgentMarkdownContent: View {
    let text: String
    let isError: Bool

    private struct Block: Identifiable {
        enum Kind {
            case markdown
            case code(language: String?)
        }

        let id: Int
        let kind: Kind
        let content: String
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var lines: [String] = []
        var codeLanguage: String?
        var isCode = false

        func appendBlock(kind: Block.Kind, lines: inout [String]) {
            guard !lines.isEmpty else { return }
            result.append(Block(id: result.count, kind: kind, content: lines.joined(separator: "\n")))
            lines.removeAll(keepingCapacity: true)
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if isCode {
                    appendBlock(kind: .code(language: codeLanguage), lines: &lines)
                    isCode = false
                    codeLanguage = nil
                } else {
                    appendBlock(kind: .markdown, lines: &lines)
                    isCode = true
                    let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                }
            } else {
                lines.append(line)
            }
        }

        appendBlock(kind: isCode ? .code(language: codeLanguage) : .markdown, lines: &lines)
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(blocks) { block in
                switch block.kind {
                case .markdown:
                    Text(markdown: block.content)
                        .font(.system(size: 9.5))
                        .foregroundStyle(isError ? Color.red : Color.primary)
                        .lineSpacing(1.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language):
                    codeBlock(block.content, language: language)
                }
            }
        }
    }

    private func codeBlock(_ code: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(language?.uppercased() ?? "代码")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 7, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(isError ? Color.red : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.36), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
    }
}

private extension Text {
    init(markdown source: String) {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: source, options: options) {
            self.init(attributed)
        } else {
            self.init(source)
        }
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

                    Text(isClosing ? "关闭中" : session.status.label)
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
                        Text("打开处理")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(session.status.color)
                    } else if session.source.lowercased() == "claude" {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.tertiary)
                        Text("\(session.messages.count) 条消息")
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
        .help(session.source.lowercased() == "claude" ? "打开 Claude 实时对话" : "打开任务详情")
        .contextMenu {
            Button {
                onOpen()
            } label: {
                Label("打开对话", systemImage: "bubble.left.and.bubble.right")
            }

            if session.source.lowercased() == "claude" {
                if !session.isManaged {
                    Button {
                        AgentSessionManager.shared.jumpToTerminal(session)
                    } label: {
                        Label("在 Ghostty 中打开", systemImage: "terminal")
                    }
                }

                if session.status == .active || session.status == .inProgress {
                    Button {
                        AgentSessionManager.shared.sendMessage("/stop", to: session.id)
                    } label: {
                        Label("停止当前运行", systemImage: "stop.circle")
                    }
                }
            }

            if let cwd = session.cwd, !cwd.isEmpty {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
                } label: {
                    Label("打开工作目录", systemImage: "folder")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cwd, forType: .string)
                } label: {
                    Label("复制工作目录", systemImage: "doc.on.doc")
                }
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            } label: {
                Label("复制会话 ID", systemImage: "number")
            }

            Divider()

            Button(role: .destructive) {
                AgentSessionManager.shared.close(session)
            } label: {
                Label("关闭任务窗口", systemImage: "xmark.circle")
            }
        }
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
                Text("新建")
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
        .help("新建 Claude Code 任务")
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
