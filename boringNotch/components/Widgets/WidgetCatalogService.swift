import Combine
import Foundation

struct DiscoveredWidgetExtension: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let appName: String
    let extensionName: String
    let appBundleIdentifier: String
    let appURL: URL?
    let extensionURL: URL

    var displayName: String {
        extensionName.isEmpty || extensionName == appBundleIdentifier ? appName : extensionName
    }

    var localizedAppName: String {
        if appURL == nil, appBundleIdentifier.hasPrefix("com.apple.") { return "macOS 系统" }
        return Self.localizedAppLabel(appName)
    }
    var localizedDisplayName: String { Self.localizedWidgetLabel(displayName, appName: localizedAppName) }

    private static func localizedAppLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownNames: [String: String] = [
            "Calendar": "日历", "Clock": "时钟", "Batteries": "电池", "Battery": "电池",
            "Weather": "天气", "Reminders": "提醒事项", "Notes": "备忘录", "Photos": "照片",
            "Stocks": "股票", "News": "新闻", "Screen Time": "屏幕使用时间", "Podcasts": "播客",
            "Music": "音乐", "Maps": "地图", "Contacts": "通讯录", "Home": "家庭",
            "Find My": "查找", "Calculator": "计算器"
        ]
        if let localized = knownNames[trimmed] { return localized }
        return trimmed
    }

    private static func localizedWidgetLabel(_ value: String, appName: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = "\(trimmed) \(appName)".lowercased()
        let labels: [(String, String)] = [
            ("calendar", "日历"), ("world clock", "世界时钟"), ("clock", "时钟"),
            ("airbattery", "耳机电量"), ("batter", "电池"),
            ("weather", "天气"), ("reminder", "提醒事项"),
            ("note", "备忘录"), ("photo", "照片"), ("relive", "照片回忆"),
            ("stock", "股票"), ("news", "新闻"), ("screentime", "屏幕使用时间"),
            ("podcast", "播客"), ("music", "音乐"), ("map", "地图"),
            ("contact", "通讯录"), ("findmywidgetitems", "查找物品"),
            ("findmywidgetpeople", "查找联系人"), ("homeenergy", "家庭能源"),
            ("homewidget", "家庭"), ("calculator", "计算器"),
            ("airdrop", "隔空投送"), ("accessibility", "辅助功能"),
            ("appearance", "外观设置"), ("bluetooth", "蓝牙设置"),
            ("controlcenter", "控制中心"), ("date&time", "日期与时间"),
            ("desktopsettings", "桌面设置"), ("display", "显示器设置"),
            ("loginitems", "登录项"), ("mouse", "鼠标设置"),
            ("notification", "通知设置"), ("printer", "打印机与扫描仪"),
            ("macwidget", "1Blocker 小组件"), ("bettertouchtool", "BetterTouchTool 小组件"),
            ("excel", "Excel"), ("outlook", "Outlook"), ("powerpoint", "PowerPoint"),
            ("wordwidget", "Word")
        ]
        if let (_, label) = labels.first(where: { normalized.contains($0.0) }) {
            return label
        }
        if trimmed.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
            return trimmed
        }
        // Internal bundle names such as CalendarWidgetExtension are not
        // user-facing titles. Fall back to the readable application name.
        return appName.isEmpty ? "应用小组件" : "\(appName) 小组件"
    }
}

@MainActor
final class WidgetCatalogService: ObservableObject {
    static let shared = WidgetCatalogService()

    @Published private(set) var widgets: [DiscoveredWidgetExtension] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanDate: Date?

    private init() {}

    func scanIfNeeded() {
        guard lastScanDate == nil else { return }
        scan()
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true

        Task {
            let data = await XPCHelperClient.shared.widgetCatalogJSON()
            widgets = (try? JSONDecoder().decode([DiscoveredWidgetExtension].self, from: data)) ?? []
            lastScanDate = Date()
            isScanning = false
        }
    }
}
