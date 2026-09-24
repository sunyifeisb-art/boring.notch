import Foundation

private struct WidgetCatalogRecord: Codable {
    let id: String
    let appName: String
    let extensionName: String
    let appBundleIdentifier: String
    let appURL: URL?
    let extensionURL: URL
}

enum WidgetCatalogScanner {
    private static let widgetExtensionPoint = "com.apple.widgetkit-extension"

    static func scan() -> Data {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true),
            URL(fileURLWithPath: "/Library/Apple/System/Library/Extensions", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            home.appendingPathComponent("Library/Extensions", isDirectory: true)
        ]
        let mountedVolumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsRemovableKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        roots += mountedVolumes.map { $0.appendingPathComponent("Applications", isDirectory: true) }

        var results: [String: WidgetCatalogRecord] = [:]
        for root in roots where fileManager.fileExists(atPath: root.path) {
            if root.pathExtension == "appex" {
                if let widget = makeWidget(from: root, appURL: nil) { results[widget.id] = widget }
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                if url.pathExtension == "appex" {
                    if let widget = makeWidget(from: url, appURL: nil) { results[widget.id] = widget }
                    continue
                }
                guard url.pathExtension == "app" else { continue }

                for appex in extensionBundles(in: url) {
                    if let widget = makeWidget(from: appex, appURL: url) { results[widget.id] = widget }
                }

                // Some apps bundle the actual app and its widgets inside Wrapper.
                let wrapper = url.appendingPathComponent("Contents/Wrapper", isDirectory: true)
                guard let nestedApps = fileManager.enumerator(
                    at: wrapper,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let nestedURL as URL in nestedApps where nestedURL.pathExtension == "app" {
                    for appex in extensionBundles(in: nestedURL) {
                        if let widget = makeWidget(from: appex, appURL: nestedURL) { results[widget.id] = widget }
                    }
                }
            }
        }

        let sorted = results.values.sorted {
            let comparison = $0.appName.localizedCaseInsensitiveCompare($1.appName)
            return comparison == .orderedSame
                ? $0.extensionName.localizedCaseInsensitiveCompare($1.extensionName) == .orderedAscending
                : comparison == .orderedAscending
        }
        return (try? JSONEncoder().encode(sorted)) ?? Data("[]".utf8)
    }

    private static func extensionBundles(in appURL: URL) -> [URL] {
        let candidateDirectories = [
            appURL.appendingPathComponent("Contents/PlugIns", isDirectory: true),
            appURL.appendingPathComponent("Contents/Extensions", isDirectory: true),
            appURL.appendingPathComponent("PlugIns", isDirectory: true)
        ]
        return candidateDirectories.flatMap { directory -> [URL] in
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return children.filter { $0.pathExtension == "appex" }
        }
    }

    private static func makeWidget(from extensionURL: URL, appURL: URL?) -> WidgetCatalogRecord? {
        guard
            let extensionInfo = readInfoPlist(at: extensionURL),
            let extensionDetails = extensionInfo["NSExtension"] as? [String: Any],
            extensionDetails["NSExtensionPointIdentifier"] as? String == widgetExtensionPoint
        else { return nil }

        let resolvedAppURL = appURL ?? containingApp(for: extensionURL)
        let appInfo = resolvedAppURL.flatMap(readInfoPlist(at:)) ?? [:]
        let appBundleIdentifier = appInfo["CFBundleIdentifier"] as? String
            ?? extensionInfo["NSExtensionIdentifier"] as? String
            ?? extensionURL.deletingPathExtension().lastPathComponent
        let appName = (appInfo["CFBundleDisplayName"] as? String)
            ?? (appInfo["CFBundleName"] as? String)
            ?? resolvedAppURL?.deletingPathExtension().lastPathComponent
            ?? (extensionInfo["CFBundleDisplayName"] as? String)
            ?? appBundleIdentifier
        let extensionBundleIdentifier = extensionInfo["CFBundleIdentifier"] as? String ?? extensionURL.lastPathComponent
        let extensionName = (extensionInfo["CFBundleDisplayName"] as? String)
            ?? (extensionInfo["CFBundleName"] as? String)
            ?? ""

        return WidgetCatalogRecord(
            id: extensionBundleIdentifier,
            appName: appName,
            extensionName: extensionName,
            appBundleIdentifier: appBundleIdentifier,
            appURL: resolvedAppURL,
            extensionURL: extensionURL
        )
    }

    private static func containingApp(for extensionURL: URL) -> URL? {
        var parent = extensionURL.deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension == "app" { return parent }
            parent.deleteLastPathComponent()
        }
        return nil
    }

    private static func readInfoPlist(at bundleURL: URL) -> [String: Any]? {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        return dictionary
    }
}
