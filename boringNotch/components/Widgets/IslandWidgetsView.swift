import AppKit
import SwiftUI

struct IslandWidgetsView: View {
    @AppStorage("islandWidgetKinds") private var storedKinds = "agents,quickActions,codexUsage"
    @State private var showingCatalog = false
    @ObservedObject private var catalogService = WidgetCatalogService.shared
    @ObservedObject private var agentManager = AgentSessionManager.shared

    private var visibleKinds: [IslandWidgetKind] {
        storedKinds.split(separator: ",")
            .compactMap { IslandWidgetKind(rawValue: String($0)) }
    }

    private var availableKinds: [IslandWidgetKind] {
        IslandWidgetKind.allCases.filter { !visibleKinds.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundStyle(.white.opacity(0.75))
                Text("灵动岛组件")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("状态、操作和 Agent 信息")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    catalogService.scanIfNeeded()
                    showingCatalog = true
                } label: {
                    Label("应用组件清单", systemImage: "square.grid.2x2")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .background(Color.white.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingCatalog, arrowEdge: .top) {
                    WidgetCatalogPicker(
                        onRefresh: { catalogService.scan() }
                    )
                    .frame(width: 390, height: 450)
                    .preferredColorScheme(.dark)
                }
                Menu {
                    ForEach(availableKinds) { kind in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                save(visibleKinds + [kind])
                            }
                        } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                    if !visibleKinds.isEmpty {
                        Divider()
                        Button("恢复默认组件") { save(IslandWidgetKind.defaultKinds) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 25, height: 25)
                        .background(Color.white.opacity(0.09), in: Circle())
                }
                .menuStyle(.borderlessButton)
            }

            if visibleKinds.isEmpty {
                ContentUnavailableView("还没有组件", systemImage: "square.grid.2x2", description: Text("从菜单添加 Agent 状态、快捷控制或 Codex 额度组件。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let cardWidth = max(160, (geometry.size.width - 20) / 3)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(visibleKinds) { kind in
                                IslandWidgetCard(kind: kind)
                                    .frame(width: cardWidth, height: 178)
                                    .onDrag { NSItemProvider(object: kind.rawValue as NSString) }
                                    .dropDestination(for: String.self) { values, _ in
                                        guard let moved = values.first.flatMap(IslandWidgetKind.init(rawValue:)),
                                              moved != kind
                                        else { return false }
                                        reorder(moved, before: kind)
                                        return true
                                    }
                                    .contextMenu {
                                        Button("移除组件", systemImage: "minus.circle") {
                                            save(visibleKinds.filter { $0 != kind })
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.top, 2)
                        .padding(.bottom, 6)
                    }
                    .frame(height: 186)
                }
                .frame(height: 186)
            }

            Text("组件直接显示任务状态并提供操作。应用自带的 WidgetKit 画面不能被其他 App 内嵌；清单用于识别本机扩展并显示兼容情况。")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 1)
        .padding(.bottom, 12)
        .onAppear {
            if storedKinds == "clock,battery,calendar,agents" {
                storedKinds = IslandWidgetKind.defaultKinds.map(\.rawValue).joined(separator: ",")
            }
            managerRefreshCodexUsage()
        }
        .onChange(of: agentManager.agentSessions.filter { $0.source.lowercased() == "codex" && $0.status.isRunningOrWaiting }.map(\.id)) { _, _ in
            managerRefreshCodexUsage()
        }
    }

    private func save(_ kinds: [IslandWidgetKind]) {
        storedKinds = kinds.map(\.rawValue).joined(separator: ",")
    }

    private func reorder(_ moved: IslandWidgetKind, before target: IslandWidgetKind) {
        var order = visibleKinds.filter { $0 != moved }
        guard let index = order.firstIndex(of: target) else { return }
        order.insert(moved, at: index)
        save(order)
    }

    private func managerRefreshCodexUsage() {
        let active = agentManager.agentSessions.filter {
            $0.source.lowercased() == "codex" && $0.status.isRunningOrWaiting
        }.map(\.id)
        agentManager.refreshCodexUsageIfNeeded(activeSessionIDs: active)
    }
}

private struct WidgetCatalogPicker: View {
    @ObservedObject private var service = WidgetCatalogService.shared
    @State private var searchText = ""
    let onRefresh: () -> Void

    private var filteredWidgets: [DiscoveredWidgetExtension] {
        guard !searchText.isEmpty else { return service.widgets }
        return service.widgets.filter {
            $0.localizedAppName.localizedCaseInsensitiveContains(searchText)
                || $0.localizedDisplayName.localizedCaseInsensitiveContains(searchText)
                || $0.appName.localizedCaseInsensitiveContains(searchText)
                || $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.appBundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac 组件库")
                        .font(.system(size: 14, weight: .semibold))
                    Text(service.isScanning ? "正在扫描已安装的应用…" : "识别到 \(service.widgets.count) 个应用组件扩展")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(service.isScanning)
                .help("重新扫描应用")
            }

            TextField("搜索应用或组件", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if service.isScanning && service.widgets.isEmpty {
                ProgressView("正在读取应用扩展")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredWidgets.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "没有发现 Widget 扩展" : "没有匹配的组件",
                    systemImage: "square.grid.2x2",
                    description: Text(searchText.isEmpty ? "检查 /Applications 和系统应用目录，或点击重新扫描。" : "换个应用名称或关键词试试。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(filteredWidgets) { widget in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: (widget.appURL ?? widget.extensionURL).path))
                                    .resizable()
                                    .frame(width: 30, height: 30)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(widget.localizedDisplayName)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Text(widget.localizedAppName)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Label("系统限制，不能内嵌", systemImage: "info.circle")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }

                Text("macOS 不开放把其他 App 的 WidgetKit 画面嵌入本 App 的接口。灵动岛内的组件会使用本 App 可交互的原生卡片，避免把应用启动入口伪装成小组件。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }
}

private enum IslandWidgetKind: String, CaseIterable, Identifiable {
    case agents, quickActions, codexUsage

    static let defaultKinds: [IslandWidgetKind] = [.agents, .quickActions, .codexUsage]
    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: "Agent 任务"
        case .quickActions: "快捷指令"
        case .codexUsage: "Codex 额度"
        }
    }

    var symbol: String {
        switch self {
        case .agents: "terminal"
        case .quickActions: "bolt.fill"
        case .codexUsage: "gauge.with.needle"
        }
    }
}

private struct IslandWidgetCard: View {
    let kind: IslandWidgetKind
    @ObservedObject private var agentManager = AgentSessionManager.shared
    @ObservedObject private var shortcutService = ShortcutActionService.shared
    @AppStorage("islandShortcutNames") private var storedShortcutNames = "[]"
    @State private var showingShortcutPicker = false

    private var selectedShortcutNames: [String] {
        guard let data = storedShortcutNames.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Array(names.prefix(4))
    }

    private var activeSessions: [AgentSession] {
        agentManager.agentSessions.filter { $0.status.isRunningOrWaiting }
    }

    private var currentSession: AgentSession? {
        if let selected = agentManager.selectedAgentSession,
           !selected.status.isTerminal,
           (selected.status.isRunningOrWaiting || selected.lastActivity >= Date().addingTimeInterval(-24 * 60 * 60))
        {
            return selected
        }
        return activeSessions.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(kind.title, systemImage: kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if kind == .quickActions {
                    Button {
                        shortcutService.scanIfNeeded()
                        showingShortcutPicker = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("选择要显示的快捷指令")
                    .popover(isPresented: $showingShortcutPicker, arrowEdge: .top) {
                        ShortcutSelectionPicker(
                            selectedNames: selectedShortcutNames,
                            onSave: saveShortcutNames
                        )
                        .frame(width: 280, height: 340)
                        .preferredColorScheme(.dark)
                    }
                }
            }
            content
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .agents:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(activeSessions.count)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("项进行中")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(currentSession?.displayName ?? "等待 Agent 任务")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(currentSession?.detail ?? "Codex 与 Claude Code 的任务进度会显示在这里")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 7) {
                    Button("查看对话") {
                        if let currentSession { agentManager.requestOpen(currentSession) }
                        else { BoringViewCoordinator.shared.currentView = .agents }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    Button("新建 CC") {
                        agentManager.newConversation(openInIsland: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    if let currentSession, [.active, .inProgress].contains(currentSession.status) {
                        Button("停止") {
                            agentManager.sendMessage("/stop", to: currentSession.id)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                    }
                }
            }
        case .quickActions:
            VStack(alignment: .leading, spacing: 4) {
                if selectedShortcutNames.isEmpty {
                    Text("把常用操作放到灵动岛")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Button("选择快捷指令") {
                        shortcutService.scanIfNeeded()
                        showingShortcutPicker = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                        ForEach(selectedShortcutNames, id: \.self) { name in
                            Button {
                                shortcutService.run(name)
                            } label: {
                                HStack(spacing: 4) {
                                    if shortcutService.runningName == name {
                                        ProgressView().controlSize(.mini).scaleEffect(0.6)
                                    } else {
                                        Image(systemName: shortcutService.lastCompletedName == name ? "checkmark.circle.fill" : "play.fill")
                                            .font(.system(size: 8, weight: .semibold))
                                    }
                                    Text(name)
                                        .font(.system(size: 9, weight: .medium))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 6)
                                .frame(height: 25)
                                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .disabled(shortcutService.runningName != nil)
                            .help("运行快捷指令：\(name)")
                        }
                    }
                    if let lastError = shortcutService.lastError {
                        Text(lastError)
                            .font(.system(size: 8))
                            .foregroundStyle(.red.opacity(0.9))
                    } else if let completed = shortcutService.lastCompletedName {
                        Text(shortcutService.lastOutput ?? "已完成：\(completed)")
                            .font(.system(size: 8))
                            .foregroundStyle(.green)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
            }
            .onAppear {
                shortcutService.scanIfNeeded()
            }
        case .codexUsage:
            VStack(alignment: .leading, spacing: 5) {
                if let usage = agentManager.codexUsage, usage.error == nil {
                    quotaRow(title: "5 小时", remaining: usage.fiveHourRemainingPercent)
                    quotaRow(title: "周额度", remaining: usage.weeklyRemainingPercent)
                } else {
                    Text(agentManager.codexUsage?.error == nil ? "Codex 任务启动后自动读取额度" : "暂时无法读取额度")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if agentManager.isRefreshingCodexUsage {
                    ProgressView().controlSize(.mini)
                }
            }
        }
    }

    private func quotaRow(title: String, remaining: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(remaining.map { "剩余 \($0)%" } ?? "—")
                    .fontWeight(.semibold)
            }
            .font(.system(size: 10))
            if let remaining {
                ProgressView(value: Double(remaining), total: 100)
                    .tint(remaining < 15 ? .orange : .white)
            }
        }
    }

    private func saveShortcutNames(_ names: [String]) {
        guard let data = try? JSONEncoder().encode(Array(names.prefix(4))),
              let encoded = String(data: data, encoding: .utf8)
        else { return }
        storedShortcutNames = encoded
    }
}

private struct ShortcutSelectionPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = ShortcutActionService.shared
    @State private var searchText = ""
    @State private var selection: [String]
    let onSave: ([String]) -> Void

    init(selectedNames: [String], onSave: @escaping ([String]) -> Void) {
        _selection = State(initialValue: Array(selectedNames.prefix(4)))
        self.onSave = onSave
    }

    private var filteredNames: [String] {
        guard !searchText.isEmpty else { return service.names }
        return service.names.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("快捷指令")
                        .font(.system(size: 13, weight: .semibold))
                    Text("选择最多 4 个，点击卡片时运行")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    service.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(service.isScanning)
            }

            TextField("搜索快捷指令", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if service.isScanning && service.names.isEmpty {
                ProgressView("正在读取快捷指令")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredNames.isEmpty {
                ContentUnavailableView(
                    "没有找到快捷指令",
                    systemImage: "bolt",
                    description: Text("请先在 macOS「快捷指令」App 中创建指令，再重新扫描。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filteredNames, id: \.self) { name in
                            let isSelected = selection.contains(name)
                            Button {
                                if isSelected {
                                    selection.removeAll { $0 == name }
                                } else if selection.count < 4 {
                                    selection.append(name)
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    Text(name)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 10))
                                .padding(.horizontal, 8)
                                .frame(height: 27)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!isSelected && selection.count >= 4)
                            .background(isSelected ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            HStack {
                Text("\(selection.count)/4 已选")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") {
                    onSave(selection)
                    dismiss()
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .onAppear { service.scanIfNeeded() }
    }
}
