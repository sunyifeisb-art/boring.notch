//
//  AgentSessionsView.swift
//  boringNotch
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentSessionsView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = AgentSessionManager.shared
    @State private var draft = ""
    @State private var detailSessionID: String?
    @State private var showsDirectoryPicker = false
    @AppStorage("agentIslandShowCompleted") private var showCompleted = true
    @FocusState private var composerFocused: Bool

    private var displayedSessions: [AgentSession] {
        showCompleted ? manager.agentSessions : manager.agentSessions.filter { $0.status != .completed }
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
            focusComposer()
        }
        .onChange(of: manager.sessions.map(\.id)) { _, identifiers in
            if let detailSessionID, !identifiers.contains(detailSessionID) {
                self.detailSessionID = nil
            }
        }
        .onChange(of: detailSessionID) { _, identifier in
            updateNotchSize(hasDetail: identifier != nil)
        }
        .onChange(of: manager.requestedOpenSessionID) { _, identifier in
            consumeOpenRequest(identifier)
        }
        .onAppear {
            consumeOpenRequest(manager.requestedOpenSessionID)
            updateNotchSize(hasDetail: detailSessionID != nil)
        }
        .onDisappear {
            guard vm.notchState == .open else { return }
            withAnimation(.snappy(duration: 0.22)) {
                vm.notchSize = openNotchSize
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
                        focusComposer()
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
                    Text(manager.isInstallingHooks ? "安装中" : "安装或修复 Agent Hooks")
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
        if let result = manager.hookInstallSummary { return result }
        return !showCompleted && !manager.agentSessions.isEmpty
            ? "当前没有进行中的任务，可在下方新建 Claude 对话。"
            : "Claude Code 与 Codex 连接已就绪，启动任务后会自动显示在这里。"
    }

    private func taskDetail(session: AgentSession) -> some View {
        VStack(spacing: 6) {
            detailHeader(session: session)
                .frame(height: 30)

            AgentConversationTimeline(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if session.status.needsAttention {
                attentionBar(session: session)
            }

            if session.source.lowercased() == "claude" {
                claudeComposer(for: session, showsTarget: false)
                    .frame(height: 36)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(height: 24)
                .padding(.horizontal, 6)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("返回任务列表")

            Image(systemName: sourceIcon(for: session.source))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(session.status.color)

            Text(session.displayName)
                .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(session.status.color)
                    .lineLimit(1)
            }

            if session.source.lowercased() == "claude" {
                Button {
                    manager.jumpToTerminal(session)
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 23, height: 23)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("打开 Claude Code")
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
                Button("安装或修复 Agent Hooks") { manager.installHooks() }
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
                .font(.system(size: showsTarget ? 11 : 12.5))
                .focused($composerFocused)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        focusComposer()
                    }
                )
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
            focusComposer()
            return
        }

        if let target, target.status == .waitingForAnswer {
            manager.answer(target, value: message)
        } else if let target {
            manager.sendMessage(message, to: target.id)
        } else {
            manager.newConversation(prompt: message)
        }
        focusComposer()
    }

    private func submitCommand(_ command: String, to target: AgentSession?) {
        if let target {
            manager.sendMessage(command, to: target.id)
        } else if command == "/new" {
            manager.newConversation()
        }
        focusComposer()
    }

    private func openSession(_ session: AgentSession) {
        detailSessionID = session.id
        if session.source.lowercased() == "claude" {
            manager.select(session)
            focusComposer()
        }
    }

    private func focusComposer() {
        // `nonactivatingPanel` intentionally keeps the user's current app
        // active. Explicitly making the visible notch panel key gives its
        // TextField first-responder status without switching applications.
        if let panel = NSApp.windows.first(where: {
            $0 is BoringNotchSkyLightWindow && $0.isVisible
        }) {
            panel.makeKey()
        }
        composerFocused = true
    }

    private func updateNotchSize(hasDetail: Bool) {
        guard vm.notchState == .open else { return }
        withAnimation(.snappy(duration: 0.22)) {
            vm.notchSize = hasDetail ? agentDetailNotchSize : openNotchSize
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
    let session: AgentSession

    var body: some View {
        Group {
            if session.messages.isEmpty {
                ContentUnavailableView(
                    "暂无消息",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(session.detail)
                )
                .font(.system(size: 12))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 9) {
                            ForEach(session.messages) { message in
                                AgentMessageRow(
                                    message: message,
                                    isStreaming: message.id == session.messages.last?.id
                                        && message.role == "assistant"
                                        && (session.status == .active || session.status == .inProgress)
                                )
                                .equatable()
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

private struct AgentMessageRow: View, Equatable {
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
                    .font(.system(size: 10.5))
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
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(roleColor)
                        if isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                            Text("实时")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    AgentMarkdownContent(
                        text: message.text.isEmpty ? "…" : message.text,
                        isError: isError
                    )
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 11))

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

private struct AgentMarkdownContent: View, Equatable {
    let text: String
    let isError: Bool

    private struct Block: Identifiable {
        enum Kind {
            case paragraph
            case heading(level: Int)
            case bullet
            case numbered(marker: String)
            case quote
            case divider
            case code(language: String?)
            case table(headers: [String], rows: [[String]])
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

        func appendSingle(kind: Block.Kind, content: String) {
            result.append(Block(id: result.count, kind: kind, content: content))
        }

        let sourceLines = text.components(separatedBy: .newlines)
        var lineIndex = 0

        while lineIndex < sourceLines.count {
            let line = sourceLines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if isCode {
                    appendBlock(kind: .code(language: codeLanguage), lines: &lines)
                    isCode = false
                    codeLanguage = nil
                } else {
                    appendBlock(kind: .paragraph, lines: &lines)
                    isCode = true
                    let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                }
            } else if isCode {
                lines.append(line)
            } else if let headers = tableCells(from: line),
                      lineIndex + 1 < sourceLines.count,
                      isTableSeparator(sourceLines[lineIndex + 1], columnCount: headers.count)
            {
                appendBlock(kind: .paragraph, lines: &lines)
                var rows: [[String]] = []
                lineIndex += 2
                while lineIndex < sourceLines.count,
                      let row = tableCells(from: sourceLines[lineIndex]),
                      row.count == headers.count
                {
                    rows.append(row)
                    lineIndex += 1
                }
                appendSingle(kind: .table(headers: headers, rows: rows), content: "")
                continue
            } else if trimmed.isEmpty {
                appendBlock(kind: .paragraph, lines: &lines)
            } else if let heading = heading(from: trimmed) {
                appendBlock(kind: .paragraph, lines: &lines)
                appendSingle(kind: .heading(level: heading.level), content: heading.text)
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                appendBlock(kind: .paragraph, lines: &lines)
                appendSingle(kind: .divider, content: "")
            } else if let bullet = bulletText(from: trimmed) {
                appendBlock(kind: .paragraph, lines: &lines)
                appendSingle(kind: .bullet, content: bullet)
            } else if let numbered = numberedText(from: trimmed) {
                appendBlock(kind: .paragraph, lines: &lines)
                appendSingle(kind: .numbered(marker: numbered.marker), content: numbered.text)
            } else if trimmed.hasPrefix(">") {
                appendBlock(kind: .paragraph, lines: &lines)
                appendSingle(
                    kind: .quote,
                    content: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                )
            } else {
                lines.append(line)
            }
            lineIndex += 1
        }

        appendBlock(kind: isCode ? .code(language: codeLanguage) : .paragraph, lines: &lines)
        return result
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(blocks) { block in
                switch block.kind {
                case .paragraph:
                    Text(inlineMarkdown: block.content)
                        .font(.system(size: 12.5))
                        .foregroundStyle(isError ? Color.red : Color.primary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let level):
                    Text(inlineMarkdown: block.content)
                        .font(.system(size: headingSize(level), weight: .bold))
                        .foregroundStyle(isError ? Color.red : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet:
                    listRow(marker: "•", content: block.content)
                case .numbered(let marker):
                    listRow(marker: marker, content: block.content)
                case .quote:
                    HStack(alignment: .top, spacing: 6) {
                        Capsule()
                            .fill(Color.white.opacity(0.24))
                            .frame(width: 2)
                        Text(inlineMarkdown: block.content)
                            .font(.system(size: 12))
                            .foregroundStyle(isError ? Color.red : Color.secondary)
                            .italic()
                    }
                case .divider:
                    Divider().opacity(0.25)
                case .code(let language):
                    codeBlock(block.content, language: language)
                case .table(let headers, let rows):
                    markdownTable(headers: headers, rows: rows)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func heading(from line: String) -> (level: Int, text: String)? {
        let marker = line.prefix { $0 == "#" }
        guard !marker.isEmpty, marker.count <= 6 else { return nil }
        let remainder = line.dropFirst(marker.count)
        guard remainder.first == " " else { return nil }
        return (marker.count, remainder.trimmingCharacters(in: .whitespaces))
    }

    private func bulletText(from line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private func numberedText(from line: String) -> (marker: String, text: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let number = line[..<dot]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let remainder = line[line.index(after: dot)...]
        guard remainder.first == " " else { return nil }
        return ("\(number).", remainder.trimmingCharacters(in: .whitespaces))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 17
        case 2: return 15.5
        case 3: return 14
        default: return 12.5
        }
    }

    private func tableCells(from line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        let content = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        let cells = content
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.count >= 2 ? cells : nil
    }

    private func isTableSeparator(_ line: String, columnCount: Int) -> Bool {
        guard let cells = tableCells(from: line), cells.count == columnCount else { return false }
        return cells.allSatisfy { cell in
            let marker = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return marker.count >= 3 && marker.allSatisfy { $0 == "-" }
        }
    }

    private func markdownTable(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(cells: headers, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(cells: row, isHeader: false, shaded: index.isMultiple(of: 2))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func tableRow(cells: [String], isHeader: Bool, shaded: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(inlineMarkdown: cell)
                    .font(.system(size: 11.5, weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(isError ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 150, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(isHeader ? Color.white.opacity(0.10) : Color.white.opacity(shaded ? 0.045 : 0.018))
                    .overlay(alignment: .trailing) {
                        if index < cells.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.09))
                                .frame(width: 1)
                        }
                    }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.09))
                .frame(height: 1)
        }
    }

    private func listRow(marker: String, content: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(marker)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 10, alignment: .trailing)
            Text(inlineMarkdown: content)
                .font(.system(size: 12.5))
                .foregroundStyle(isError ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeBlock(_ code: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(language?.uppercased() ?? "代码")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Text(code)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(isError ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 650, alignment: .leading)
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
    init(inlineMarkdown source: String) {
        guard source.count <= 20_000 else {
            self.init(source)
            return
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
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
                Button {
                    AgentSessionManager.shared.jumpToTerminal(session)
                } label: {
                    Label("打开 Claude Code", systemImage: "terminal")
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
