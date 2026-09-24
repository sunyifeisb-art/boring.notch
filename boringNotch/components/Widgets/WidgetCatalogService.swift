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
