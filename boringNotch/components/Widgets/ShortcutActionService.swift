import Combine
import Foundation

struct ShortcutActionExecution: Codable {
    let output: String?
    let error: String?
}

@MainActor
final class ShortcutActionService: ObservableObject {
    static let shared = ShortcutActionService()

    @Published private(set) var names: [String] = []
    @Published private(set) var isScanning = false
    @Published private(set) var runningName: String?
    @Published private(set) var lastCompletedName: String?
    @Published private(set) var lastOutput: String?
    @Published private(set) var lastError: String?

    private var hasScanned = false

    private init() {}

    func scanIfNeeded() {
        guard !hasScanned else { return }
        scan()
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let data = await XPCHelperClient.shared.shortcutNamesJSON()
            let result = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            names = result
            hasScanned = true
            isScanning = false
        }
    }

    func run(_ name: String) {
        guard runningName == nil, names.contains(name) else { return }
        runningName = name
        lastCompletedName = nil
        lastOutput = nil
        lastError = nil
        Task {
            let data = await XPCHelperClient.shared.runShortcut(name)
            let result = try? JSONDecoder().decode(ShortcutActionExecution.self, from: data)
            runningName = nil
            guard let result else {
                lastError = "无法读取快捷指令的执行结果。"
                return
            }
            if let error = result.error {
                lastError = error
            } else {
                lastCompletedName = name
                lastOutput = result.output
            }
        }
    }
}
