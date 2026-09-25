import Foundation

enum ShortcutActionRunner {
    private struct ExecutionResult: Encodable {
        let output: String?
        let error: String?
    }

    private static let executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    private static let maximumShortcutResultBytes = 16 * 1024
    private static let maximumShortcutListBytes = 1024 * 1024

    static func shortcutNamesJSON() -> Data {
        let (output, succeeded) = runProcess(
            arguments: ["list"],
            timeout: 20,
            capturesOutput: true,
            maximumOutputBytes: maximumShortcutListBytes
        )
        guard succeeded,
              let text = String(data: output, encoding: .utf8)
        else { return Data("[]".utf8) }

        let names = Array(Set(text.split(whereSeparator: \.isNewline).compactMap { rawLine -> String? in
            let name = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (try? JSONEncoder().encode(names)) ?? Data("[]".utf8)
    }

    static func runJSON(name: String) -> Data {
        let result = executionResult(name: name)
        return (try? JSONEncoder().encode(result)) ?? Data("{}".utf8)
    }

    private static func executionResult(name: String) -> ExecutionResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName.count <= 256,
              !trimmedName.contains("\n"),
              !trimmedName.contains("\r")
        else { return ExecutionResult(output: nil, error: "快捷指令名称无效。") }

        let (data, succeeded) = runProcess(
            arguments: ["run", trimmedName],
            timeout: 180,
            capturesOutput: true,
            maximumOutputBytes: maximumShortcutResultBytes
        )
        guard succeeded else {
            return ExecutionResult(output: nil, error: "快捷指令执行失败或超时，请检查该指令的权限与运行状态。")
        }
        let rawOutput = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = rawOutput.isEmpty ? nil : String(rawOutput.prefix(1_000))
        return ExecutionResult(output: output, error: nil)
    }

    private static func runProcess(
        arguments: [String],
        timeout: TimeInterval,
        capturesOutput: Bool,
        maximumOutputBytes: Int
    ) -> (Data, Bool) {
        guard let process = makeProcess(arguments: arguments, capturesOutput: capturesOutput) else { return (Data(), false) }
        let outputPipe = process.standardOutput as? Pipe
        do {
            try process.run()
            let timeoutWork = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            var output = Data()
            if let outputPipe {
                let handle = outputPipe.fileHandleForReading
                while true {
                    let chunk = handle.readData(ofLength: 4 * 1024)
                    guard !chunk.isEmpty else { break }
                    let remainingCapacity = maximumOutputBytes - output.count
                    if remainingCapacity > 0 {
                        output.append(contentsOf: chunk.prefix(remainingCapacity))
                    }
                    // Continue draining after the capture limit so a verbose
                    // shortcut cannot block on a full pipe or grow memory.
                }
            }
            process.waitUntilExit()
            timeoutWork.cancel()
            let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
            return (output, succeeded)
        } catch {
            return (Data(), false)
        }
    }

    private static func makeProcess(arguments: [String], capturesOutput: Bool) -> Process? {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return nil }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if capturesOutput {
            process.standardOutput = Pipe()
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = FileHandle.nullDevice
        return process
    }

}
