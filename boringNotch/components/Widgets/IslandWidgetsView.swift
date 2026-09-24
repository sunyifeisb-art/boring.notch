import AppKit
import SwiftUI

struct IslandWidgetsView: View {
    @AppStorage("islandWidgetKinds") private var storedKinds = "clock,battery,calendar,agents"
    @AppStorage("islandDiscoveredWidgetIDs") private var storedWidgetIDs = ""
    @State private var calendarStatus = "点击授权后显示即将开始的日程"
    @State private var showingCatalog = false
    @ObservedObject private var catalogService = WidgetCatalogService.shared

    private var visibleKinds: [IslandWidgetKind] {
        storedKinds.split(separator: ",")
            .compactMap { IslandWidgetKind(rawValue: String($0)) }
    }

    private var availableKinds: [IslandWidgetKind] {
        IslandWidgetKind.allCases.filter { !visibleKinds.contains($0) }
    }

    private var selectedWidgets: [DiscoveredWidgetExtension] {
        let ids = Set(storedWidgetIDs.split(separator: ",").map(String.init))
        return catalogService.widgets.filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundStyle(.white.opacity(0.75))
                Text("灵动岛组件")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("从组件库选择可用组件")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    catalogService.scanIfNeeded()
                    showingCatalog = true
                } label: {
                    Label("组件库", systemImage: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .background(Color.white.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingCatalog, arrowEdge: .top) {
                    WidgetCatalogPicker(
                        selectedIDs: selectedWidgetIDs,
                        onToggle: toggleWidget,
                        onRefresh: { catalogService.scan() }
                    )
                    .frame(width: 370, height: 430)
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

            if visibleKinds.isEmpty && selectedWidgets.isEmpty {
                ContentUnavailableView("还没有组件", systemImage: "square.grid.2x2", description: Text("点击“组件库”选择应用组件，或从菜单添加内置卡片。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleKinds) { kind in
                            IslandWidgetCard(kind: kind, calendarStatus: calendarStatus) {
                                Task { await requestCalendarAccess() }
                            }
                            .frame(width: 136, height: 105)
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
                        ForEach(selectedWidgets) { widget in
                            DiscoveredWidgetCard(widget: widget)
                                .frame(width: 136, height: 105)
                                .contextMenu {
                                    Button("打开来源 App", systemImage: "arrow.up.forward.app") {
                                        openSourceApp(widget)
                                    }
                                    .disabled(widget.appURL == nil)
                                    Button("从灵动岛移除", systemImage: "minus.circle") {
                                        toggleWidget(widget)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .frame(height: 105)
            }

            Text("扫描只在打开组件库时进行。系统可识别应用提供的 Widget 扩展；第三方实时画面需应用公开适配接口。")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 1)
        .onAppear { catalogService.scanIfNeeded() }
    }

    private var selectedWidgetIDs: Set<String> {
        Set(storedWidgetIDs.split(separator: ",").map(String.init))
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

    private func toggleWidget(_ widget: DiscoveredWidgetExtension) {
        var ids = selectedWidgetIDs
        if ids.contains(widget.id) {
            ids.remove(widget.id)
        } else {
            ids.insert(widget.id)
        }
        storedWidgetIDs = ids.sorted().joined(separator: ",")
    }

    private func openSourceApp(_ widget: DiscoveredWidgetExtension) {
        guard let appURL = widget.appURL else { return }
        NSWorkspace.shared.open(appURL)
    }

    @MainActor
    private func requestCalendarAccess() async {
        await CalendarManager.shared.checkCalendarAuthorization()
        let events = CalendarManager.shared.events
            .filter { $0.end >= Date() }
            .sorted { $0.start < $1.start }
        if let event = events.first {
            calendarStatus = "\(event.title) · \(event.start.formatted(date: .omitted, time: .shortened))"
        } else {
            calendarStatus = "今天暂无即将开始的日程"
        }
    }
}

private struct WidgetCatalogPicker: View {
    @ObservedObject private var service = WidgetCatalogService.shared
    @State private var searchText = ""
    let selectedIDs: Set<String>
    let onToggle: (DiscoveredWidgetExtension) -> Void
    let onRefresh: () -> Void

    private var filteredWidgets: [DiscoveredWidgetExtension] {
        guard !searchText.isEmpty else { return service.widgets }
        return service.widgets.filter {
            $0.appName.localizedCaseInsensitiveContains(searchText)
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
                    Text(service.isScanning ? "正在扫描已安装的应用…" : "发现 \(service.widgets.count) 个 Widget 扩展")
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
                            Button {
                                onToggle(widget)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: (widget.appURL ?? widget.extensionURL).path))
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                        .clipShape(RoundedRectangle(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(widget.displayName)
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                        Text(widget.appName)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: selectedIDs.contains(widget.id) ? "checkmark.circle.fill" : "plus.circle")
                                        .foregroundStyle(selectedIDs.contains(widget.id) ? Color.green : Color.white.opacity(0.65))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }

                Text("系统只公开扩展清单，不提供跨 App 读取其实时视图与数据的接口。加入后会显示轻量入口卡片，可直接打开来源应用。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }
}

private struct DiscoveredWidgetCard: View {
    let widget: DiscoveredWidgetExtension

    var body: some View {
        Button {
            if let appURL = widget.appURL {
                NSWorkspace.shared.open(appURL)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: (widget.appURL ?? widget.extensionURL).path))
                        .resizable()
                        .frame(width: 17, height: 17)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(widget.appName)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(widget.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Label(widget.appURL == nil ? "系统组件扩展" : "打开来源应用", systemImage: widget.appURL == nil ? "puzzlepiece.extension" : "arrow.up.forward.app")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(9)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.07), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .disabled(widget.appURL == nil)
    }
}

private enum IslandWidgetKind: String, CaseIterable, Identifiable {
    case clock, battery, calendar, agents, media, downloads

    static let defaultKinds: [IslandWidgetKind] = [.clock, .battery, .calendar, .agents]
    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: "时间"
        case .battery: "电池"
        case .calendar: "日程"
        case .agents: "Agent 任务"
        case .media: "媒体"
        case .downloads: "下载"
        }
    }

    var symbol: String {
        switch self {
        case .clock: "clock"
        case .battery: "battery.100percent"
        case .calendar: "calendar"
        case .agents: "terminal"
        case .media: "music.note"
        case .downloads: "arrow.down.circle"
        }
    }
}

private struct IslandWidgetCard: View {
    let kind: IslandWidgetKind
    let calendarStatus: String
    let onCalendarAccess: () -> Void
    @ObservedObject private var agentManager = AgentSessionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(kind.title, systemImage: kind.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            content

            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .clock:
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                    Text(context.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        case .battery:
            BatteryWidgetValue()
        case .calendar:
            Button(action: onCalendarAccess) {
                Text(calendarStatus)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
        case .agents:
            let active = agentManager.agentSessions.filter { [.active, .inProgress, .pending].contains($0.status) }.count
            VStack(alignment: .leading, spacing: 3) {
                Text("\(active)")
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                Text("进行中的任务")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        case .media:
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: "playpause.fill")
                    .font(.system(size: 15))
                Text("媒体控制可在主页使用")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        case .downloads:
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15))
                Text("下载状态将在活动时显示")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BatteryWidgetValue: View {
    @ObservedObject private var battery = BatteryStatusViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(Int(battery.levelBattery))%")
                .font(.system(size: 22, weight: .medium, design: .rounded))
            Text(battery.isCharging ? "正在充电" : "电池电量")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}
