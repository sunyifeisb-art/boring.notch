//
//  AgentSessionsView.swift
//  boringNotch
//

import AppKit
import SwiftUI
import SwiftUIMath
import UniformTypeIdentifiers

struct AgentSessionsView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = AgentSessionManager.shared
    @State private var draft = ""
    @State private var detailSessionID: String?
    @State private var showsDirectoryPicker = false
    @State private var isDroppingFileContext = false
    @State private var composerWindow: NSWindow?
    @AppStorage("agentIslandShowCompleted") private var showCompleted = true
    @FocusState private var composerFocused: Bool

    private var displayedSessions: [AgentSession] {
        showCompleted ? manager.agentSessions : manager.agentSessions.filter { $0.status != .completed }
    }

    private var selectedAgentSession: AgentSession? {
        displayedSessions.first { $0.id == manager.selectedSessionID }
    }

    private var detailSession: AgentSession? {
        guard let detailSessionID else { return nil }
        return manager.sessions.first(where: { $0.id == detailSessionID })
    }

    private var activeCodexSessionIDs: [String] {
        manager.agentSessions
            .filter {
                $0.source.lowercased() == "codex"
                    && [.active, .inProgress, .pending].contains($0.status)
            }
            .map(\.id)
            .sorted()
    }

    var body: some View {
        Group {
            if let detailSession {
                taskDetail(session: detailSession)
                    // Sliding a fully populated transcript while the notch is also
                    // resizing briefly composites two differently wrapped layouts.
                    // A short fade avoids that overlap during entry/exit.
                    .transition(.opacity)
            } else {
                taskList
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.14), value: detailSessionID)
        .fileImporter(
            isPresented: $showsDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let directory = urls.first else { return }
            guard manager.setDefaultWorkingDirectory(directory) else { return }
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
        .onChange(of: activeCodexSessionIDs) { _, identifiers in
            manager.refreshCodexUsageIfNeeded(activeSessionIDs: identifiers)
        }
        .onAppear {
            consumeOpenRequest(manager.requestedOpenSessionID)
            manager.refreshCodexUsageIfNeeded(activeSessionIDs: activeCodexSessionIDs)
            updateNotchSize(hasDetail: detailSessionID != nil)
        }
        .onDisappear {
            guard vm.notchState == .open else { return }
            withAnimation(.snappy(duration: 0.22)) {
                vm.notchSize = openNotchSize
            }
        }
        .alert(
            manager.workspaceAccessError == nil ? "无法打开 Claude Code" : "工作目录授权",
            isPresented: Binding(
                get: { manager.terminalOpenError != nil || manager.workspaceAccessError != nil },
                set: { isPresented in
                    if !isPresented {
                        manager.dismissTerminalOpenError()
                        manager.workspaceAccessError = nil
                    }
                }
            )
        ) {
            Button("好") {
                manager.dismissTerminalOpenError()
                manager.workspaceAccessError = nil
            }
        } message: {
            Text(manager.workspaceAccessError ?? manager.terminalOpenError ?? "")
        }
    }

    private var taskList: some View {
        VStack(spacing: 7) {
            sessionStrip
                .frame(height: 74)

            agentComposer(for: selectedAgentSession, showsTarget: true)
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
                            isClosing: manager.closingSessionIDs.contains(session.id),
                            onDropContext: { providers in handleFileContextDrop(providers, for: session) }
                        ) {
                            openSession(session)
                        }
                    }

                    NewClaudeTaskButton {
                        startNewConversation()
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
            ? "当前没有进行中的任务，可在下方新建 Claude Code 对话。"
            : "安装并信任 Agent Hooks 后，Claude Code 与 Codex 桌面任务会同步到这里。"
    }

    private func taskDetail(session: AgentSession) -> some View {
        VStack(spacing: 6) {
            detailHeader(session: session)
                .frame(height: 30)

            AgentConversationTimeline(session: session)
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if isDroppingFileContext {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .overlay {
                                Text("松开后将文件作为对话上下文发送")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(.black.opacity(0.82), in: Capsule())
                            }
                            .allowsHitTesting(false)
                    }
                }
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText], isTargeted: $isDroppingFileContext) { providers in
                    handleFileContextDrop(providers, for: session)
                }

            if session.status.needsAttention {
                attentionBar(session: session)
            }

            agentComposer(for: session, showsTarget: false)
                .frame(height: 36)
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

            if session.source.lowercased() == "codex",
               [.active, .inProgress, .pending].contains(session.status),
               let usage = manager.codexUsage {
                Button {
                    manager.refreshCodexUsage()
                } label: {
                    HStack(spacing: 3) {
                        if manager.isRefreshingCodexUsage {
                            ProgressView().controlSize(.mini).scaleEffect(0.65)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 7, weight: .semibold))
                        }
                        Text(usage.displayLabel)
                            .lineLimit(1)
                    }
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(usage.error == nil ? Color.secondary : Color.orange)
                }
                .buttonStyle(.plain)
                .disabled(manager.isRefreshingCodexUsage)
                .help(usage.error ?? "点击刷新 Codex 账户额度")
            } else if session.source.lowercased() == "codex",
                      [.active, .inProgress, .pending].contains(session.status) {
                Button {
                    manager.refreshCodexUsage()
                } label: {
                    HStack(spacing: 3) {
                        if manager.isRefreshingCodexUsage {
                            ProgressView().controlSize(.mini).scaleEffect(0.65)
                        } else {
                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .font(.system(size: 8, weight: .medium))
                        }
                        Text(manager.isRefreshingCodexUsage ? "读取中" : "读取额度")
                            .font(.system(size: 8, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(manager.isRefreshingCodexUsage)
            }

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
            } else if session.source.lowercased() == "codex" {
                Button {
                    openCodexDesktop(session)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 23, height: 23)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("在 Codex 桌面打开此任务")
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
                    ? "关闭任务并停止由灵动岛启动的进程"
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

    private func agentComposer(for target: AgentSession?, showsTarget: Bool) -> some View {
        let providerName = target.map { providerDisplayName($0.source) } ?? "Claude Code"
        return HStack(spacing: 6) {
            Menu {
                Button("新建 Claude 对话") {
                    startNewConversation()
                }
                Button("设置默认工作目录（授权一次）…") { showsDirectoryPicker = true }

                if target != nil {
                    Divider()
                    Button("打开对话") {
                        if let target { openSession(target) }
                    }
                    if target?.source.lowercased() == "claude" {
                        Button("清空并重新开始") { submitCommand("/clear", to: target) }
                        Button("停止当前运行") { submitCommand("/stop", to: target) }
                        Button("压缩上下文") { submitCommand("/compact", to: target) }
                        Divider()
                        Button("当前会话") { submitCommand("/current", to: target) }
                        Button("查看对话列表") { submitCommand("/list", to: target) }
                        Button("命令帮助") { submitCommand("/help", to: target) }
                    } else {
                        Button("停止当前运行") { submitCommand("/stop", to: target) }
                    }
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

            if showsTarget, manager.isCodexDesktopRunning || !activeCodexSessionIDs.isEmpty {
                Button {
                    manager.refreshCodexUsage()
                } label: {
                    HStack(spacing: 3) {
                        if manager.isRefreshingCodexUsage {
                            ProgressView().controlSize(.mini).scaleEffect(0.55)
                        } else {
                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .font(.system(size: 7, weight: .medium))
                        }
                        Text(manager.codexUsage?.compactDisplayLabel ?? "Codex 额度")
                            .font(.system(size: 7, weight: .medium, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(manager.codexUsage?.error == nil ? Color.secondary : Color.orange)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .disabled(manager.isRefreshingCodexUsage)
                .help(manager.codexUsage?.error ?? "Codex 活跃任务额度；点击刷新")
            }

            TextField(composerPlaceholder(for: target), text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: showsTarget ? 11 : 12.5))
                .focused($composerFocused)
                .background(AgentComposerWindowReader { window in
                    if composerWindow !== window {
                        composerWindow = window
                        if composerFocused, let panel = window as? BoringNotchSkyLightWindow {
                            panel.makeKey()
                        }
                    }
                })
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
            .help(target == nil ? "发起 Claude Code 对话" : "发送到这个 \(providerName) 任务")
        }
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func composerPlaceholder(for target: AgentSession?) -> String {
        if target?.status == .waitingForAnswer { return "回复 Claude…" }
        guard let target else { return "发起 Claude Code 对话…" }
        return "给当前 \(providerDisplayName(target.source)) 任务发送消息…"
    }

    private func sendDraft(to target: AgentSession?) {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draft = ""
        NotificationCenter.default.post(name: .agentMessageSubmitted, object: nil)

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
            startNewConversation()
        }
        focusComposer()
    }

    private func openSession(_ session: AgentSession) {
        detailSessionID = session.id
        manager.select(session)
        focusComposer()
    }

    private func startNewConversation() {
        detailSessionID = nil
        if manager.hasDefaultWorkingDirectory {
            manager.newConversation()
        } else {
            showsDirectoryPicker = true
        }
    }

    private func openCodexDesktop(_ session: AgentSession) {
        guard let url = URL(string: "codex://threads/\(session.id)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func providerDisplayName(_ source: String) -> String {
        source.lowercased() == "codex" ? "Codex 桌面" : "Claude Code"
    }

    private func focusComposer() {
        // `nonactivatingPanel` intentionally keeps the user's current app
        // active. Explicitly making the visible notch panel key gives its
        // TextField first-responder status without switching applications.
        if let panel = composerWindow as? BoringNotchSkyLightWindow, panel.isVisible {
            panel.makeKey()
        }
        DispatchQueue.main.async {
            composerFocused = true
        }
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

    private func handleFileContextDrop(_ providers: [NSItemProvider], for session: AgentSession) -> Bool {
        guard !providers.isEmpty else { return false }
        detailSessionID = session.id
        manager.select(session)
        Task {
            var references: [String] = []
            for provider in providers {
                if let fileURL = await provider.extractFileURL() {
                    references.append("- 文件：\(fileURL.path)")
                } else if let url = await provider.extractURL() {
                    references.append(url.isFileURL ? "- 文件：\(url.path)" : "- 链接：\(url.absoluteString)")
                } else if let text = await provider.extractText(), !text.isEmpty {
                    references.append("- 内容：\(String(text.prefix(4_000)))")
                }
            }
            guard !references.isEmpty else { return }
            let prompt = "请结合我拖入的内容协助处理：\n\n\(references.joined(separator: "\n"))"
            manager.sendMessage(prompt, to: session.id)
        }
        return true
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

    @State private var isOutlineExpanded = false
    @State private var activeMessageID: UUID?
    @State private var trackedMessageID: UUID?
    @State private var isFollowingLatest = true

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
                    ZStack(alignment: .trailing) {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 9) {
                                ForEach(session.messages) { message in
                                    AgentMessageRow(
                                        message: message,
                                        source: session.source,
                                        isStreaming: message.id == session.messages.last?.id
                                            && message.role == "assistant"
                                            && (session.status == .active || session.status == .inProgress)
                                    )
                                    .equatable()
                                    .id(message.id)
                                }
                            }
                            .padding(.leading, 2)
                            .padding(.trailing, 17)
                            .padding(.vertical, 1)
                            .scrollTargetLayout()
                        }
                        .scrollPosition(id: $trackedMessageID, anchor: .bottom)
                        .defaultScrollAnchor(.bottom)
                        .onChange(of: trackedMessageID) { _, identifier in
                            activeMessageID = identifier
                            isFollowingLatest = identifier == session.messages.last?.id
                        }

                        conversationOutline(using: proxy)
                    }
                    .onAppear {
                        trackedMessageID = session.messages.last?.id
                    }
                    .onChange(of: session.messages.count) { _, _ in
                        if isFollowingLatest || session.messages.last?.role == "user" {
                            trackedMessageID = session.messages.last?.id
                        }
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

    @ViewBuilder
    private func conversationOutline(using proxy: ScrollViewProxy) -> some View {
        if !session.messages.isEmpty {
            HStack(spacing: 8) {
                if isOutlineExpanded {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("对话目录")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.black.opacity(0.78))
                            Spacer(minLength: 4)
                            Button {
                                guard let latestID = session.messages.last?.id else { return }
                                withAnimation(.easeInOut(duration: 0.24)) {
                                    proxy.scrollTo(latestID, anchor: .bottom)
                                }
                            } label: {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.black.opacity(0.55))
                                    .frame(width: 22, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("跳到最新消息")
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)

                        ScrollViewReader { outlineProxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(session.messages.enumerated()), id: \.element.id) { index, message in
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.24)) {
                                                proxy.scrollTo(message.id, anchor: .top)
                                            }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Circle()
                                                    .fill(message.role == "user" ? Color.blue : Color.gray.opacity(0.65))
                                                    .frame(width: 5, height: 5)
                                                Text(outlineTitle(for: message, index: index))
                                                    .font(.system(size: 10, weight: message.role == "user" ? .medium : .regular))
                                                    .lineLimit(1)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .foregroundStyle(Color.black.opacity(0.78))
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 6)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .background(
                                            message.id == activeMessageID ? Color.blue.opacity(0.12) : Color.black.opacity(0.045),
                                            in: RoundedRectangle(cornerRadius: 7)
                                        )
                                        .id(message.id)
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.bottom, 7)
                            }
                            .onAppear {
                                outlineProxy.scrollTo(activeMessageID ?? session.messages.last?.id, anchor: .center)
                            }
                            .onChange(of: activeMessageID) { _, identifier in
                                guard let identifier else { return }
                                withAnimation(.easeOut(duration: 0.16)) {
                                    outlineProxy.scrollTo(identifier, anchor: .center)
                                }
                            }
                        }
                    }
                    .frame(width: 190, height: min(270, max(130, CGFloat(session.messages.count) * 28 + 42)))
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 16, y: 5)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                GeometryReader { geometry in
                    ZStack(alignment: .top) {
                        Capsule()
                            .fill(Color.white.opacity(0.72))
                            .frame(width: 2, height: geometry.size.height * 0.72)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ForEach(Array(session.messages.enumerated()), id: \.element.id) { index, message in
                            Capsule()
                                .fill(Color.white.opacity(message.id == activeMessageID ? 1 : 0.48))
                                .frame(width: message.id == activeMessageID ? 12 : (index.isMultiple(of: 4) ? 9 : 5), height: message.id == activeMessageID ? 3 : 2)
                                .position(
                                    x: geometry.size.width / 2,
                                    y: markerY(index: index, count: session.messages.count, height: geometry.size.height)
                                )
                        }
                    }
                    .contentShape(Rectangle())
                }
                .frame(width: 14)
                .padding(.vertical, 15)
            }
            .padding(.trailing, 1)
            .frame(maxHeight: .infinity, alignment: .center)
            .onHover { hovering in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    isOutlineExpanded = hovering
                }
            }
            .help("悬停查看对话目录，点击跳转")
        }
    }

    private func markerY(index: Int, count: Int, height: CGFloat) -> CGFloat {
        guard count > 1 else { return height / 2 }
        return 9 + CGFloat(index) / CGFloat(count - 1) * max(0, height - 18)
    }

    private func outlineTitle(for message: AgentMessage, index: Int) -> String {
        let role = message.role == "user" ? "我" : (message.role == "assistant" ? assistantName : "提示")
        let firstLine = message.text
            .prefix(256)
            .split(whereSeparator: \.isNewline)
            .first(where: { !String($0).trimmingCharacters(in: .whitespaces).isEmpty })
            .map {
                String($0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#*- `>"))
            } ?? ""
        let title = firstLine.isEmpty ? "消息 \(index + 1)" : String(firstLine.prefix(32))
        return "\(role)：\(title)"
    }

    private var assistantName: String {
        session.source.lowercased() == "codex" ? "Codex" : "Claude"
    }
}

private struct AgentMessageRow: View, Equatable {
    let message: AgentMessage
    let source: String
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
            HStack(alignment: .bottom, spacing: 0) {
                if isUser { Spacer(minLength: 24) }

                AgentBubbleLayout(maximumWidth: isUser ? 520 : 900) {
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

                    if isStreaming {
                        // Keep live output responsive: parsing Markdown, formulas,
                        // tables and code blocks against the entire growing reply
                        // on every stream update caused expensive repeated layout.
                        Text(message.text.isEmpty ? "…" : message.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(isError ? Color.red : Color.primary)
                            .lineSpacing(1.5)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        AgentMarkdownContent(
                            text: message.text.isEmpty ? "…" : message.text,
                            isError: isError,
                            messageID: message.id
                        )
                        .multilineTextAlignment(isUser ? .trailing : .leading)
                    }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 11))
                }

                if !isUser { Spacer(minLength: 24) }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    private var roleLabel: String {
        switch message.role {
        case "user": return "我"
        case "assistant": return source.lowercased() == "codex" ? "Codex" : "Claude"
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

private struct AgentBubbleLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let availableWidth = min(maximumWidth, proposal.width ?? maximumWidth)
        // Measuring a streaming message with an unspecified width makes SwiftUI
        // shape its entire growing text as one unbounded line on every update.
        // Constrain the first measurement so long replies wrap immediately and
        // short messages can still report their natural width.
        return content.sizeThatFits(ProposedViewSize(width: availableWidth, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        content.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

private struct AgentMarkdownContent: View, Equatable {
    let text: String
    let isError: Bool
    let messageID: UUID

    private struct Block: Identifiable, Sendable {
        enum Kind: Sendable {
            case paragraph
            case heading(level: Int)
            case bullet
            case numbered(marker: String)
            case quote
            case divider
            case math
            case code(language: String?)
            case table(headers: [String], rows: [[String]])
        }

        let id: Int
        let kind: Kind
        let content: String
    }

    private let parsedBlocks: [Block]?

    init(text: String, isError: Bool, messageID: UUID) {
        self.text = text
        self.isError = isError
        self.messageID = messageID

        // Keep the rich renderer bounded. Replacing a plain-text placeholder
        // with hundreds of asynchronously-created rows changed lazy-list row
        // heights after scrolling had begun, which could leave stale/overlapped
        // content visible when opening long conversations.
        let newlineCount = text.utf8.filter { $0 == 0x0A }.prefix(201).count
        if text.utf8.count <= 20_000, newlineCount <= 200 {
            parsedBlocks = Self.parseBlocks(text)
        } else {
            parsedBlocks = nil
        }
    }

    static func == (lhs: AgentMarkdownContent, rhs: AgentMarkdownContent) -> Bool {
        lhs.text == rhs.text && lhs.isError == rhs.isError && lhs.messageID == rhs.messageID
    }

    nonisolated private static func parseBlocks(_ text: String) -> [Block] {
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
            } else if !isCode && (trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[")) {
                appendBlock(kind: .paragraph, lines: &lines)
                let delimiter = trimmed.hasPrefix("$$") ? "$$" : "\\["
                let closingDelimiter = delimiter == "$$" ? "$$" : "\\]"
                let first = String(trimmed.dropFirst(delimiter.count))
                if let end = first.range(of: closingDelimiter) {
                    appendSingle(kind: .math, content: String(first[..<end.lowerBound]))
                } else {
                    var formulaLines = [first]
                    lineIndex += 1
                    while lineIndex < sourceLines.count {
                        let formulaLine = sourceLines[lineIndex]
                        if let end = formulaLine.range(of: closingDelimiter) {
                            formulaLines.append(String(formulaLine[..<end.lowerBound]))
                            break
                        }
                        formulaLines.append(formulaLine)
                        lineIndex += 1
                    }
                    appendSingle(kind: .math, content: formulaLines.joined(separator: "\n"))
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
        Group {
            if let parsedBlocks {
                // The outer conversation list already virtualizes whole messages.
                // A nested lazy stack estimates rich row heights and can overlap
                // content while a long transcript settles.
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(parsedBlocks) { block in
                        Group {
                            switch block.kind {
                            case .paragraph:
                                AgentInlineMarkdown(source: block.content, fontSize: 12.5, color: isError ? .red : .primary)
                                    .lineSpacing(1.5)
                            case .heading(let level):
                                AgentInlineMarkdown(
                                    source: block.content,
                                    fontSize: headingSize(level),
                                    color: isError ? .red : .primary,
                                    weight: .bold
                                )
                            case .bullet:
                                listRow(marker: "•", content: block.content)
                            case .numbered(let marker):
                                listRow(marker: marker, content: block.content)
                            case .quote:
                                HStack(alignment: .top, spacing: 6) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.24))
                                        .frame(width: 2)
                                    AgentInlineMarkdown(
                                        source: block.content,
                                        fontSize: 12,
                                        color: isError ? .red : .secondary,
                                        italic: true
                                    )
                                }
                            case .divider:
                                Divider().opacity(0.25)
                            case .math:
                                Math(block.content)
                                    .mathFont(Math.Font(name: .latinModern, size: 16))
                                    .mathTypesettingStyle(.display)
                                    .foregroundStyle(isError ? Color.red : Color.primary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 5)
                                    .fixedSize(horizontal: false, vertical: true)
                            case .code(let language):
                                codeBlock(block.content, language: language)
                            case .table(let headers, let rows):
                                markdownTable(headers: headers, rows: rows)
                            }
                        }
                        .id("\(messageID.uuidString)-block-\(block.id)")
                    }
                }
            } else {
                // Large transcripts use one text view instead of thousands of
                // Markdown subviews. This keeps the lazy timeline's row geometry
                // stable and bounds layout work when entering an older task.
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isError ? Color.red : Color.primary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }

    nonisolated private static func heading(from line: String) -> (level: Int, text: String)? {
        let marker = line.prefix { $0 == "#" }
        guard !marker.isEmpty, marker.count <= 6 else { return nil }
        let remainder = line.dropFirst(marker.count)
        guard remainder.first == " " else { return nil }
        return (marker.count, remainder.trimmingCharacters(in: .whitespaces))
    }

    nonisolated private static func bulletText(from line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    nonisolated private static func numberedText(from line: String) -> (marker: String, text: String)? {
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

    nonisolated private static func tableCells(from line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        let content = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        let cells = content
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.count >= 2 ? cells : nil
    }

    nonisolated private static func isTableSeparator(_ line: String, columnCount: Int) -> Bool {
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
                AgentInlineMarkdown(
                    source: cell,
                    fontSize: 11.5,
                    color: isError ? .red : .primary,
                    weight: isHeader ? .semibold : .regular
                )
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
            AgentInlineMarkdown(source: content, fontSize: 12.5, color: isError ? .red : .primary)
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

private struct AgentInlineMarkdown: View {
    let source: String
    let fontSize: CGFloat
    let color: Color
    var weight: Font.Weight = .regular
    var italic = false

    private static let formulaExpression = try? NSRegularExpression(
        pattern: #"(?<!\$)\$\$([\s\S]+?)\$\$(?!\$)|(?<!\\)\$(?!\$)([^$\n]+)\$|\\\((.*?)\\\)|\\\[([\s\S]*?)\\\]"#
    )

    private struct Segment: Identifiable {
        let id: Int
        let text: String
        let isFormula: Bool
    }

    private var segments: [Segment] {
        guard let expression = Self.formulaExpression else {
            return [Segment(id: 0, text: source, isFormula: false)]
        }
        let nsSource = source as NSString
        let matches = expression.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        guard !matches.isEmpty else { return [Segment(id: 0, text: source, isFormula: false)] }

        var result: [Segment] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result.append(Segment(
                    id: result.count,
                    text: nsSource.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                    isFormula: false
                ))
            }
            let formula = (1..<match.numberOfRanges).compactMap { index -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : nsSource.substring(with: range)
            }.first(where: { !$0.isEmpty }) ?? ""
            result.append(Segment(id: result.count, text: formula, isFormula: true))
            cursor = NSMaxRange(match.range)
        }
        if cursor < nsSource.length {
            result.append(Segment(
                id: result.count,
                text: nsSource.substring(from: cursor),
                isFormula: false
            ))
        }
        return result
    }

    var body: some View {
        if !segments.contains(where: \.isFormula) {
            markdownText(source)
        } else {
            InlineFormulaFlowLayout(horizontalSpacing: 1, verticalSpacing: 2) {
                ForEach(segments) { segment in
                    if segment.isFormula {
                        Math(segment.text)
                            .mathFont(Math.Font(name: .latinModern, size: fontSize + 1))
                            .mathTypesettingStyle(.text)
                            .foregroundStyle(color)
                    } else {
                        markdownText(segment.text)
                    }
                }
            }
        }
    }

    private func markdownText(_ value: String) -> some View {
        Text(inlineMarkdown: value)
            .font(.system(size: fontSize, weight: weight))
            .italic(italic)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InlineFormulaFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    private struct Placement {
        let origin: CGPoint
        let size: CGSize
    }

    private struct Measurement {
        let size: CGSize
        let placements: [Placement]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = measure(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (subview, placement) in zip(subviews, result.placements) {
            subview.place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(width: placement.size.width, height: placement.size.height)
            )
        }
    }

    private func measure(proposal: ProposedViewSize, subviews: Subviews) -> Measurement {
        let maximumWidth = max(1, proposal.width ?? 620)
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widestLine: CGFloat = 0

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maximumWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maximumWidth, height: nil))
            }
            if x > 0, x + horizontalSpacing + size.width > maximumWidth {
                widestLine = max(widestLine, x)
                y += lineHeight + verticalSpacing
                x = 0
                lineHeight = 0
            }
            if x > 0 { x += horizontalSpacing }
            placements.append(Placement(origin: CGPoint(x: x, y: y), size: size))
            x += size.width
            lineHeight = max(lineHeight, size.height)
        }

        return Measurement(
            size: CGSize(width: min(maximumWidth, max(widestLine, x)), height: y + lineHeight),
            placements: placements
        )
    }
}

private struct AgentSessionCard: View {
    let session: AgentSession
    let isSelected: Bool
    let isClosing: Bool
    let onDropContext: ([NSItemProvider]) -> Bool
    let onOpen: () -> Void
    @State private var isDropTargeted = false

    private var cardWidth: CGFloat { session.status.needsAttention ? 214 : 180 }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: sourceIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(session.status.color)

                    Text(session.source.lowercased() == "codex" ? "Codex 桌面" : "Claude Code")
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
                    } else if ["claude", "codex"].contains(session.source.lowercased()) {
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
                    .stroke(isDropTargeted ? Color.accentColor : borderColor, lineWidth: isSelected || isDropTargeted ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isClosing)
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText], isTargeted: $isDropTargeted, perform: onDropContext)
        .help("打开\(session.source.lowercased() == "codex" ? "Codex 桌面" : "Claude Code")实时任务详情")
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
            } else if session.source.lowercased() == "codex" {
                Button {
                    openCodexDesktop(session)
                } label: {
                    Label("在 Codex 桌面打开", systemImage: "arrow.up.right.square")
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

    private func openCodexDesktop(_ session: AgentSession) {
        guard let url = URL(string: "codex://threads/\(session.id)") else { return }
        NSWorkspace.shared.open(url)
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

private struct AgentComposerWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResolve: onResolve) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        context.coordinator.resolve(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.resolve(from: view)
    }

    final class Coordinator {
        private let onResolve: (NSWindow?) -> Void
        private weak var resolvedWindow: NSWindow?

        init(onResolve: @escaping (NSWindow?) -> Void) {
            self.onResolve = onResolve
        }

        func resolve(from view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let window = view.window,
                      self.resolvedWindow !== window else { return }
                self.resolvedWindow = window
                self.onResolve(window)
            }
        }
    }
}
