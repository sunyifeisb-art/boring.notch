//
//  AgentBridgeService.swift
//  BoringNotchXPCHelper
//
//  Native Swift port of the local hook/session protocol used by Vibe Island.
//  The XPC helper owns the socket because the main app is sandboxed.
//

import Darwin
import Foundation

private enum BridgeJSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: BridgeJSONValue])
    case array([BridgeJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: BridgeJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([BridgeJSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct BridgeHookEvent: Decodable {
    let sessionID: String
    let hookEventName: String
    let cwd: String?
    let toolName: String?
    let toolInput: BridgeJSONValue?
    let prompt: String?
    let lastAssistantMessage: String?
    let title: String?
    let source: String?
    let environment: [String: String]?
    let tty: String?
    let terminalBundleID: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case prompt
        case lastAssistantMessage = "last_assistant_message"
        case title = "codex_title"
        case source = "_source"
        case environment = "_env"
        case tty = "_tty"
        case terminalBundleID = "terminal_bundle_id"
    }
}

private enum BridgeSessionStatus: String, Codable {
    case active
    case idle
    case pending
    case inProgress = "in_progress"
    case completed
    case waitingForApproval = "waiting_for_approval"
    case waitingForAnswer = "waiting_for_answer"
}

private struct BridgeSession: Codable {
    let id: String
    var source: String
    var status: BridgeSessionStatus
    var cwd: String?
    var lastUserText: String?
    var lastAssistantMessage: String?
    var toolName: String?
    var toolInput: BridgeJSONValue?
    var title: String?
    var environment: [String: String]
    var tty: String?
    var terminalBundleID: String?
    var resumeID: String?
    var isManaged: Bool
    var messages: [BridgeMessage]
    let startedAt: Date
    var lastActivity: Date
}

private struct BridgeMessage: Codable {
    let id: UUID
    var role: String
    var text: String
    let createdAt: Date
}

private struct ClaudeStreamEvent {
    var delta: String?
    var snapshot: String?
    var result: String?
    var sessionID: String?
    var failed: Bool?
}

private final class AgentDataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

final class AgentBridgeService {
    private let stateQueue = DispatchQueue(label: "theboringteam.boringnotch.agent-bridge.state")
    private var sessions: [String: BridgeSession] = [:]
    private var pendingConnections: [String: Int32] = [:]
    private var runningProcesses: [String: Process] = [:]
    private var socketServer: AgentUnixSocketServer?
    private let commandQueue = DispatchQueue(label: "theboringteam.boringnotch.agent-bridge.commands", attributes: .concurrent)

    private static var baseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".boring-notch", isDirectory: true)
    }

    private static var socketURL: URL {
        baseDirectory.appendingPathComponent("run/agent-bridge.sock")
    }

    func start() throws {
        try stateQueue.sync {
            guard socketServer == nil else { return }
            let runDirectory = Self.socketURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            let server = try AgentUnixSocketServer(path: Self.socketURL.path) { [weak self] data, descriptor in
                self?.handle(data: data, descriptor: descriptor)
            }
            socketServer = server
            server.start()
        }
    }

    func stop() {
        stateQueue.sync {
            socketServer?.stop()
            socketServer = nil
            pendingConnections.values.forEach { Darwin.close($0) }
            pendingConnections.removeAll()
            runningProcesses.values.forEach { $0.terminate() }
            runningProcesses.removeAll()
        }
    }

    func sessionsJSON() -> Data {
        stateQueue.sync {
            let staleCutoff = Date().addingTimeInterval(-12 * 60 * 60)
            sessions = sessions.filter { _, session in
                session.status == .waitingForApproval || session.status == .waitingForAnswer || session.lastActivity > staleCutoff
            }
            let ordered = sessions.values.sorted {
                let lhsAttention = $0.status == .waitingForApproval || $0.status == .waitingForAnswer
                let rhsAttention = $1.status == .waitingForApproval || $1.status == .waitingForAnswer
                if lhsAttention != rhsAttention { return lhsAttention }
                return $0.lastActivity > $1.lastActivity
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return (try? encoder.encode(ordered)) ?? Data("[]".utf8)
        }
    }

    func respond(sessionID: String, response: Data) -> Bool {
        stateQueue.sync {
            guard let descriptor = pendingConnections.removeValue(forKey: sessionID) else { return false }
            response.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                _ = Darwin.send(descriptor, baseAddress, bytes.count, 0)
            }
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            if var session = sessions[sessionID] {
                session.status = .inProgress
                session.lastActivity = Date()
                sessions[sessionID] = session
            }
            return true
        }
    }

    func jumpToTerminal(sessionID: String) -> Bool {
        guard let session = stateQueue.sync(execute: { sessions[sessionID] }) else { return false }
        let tty = session.tty ?? ""
        let termProgram = session.environment["TERM_PROGRAM"]?.lowercased() ?? ""

        if !tty.isEmpty, session.environment["TMUX"] != nil {
            _ = focusTMUXPane(tty: tty)
        }

        if let paneID = session.environment["WEZTERM_PANE"],
           let wezterm = executableURL(named: "wezterm"),
           run(wezterm.path, arguments: ["cli", "activate-pane", "--pane-id", paneID])
        {
            _ = run("/usr/bin/open", arguments: ["-b", "com.github.wez.wezterm"])
            return true
        }

        if let listenAddress = session.environment["KITTY_LISTEN_ON"],
           let kitty = executableURL(named: "kitty"),
           run(kitty.path, arguments: ["@", "--to", listenAddress, "focus-window"])
        {
            return true
        }

        if !tty.isEmpty && (termProgram.contains("iterm") || session.terminalBundleID == "com.googlecode.iterm2") {
            let script = """
            tell application "iTerm2"
                activate
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            if tty of aSession is "\(appleScriptEscaped(tty))" then
                                select aTab
                                select aSession
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
            if run("/usr/bin/osascript", arguments: ["-e", script]) { return true }
        }

        if !tty.isEmpty && (termProgram.contains("apple_terminal") || session.terminalBundleID == "com.apple.Terminal") {
            let script = """
            tell application "Terminal"
                activate
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        if tty of aTab is "\(appleScriptEscaped(tty))" then
                            set selected tab of aWindow to aTab
                            set index of aWindow to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
            if run("/usr/bin/osascript", arguments: ["-e", script]) { return true }
        }

        let bundleID = session.terminalBundleID ?? bundleID(for: termProgram, source: session.source)
        guard let bundleID else { return false }
        return run("/usr/bin/open", arguments: ["-b", bundleID])
    }

    func sendMessage(sessionID: String?, source: String, cwd: String?, message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var launchRequest: (id: String, source: String, cwd: String?, resumeID: String?, prompt: String)?
        let resultID: String? = stateQueue.sync {
            let existing = sessionID.flatMap { sessions[$0] }
            let resolvedSource = existing?.source ?? source.lowercased()
            let resolvedCWD = existing?.cwd ?? cwd

            guard resolvedSource == "claude" else {
                if let sessionID {
                    appendSystemMessage("Direct chat is available for Claude Code sessions.", to: sessionID, status: existing?.status ?? .idle)
                    return sessionID
                }
                return nil
            }

            if trimmed == "/stop", let sessionID {
                runningProcesses[sessionID]?.terminate()
                runningProcesses.removeValue(forKey: sessionID)
                appendSystemMessage("Stopped the current agent run.", to: sessionID, status: .idle)
                return sessionID
            }

            if trimmed == "/current", let sessionID, let session = sessions[sessionID] {
                let summary = "\(session.source.capitalized) · \(session.status.rawValue) · \(session.cwd ?? "No working directory")"
                appendSystemMessage(summary, to: sessionID, status: session.status)
                return sessionID
            }

            if trimmed == "/history", let sessionID, let session = sessions[sessionID] {
                let history = session.messages.suffix(6).map { message in
                    "\(message.role.capitalized): \(message.text)"
                }.joined(separator: "\n")
                appendSystemMessage(history.isEmpty ? "No conversation history yet." : history, to: sessionID, status: session.status)
                return sessionID
            }

            if trimmed == "/list", let sessionID {
                let available = sessions.values
                    .filter { $0.source == "claude" }
                    .sorted { $0.lastActivity > $1.lastActivity }
                    .enumerated()
                    .map { index, item in "\(index + 1). \(item.title ?? item.cwd ?? item.id) [\(item.status.rawValue)]" }
                    .joined(separator: "\n")
                appendSystemMessage(available.isEmpty ? "No Claude sessions." : available, to: sessionID, status: sessions[sessionID]?.status ?? .idle)
                return sessionID
            }

            if trimmed.hasPrefix("/switch ") {
                let selector = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                let available = sessions.values
                    .filter { $0.source == "claude" }
                    .sorted { $0.lastActivity > $1.lastActivity }
                let target: BridgeSession?
                if let index = Int(selector), available.indices.contains(index - 1) {
                    target = available[index - 1]
                } else {
                    target = available.first { $0.id == selector || $0.resumeID == selector }
                }
                if let target {
                    appendSystemMessage("Switched to \(target.title ?? target.cwd ?? target.id).", to: target.id, status: target.status)
                    return target.id
                }
                if let sessionID {
                    appendSystemMessage("Claude session not found: \(selector)", to: sessionID, status: sessions[sessionID]?.status ?? .idle)
                    return sessionID
                }
                return nil
            }

            if trimmed == "/help", let sessionID {
                appendSystemMessage("Commands: /new [prompt], /clear, /stop, /current, /list, /switch <number|id>, /history, /compact, /dir <path>, /help", to: sessionID, status: sessions[sessionID]?.status ?? .idle)
                return sessionID
            }

            if trimmed.hasPrefix("/dir "), let sessionID {
                let requestedPath = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                let base = URL(fileURLWithPath: resolvedCWD ?? FileManager.default.homeDirectoryForCurrentUser.path)
                let target = URL(fileURLWithPath: requestedPath, relativeTo: base).standardizedFileURL
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    sessions[sessionID]?.cwd = target.path
                    appendSystemMessage("Working directory changed to \(target.path).", to: sessionID, status: .idle)
                } else {
                    appendSystemMessage("Directory does not exist: \(target.path)", to: sessionID, status: sessions[sessionID]?.status ?? .idle)
                }
                return sessionID
            }

            let startsNew = trimmed == "/clear" || trimmed == "/new" || trimmed.hasPrefix("/new ") || existing == nil
            let targetID: String
            var prompt = trimmed
            if startsNew {
                targetID = "managed-\(resolvedSource)-\(UUID().uuidString.lowercased())"
                if trimmed == "/clear" || trimmed == "/new" {
                    prompt = ""
                } else if trimmed.hasPrefix("/new ") {
                    prompt = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                sessions[targetID] = BridgeSession(
                    id: targetID,
                    source: resolvedSource,
                    status: prompt.isEmpty ? .idle : .inProgress,
                    cwd: resolvedCWD,
                    lastUserText: prompt.isEmpty ? nil : prompt,
                    lastAssistantMessage: nil,
                    toolName: nil,
                    toolInput: nil,
                    title: prompt.isEmpty ? "New \(resolvedSource.capitalized) session" : String(prompt.prefix(42)),
                    environment: [:],
                    tty: nil,
                    terminalBundleID: nil,
                    resumeID: nil,
                    isManaged: true,
                    messages: prompt.isEmpty ? [] : [BridgeMessage(id: UUID(), role: "user", text: prompt, createdAt: Date())],
                    startedAt: Date(),
                    lastActivity: Date()
                )
            } else {
                guard let sessionID else { return nil }
                targetID = sessionID
                if trimmed == "/compact" {
                    prompt = "Compact the conversation context now. Preserve the current objective, decisions, constraints, completed work, and remaining tasks, then continue from the compacted context."
                }
                sessions[targetID]?.messages.append(BridgeMessage(id: UUID(), role: "user", text: prompt, createdAt: Date()))
                sessions[targetID]?.lastUserText = prompt
                sessions[targetID]?.status = .inProgress
                sessions[targetID]?.lastActivity = Date()
            }

            guard !prompt.isEmpty else { return targetID }
            launchRequest = (targetID, resolvedSource, resolvedCWD, startsNew ? nil : (existing?.resumeID ?? existing?.id), prompt)
            return targetID
        }

        if let launchRequest {
            commandQueue.async { [weak self] in
                self?.runAgent(
                    sessionID: launchRequest.id,
                    source: launchRequest.source,
                    cwd: launchRequest.cwd,
                    resumeID: launchRequest.resumeID,
                    prompt: launchRequest.prompt
                )
            }
        }
        return resultID
    }

    private func runAgent(sessionID: String, source: String, cwd: String?, resumeID: String?, prompt: String) {
        guard source == "claude" else { return }
        guard let executable = executableURL(named: "claude") else {
            completeAgentRun(
                sessionID: sessionID,
                response: "Claude Code was not found. Install it or make the `claude` executable available in a standard bin directory.",
                resumeID: nil,
                failed: true
            )
            return
        }

        let process = Process()
        process.executableURL = executable
        var arguments: [String] = []
        if let resumeID, !resumeID.hasPrefix("managed-") {
            arguments += ["--resume", resumeID]
        }
        arguments += [
            "--print",
            "--verbose",
            "--output-format", "stream-json",
            "--include-partial-messages",
            prompt
        ]
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["BORING_NOTCH_MANAGED_SESSION_ID"] = sessionID
        environment["BORING_NOTCH_SOURCE"] = "claude"
        process.environment = environment

        if let cwd {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
            }
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let errorCapture = AgentDataCapture()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorCapture.append(handle.availableData)
        }

        do {
            try process.run()
            stateQueue.sync { runningProcesses[sessionID] = process }
            let streamMessageID = UUID()
            beginAgentStream(sessionID: sessionID, messageID: streamMessageID)

            var lineBuffer = Data()
            var fallbackLines: [String] = []
            var finalText: String?
            var latestSnapshot: String?
            var resolvedSessionID: String?
            var streamFailed = false

            func consumeLine(_ line: Data) {
                guard !line.isEmpty else { return }
                guard let event = parseClaudeStreamLine(line) else {
                    if let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty
                    {
                        fallbackLines.append(text)
                    }
                    return
                }
                if let delta = event.delta, !delta.isEmpty {
                    appendAgentStream(delta, sessionID: sessionID, messageID: streamMessageID)
                }
                if let snapshot = event.snapshot, !snapshot.isEmpty { latestSnapshot = snapshot }
                if let result = event.result, !result.isEmpty { finalText = result }
                if let eventSessionID = event.sessionID, !eventSessionID.isEmpty { resolvedSessionID = eventSessionID }
                if event.failed == true { streamFailed = true }
            }

            while true {
                let chunk = outputPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                lineBuffer.append(chunk)
                while let newline = lineBuffer.firstIndex(of: 0x0A) {
                    let line = lineBuffer.prefix(upTo: newline)
                    consumeLine(Data(line))
                    lineBuffer.removeSubrange(...newline)
                }
            }
            if !lineBuffer.isEmpty { consumeLine(lineBuffer) }
            process.waitUntilExit()
            errorPipe.fileHandleForReading.readabilityHandler = nil
            errorCapture.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            let errorText = String(data: errorCapture.snapshot, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completeAgentRun(
                sessionID: sessionID,
                response: finalText ?? latestSnapshot ?? fallbackLines.last ?? errorText,
                resumeID: resolvedSessionID,
                failed: process.terminationStatus != 0 || streamFailed,
                streamMessageID: streamMessageID
            )
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            completeAgentRun(
                sessionID: sessionID,
                response: error.localizedDescription,
                resumeID: nil,
                failed: true,
                streamMessageID: nil
            )
        }
    }

    private func beginAgentStream(sessionID: String, messageID: UUID) {
        stateQueue.async { [weak self] in
            guard let self, var session = self.sessions[sessionID] else { return }
            session.messages.append(BridgeMessage(id: messageID, role: "assistant", text: "", createdAt: Date()))
            session.status = .inProgress
            session.lastActivity = Date()
            self.sessions[sessionID] = session
        }
    }

    private func appendAgentStream(_ delta: String, sessionID: String, messageID: UUID) {
        stateQueue.async { [weak self] in
            guard let self, var session = self.sessions[sessionID],
                  let index = session.messages.firstIndex(where: { $0.id == messageID })
            else { return }
            session.messages[index].text += delta
            session.lastAssistantMessage = session.messages[index].text
            session.status = .inProgress
            session.lastActivity = Date()
            self.sessions[sessionID] = session
        }
    }

    private func completeAgentRun(
        sessionID: String,
        response: String?,
        resumeID: String?,
        failed: Bool,
        streamMessageID: UUID? = nil
    ) {
        stateQueue.async { [weak self] in
            guard let self, var session = self.sessions[sessionID] else { return }
            self.runningProcesses.removeValue(forKey: sessionID)
            let cleaned = response?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let streamMessageID,
               let index = session.messages.firstIndex(where: { $0.id == streamMessageID })
            {
                if let cleaned, !cleaned.isEmpty {
                    session.messages[index].text = cleaned
                } else if session.messages[index].text.isEmpty {
                    session.messages[index].text = failed ? "Claude Code stopped with an error." : "No response"
                }
                session.messages[index].role = failed ? "error" : "assistant"
                session.lastAssistantMessage = session.messages[index].text
            } else {
                let text = (cleaned?.isEmpty == false ? cleaned : nil) ?? (failed ? "Claude Code stopped with an error." : "No response")
                session.messages.append(
                    BridgeMessage(id: UUID(), role: failed ? "error" : "assistant", text: text, createdAt: Date())
                )
                session.lastAssistantMessage = text
            }
            session.resumeID = resumeID ?? session.resumeID
            session.status = failed ? .idle : .completed
            session.lastActivity = Date()
            self.sessions[sessionID] = session
        }
    }

    private func appendSystemMessage(_ text: String, to sessionID: String, status: BridgeSessionStatus) {
        guard var session = sessions[sessionID] else { return }
        session.messages.append(BridgeMessage(id: UUID(), role: "system", text: text, createdAt: Date()))
        session.status = status
        session.lastActivity = Date()
        sessions[sessionID] = session
    }

    private func parseClaudeStreamLine(_ data: Data) -> ClaudeStreamEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var parsed = ClaudeStreamEvent()
        parsed.sessionID = object["session_id"] as? String

        switch object["type"] as? String {
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { break }
            if event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta"
            {
                parsed.delta = delta["text"] as? String
            } else if event["type"] as? String == "content_block_start",
                      let content = event["content_block"] as? [String: Any],
                      content["type"] as? String == "text"
            {
                parsed.delta = content["text"] as? String
            }
        case "assistant":
            if let message = object["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]]
            {
                parsed.snapshot = content.compactMap { block in
                    block["type"] as? String == "text" ? block["text"] as? String : nil
                }.joined()
            }
        case "result":
            parsed.result = object["result"] as? String
            parsed.failed = object["is_error"] as? Bool
        default:
            break
        }

        return parsed
    }

    private func executableURL(named name: String) -> URL? {
        if name == "claude",
           let override = ProcessInfo.processInfo.environment["BORING_NOTCH_CLAUDE_PATH"],
           FileManager.default.isExecutableFile(atPath: override)
        {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent(".local/bin/\(name)").path,
            home.appendingPathComponent(".claude/local/bin/\(name)").path,
            home.appendingPathComponent(".npm-global/bin/\(name)").path,
            home.appendingPathComponent(".bun/bin/\(name)").path,
            "/Applications/Claude.app/Contents/MacOS/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    func installHooks() -> [String] {
        do {
            let hookDirectory = Self.baseDirectory.appendingPathComponent("hooks", isDirectory: true)
            try FileManager.default.createDirectory(at: hookDirectory, withIntermediateDirectories: true)
            let hookURL = hookDirectory.appendingPathComponent("agent-hook.py")
            try Data(Self.pythonHook.utf8).write(to: hookURL, options: .atomic)
            _ = chmod(hookURL.path, 0o755)

            var results: [String] = []
            results.append(installClaudeHook(script: hookURL))
            results.append(installCodexHook(script: hookURL))
            results.append(installGeminiHook(script: hookURL))
            results.append(installCursorHook(script: hookURL))
            results.append(installOpenCodePlugin())
            results.append(installJavaScriptPlugin(tool: "Amp", directory: ".amp/plugins", fileName: "boring-notch.js", contents: Self.ampPlugin))
            results.append(installJavaScriptPlugin(tool: "Hermes", directory: ".hermes/plugins", fileName: "boring-notch.js", contents: Self.hermesPlugin))
            results.append(installKiroHook(script: hookURL))
            results.append(installKimiHook(script: hookURL))
            results.append(installSimpleJSONHook(tool: "Droid", directory: ".droid", config: "config.json", key: "boring_notch_hook", source: "droid", script: hookURL))
            results.append(installSimpleJSONHook(tool: "Windsurf", directory: ".windsurf", config: "settings.json", key: "boring_notch_hook", source: "windsurf", script: hookURL))
            results.append(installSimpleJSONHook(tool: "CodeBuddy", directory: ".codebuddy", config: "config.json", key: "boring_notch_hook", source: "codebuddy", script: hookURL))
            results.append(installSimpleJSONHook(tool: "Qoder", directory: ".qoder", config: "config.json", key: "boring_notch_hook", source: "qoder", script: hookURL))
            results.append(installClineHook(script: hookURL))
            results.append(installPiHook(script: hookURL))
            results.append(installCopilotHook(script: hookURL))
            return results
        } catch {
            return ["Hook install failed: \(error.localizedDescription)"]
        }
    }

    private func handle(data: Data, descriptor: Int32) {
        stateQueue.async { [weak self] in
            guard let self else {
                Darwin.close(descriptor)
                return
            }
            guard let event = try? JSONDecoder().decode(BridgeHookEvent.self, from: data), !event.sessionID.isEmpty else {
                Darwin.close(descriptor)
                return
            }

            let now = Date()
            var session = self.sessions[event.sessionID] ?? BridgeSession(
                id: event.sessionID,
                source: event.source ?? "agent",
                status: .active,
                cwd: event.cwd,
                lastUserText: nil,
                lastAssistantMessage: nil,
                toolName: nil,
                toolInput: nil,
                title: event.title,
                environment: event.environment ?? [:],
                tty: event.tty,
                terminalBundleID: event.terminalBundleID,
                resumeID: event.sessionID,
                isManaged: false,
                messages: [],
                startedAt: now,
                lastActivity: now
            )

            session.source = event.source ?? session.source
            session.cwd = event.cwd ?? session.cwd
            session.environment.merge(event.environment ?? [:]) { _, new in new }
            session.tty = event.tty ?? session.tty
            session.terminalBundleID = event.terminalBundleID ?? session.terminalBundleID
            session.lastActivity = now

            let eventName = self.normalizedEventName(event.hookEventName)
            var holdsConnection = false
            switch eventName {
            case "SessionEnd":
                if session.isManaged {
                    session.status = .idle
                    self.sessions[event.sessionID] = session
                } else {
                    self.sessions.removeValue(forKey: event.sessionID)
                }
                if let pending = self.pendingConnections.removeValue(forKey: event.sessionID) { Darwin.close(pending) }
            case "SessionStart":
                if session.status != .waitingForApproval && session.status != .waitingForAnswer {
                    session.status = .active
                }
                self.sessions[event.sessionID] = session
            case "UserPromptSubmit":
                session.lastUserText = event.prompt
                if session.status != .waitingForApproval && session.status != .waitingForAnswer {
                    session.status = .inProgress
                }
                self.sessions[event.sessionID] = session
            case "PreToolUse":
                session.toolName = event.toolName
                session.toolInput = event.toolInput
                if session.status != .waitingForApproval && session.status != .waitingForAnswer {
                    session.status = .inProgress
                }
                self.sessions[event.sessionID] = session
            case "PostToolUse":
                session.toolName = nil
                session.toolInput = nil
                session.status = .inProgress
                self.sessions[event.sessionID] = session
            case "PermissionRequest":
                session.toolName = event.toolName
                session.toolInput = event.toolInput
                session.status = event.toolName == "AskUserQuestion" ? .waitingForAnswer : .waitingForApproval
                self.sessions[event.sessionID] = session
                if let old = self.pendingConnections.updateValue(descriptor, forKey: event.sessionID) { Darwin.close(old) }
                holdsConnection = true
                self.schedulePermissionTimeout(sessionID: event.sessionID, descriptor: descriptor)
            case "Stop":
                session.status = .idle
                session.lastAssistantMessage = event.lastAssistantMessage ?? session.lastAssistantMessage
                session.title = event.title ?? session.title
                session.toolName = nil
                session.toolInput = nil
                self.sessions[event.sessionID] = session
            default:
                self.sessions[event.sessionID] = session
            }

            if !holdsConnection { Darwin.close(descriptor) }
        }
    }

    private func schedulePermissionTimeout(sessionID: String, descriptor: Int32) {
        stateQueue.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self, self.pendingConnections[sessionID] == descriptor else { return }
            self.pendingConnections.removeValue(forKey: sessionID)
            Darwin.close(descriptor)
            if var session = self.sessions[sessionID] {
                session.status = .idle
                session.lastActivity = Date()
                self.sessions[sessionID] = session
            }
        }
    }

    private func normalizedEventName(_ name: String) -> String {
        switch name.lowercased() {
        case "session.start", "session_start", "sessionstart": return "SessionStart"
        case "session.end", "session_end", "sessionend": return "SessionEnd"
        case "tool.start", "beforetool", "pre_tool_use", "pretooluse": return "PreToolUse"
        case "tool.end", "aftertool", "post_tool_use", "posttooluse": return "PostToolUse"
        case "permissionrequest", "permission_request": return "PermissionRequest"
        case "userpromptsubmit", "user_prompt_submit": return "UserPromptSubmit"
        case "stop", "turn.end", "turn_end": return "Stop"
        default: return name
        }
    }

    private func installClaudeHook(script: URL) -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let settingsURL = directory.appendingPathComponent("settings.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var root = readJSONObject(at: settingsURL)
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            let command = "BORING_NOTCH_SOURCE=claude /usr/bin/python3 \(shellQuoted(script.path))"
            for event in ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop"] {
                var entries = hooks[event] as? [[String: Any]] ?? []
                let alreadyInstalled = entries.contains { String(describing: $0).contains("BORING_NOTCH_SOURCE=claude") }
                if !alreadyInstalled {
                    entries.append(["matcher": "", "hooks": [["type": "command", "command": command, "timeout": 300000]]])
                }
                hooks[event] = entries
            }
            root["hooks"] = hooks
            try writeJSONObject(root, to: settingsURL)
            return "Claude Code: installed"
        } catch { return "Claude Code: \(error.localizedDescription)" }
    }

    private func installCodexHook(script: URL) -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let hooksURL = directory.appendingPathComponent("hooks.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var root = readJSONObject(at: hooksURL)
            root["boring-notch"] = [
                "command": "BORING_NOTCH_SOURCE=codex /usr/bin/python3 \(shellQuoted(script.path))",
                "events": ["session.start", "session.end", "tool.start", "tool.end", "permission.request", "turn.end"]
            ]
            try writeJSONObject(root, to: hooksURL)
            return "Codex: installed"
        } catch { return "Codex: \(error.localizedDescription)" }
    }

    private func installGeminiHook(script: URL) -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return "Gemini CLI: not installed, skipped" }
        let settingsURL = directory.appendingPathComponent("settings.json")
        do {
            var root = readJSONObject(at: settingsURL)
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            hooks["boring-notch"] = ["command": "BORING_NOTCH_SOURCE=gemini /usr/bin/python3 \(shellQuoted(script.path))"]
            root["hooks"] = hooks
            try writeJSONObject(root, to: settingsURL)
            return "Gemini CLI: installed"
        } catch { return "Gemini CLI: \(error.localizedDescription)" }
    }

    private func installCursorHook(script: URL) -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return "Cursor: not installed, skipped" }
        let hooksURL = directory.appendingPathComponent("hooks.json")
        do {
            var root = readJSONObject(at: hooksURL)
            root["boring-notch"] = [
                "command": "BORING_NOTCH_SOURCE=cursor /usr/bin/python3 \(shellQuoted(script.path))",
                "events": ["*"]
            ]
            try writeJSONObject(root, to: hooksURL)
            return "Cursor: installed"
        } catch { return "Cursor: \(error.localizedDescription)" }
    }

    private func installOpenCodePlugin() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let openCodeDirectory = home.appendingPathComponent(".config/opencode", isDirectory: true)
        guard FileManager.default.fileExists(atPath: openCodeDirectory.path) else { return "OpenCode: not installed, skipped" }
        let pluginDirectory = openCodeDirectory.appendingPathComponent("plugins", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
            try Data(Self.openCodePlugin.utf8).write(to: pluginDirectory.appendingPathComponent("boring-notch.js"), options: .atomic)
            return "OpenCode: installed"
        } catch { return "OpenCode: \(error.localizedDescription)" }
    }

    private func installJavaScriptPlugin(tool: String, directory: String, fileName: String, contents: String) -> String {
        let pluginDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(directory, isDirectory: true)
        let toolDirectory = pluginDirectory.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: toolDirectory.path) else { return "\(tool): not installed, skipped" }
        do {
            try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: pluginDirectory.appendingPathComponent(fileName), options: .atomic)
            return "\(tool): installed"
        } catch { return "\(tool): \(error.localizedDescription)" }
    }

    private func installKiroHook(script: URL) -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return "Kiro: not installed, skipped" }
        let agentsDirectory = directory.appendingPathComponent("agents", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
            let command = "BORING_NOTCH_SOURCE=kiro /usr/bin/python3 \(shellQuoted(script.path))"
            let definition: [String: Any] = [
                "name": "boring-notch",
                "description": "Boring Notch agent session monitor",
                "hooks": ["on_tool_call": command, "on_session_start": command, "on_session_end": command]
            ]
            try writeJSONObject(definition, to: agentsDirectory.appendingPathComponent("boring-notch.json"))
            return "Kiro: installed"
        } catch { return "Kiro: \(error.localizedDescription)" }
    }

    private func installKimiHook(script: URL) -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return "Kimi: not installed, skipped" }
        let configURL = directory.appendingPathComponent("config.toml")
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        if existing.contains("boring-notch Kimi hooks START") { return "Kimi: installed" }
        if existing.contains("[hooks]") {
            return "Kimi: existing hooks preserved; add Boring Notch manually"
        }
        let command = "BORING_NOTCH_SOURCE=kimi /usr/bin/python3 \(shellQuoted(script.path))"
        let block = """

        # --- boring-notch Kimi hooks START (managed) ---
        [hooks]
        pre_tool_call = \"\(command)\"
        post_tool_call = \"\(command)\"
        # --- boring-notch Kimi hooks END ---
        """
        do {
            try Data((existing + block).utf8).write(to: configURL, options: .atomic)
            return "Kimi: installed"
        } catch { return "Kimi: \(error.localizedDescription)" }
    }

    private func installSimpleJSONHook(
        tool: String,
        directory: String,
        config: String,
        key: String,
        source: String,
        script: URL
    ) -> String {
        let toolDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(directory, isDirectory: true)
        guard FileManager.default.fileExists(atPath: toolDirectory.path) else { return "\(tool): not installed, skipped" }
        let configURL = toolDirectory.appendingPathComponent(config)
        do {
            var root = readJSONObject(at: configURL)
            if root[key] != nil { return "\(tool): existing hook preserved" }
            root[key] = "BORING_NOTCH_SOURCE=\(source) /usr/bin/python3 \(shellQuoted(script.path))"
            try writeJSONObject(root, to: configURL)
            return "\(tool): installed"
        } catch { return "\(tool): \(error.localizedDescription)" }
    }

    private func installClineHook(script: URL) -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cline", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return "Cline: not installed, skipped" }
        let settingsURL = directory.appendingPathComponent("settings.json")
        do {
            var root = readJSONObject(at: settingsURL)
            if root["hookCommand"] != nil { return "Cline: existing hook preserved" }
            root["hookCommand"] = "BORING_NOTCH_SOURCE=cline /usr/bin/python3 \(shellQuoted(script.path))"
            root["hookEvents"] = ["PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop"]
            try writeJSONObject(root, to: settingsURL)
            return "Cline: installed"
        } catch { return "Cline: \(error.localizedDescription)" }
    }

    private func installPiHook(script: URL) -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return "Pi: not installed, skipped" }
        let configURL = directory.appendingPathComponent("config.json")
        do {
            var root = readJSONObject(at: configURL)
            if root["hook"] != nil { return "Pi: existing hook preserved" }
            root["hook"] = [
                "command": "BORING_NOTCH_SOURCE=pi /usr/bin/python3 \(shellQuoted(script.path))",
                "events": ["session_start", "session_end", "tool_call", "tool_result"]
            ]
            try writeJSONObject(root, to: configURL)
            return "Pi: installed"
        } catch { return "Pi: \(error.localizedDescription)" }
    }

    private func installCopilotHook(script: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".config/gh-copilot"), home.appendingPathComponent(".copilot")]
        guard let directory = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return "Copilot: not installed, skipped"
        }
        let hooksURL = directory.appendingPathComponent("hooks.json")
        do {
            var root = readJSONObject(at: hooksURL)
            let command = "BORING_NOTCH_SOURCE=copilot /usr/bin/python3 \(shellQuoted(script.path))"
            for event in ["PreToolUse", "PostToolUse", "SessionStart", "SessionEnd", "PermissionRequest", "Stop"] {
                var entries = root[event] as? [[String: Any]] ?? []
                if !entries.contains(where: { String(describing: $0).contains("BORING_NOTCH_SOURCE=copilot") }) {
                    entries.append(["type": "command", "command": command, "timeout": 300000])
                }
                root[event] = entries
            }
            try writeJSONObject(root, to: hooksURL)
            return "Copilot: installed"
        } catch { return "Copilot: \(error.localizedDescription)" }
    }

    private func readJSONObject(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func focusTMUXPane(tty: String) -> Bool {
        guard let tmux = executableURL(named: "tmux") else { return false }
        let process = Process()
        let output = Pipe()
        process.executableURL = tmux
        process.arguments = ["list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let listing = String(data: data, encoding: .utf8)
            else { return false }
            let ttyName = tty.replacingOccurrences(of: "/dev/", with: "")
            guard let target = listing.split(separator: "\n").compactMap({ line -> String? in
                let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard fields.count == 2, fields[0].contains(ttyName) else { return nil }
                return fields[1]
            }).first else { return false }
            _ = run(tmux.path, arguments: ["select-window", "-t", target])
            return run(tmux.path, arguments: ["select-pane", "-t", target])
        } catch {
            return false
        }
    }

    private func bundleID(for termProgram: String, source: String) -> String? {
        if termProgram.contains("iterm") { return "com.googlecode.iterm2" }
        if termProgram.contains("apple_terminal") { return "com.apple.Terminal" }
        if termProgram.contains("ghostty") { return "com.mitchellh.ghostty" }
        if termProgram.contains("warp") { return "dev.warp.Warp-Stable" }
        if termProgram.contains("vscode") { return "com.microsoft.VSCode" }
        if termProgram.contains("cursor") || source == "cursor" { return "com.todesktop.230313mzl4w4u92" }
        return nil
    }

    @discardableResult
    private func run(_ executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static let openCodePlugin = #"""
// boring-notch — OpenCode session and approval bridge
import { connect } from "net";
import { homedir } from "os";

const socketPath = homedir() + "/.boring-notch/run/agent-bridge.sock";

function exchange(payload, waitForResponse = false) {
  return new Promise((resolve) => {
    try {
      const socket = connect({ path: socketPath }, () => {
        socket.write(JSON.stringify(payload));
        if (!waitForResponse) socket.end();
      });
      let response = "";
      socket.on("data", (chunk) => response += chunk.toString());
      socket.on("end", () => {
        try { resolve(response ? JSON.parse(response) : null); }
        catch { resolve(null); }
      });
      socket.on("error", () => resolve(null));
      socket.setTimeout(waitForResponse ? 300000 : 3000, () => {
        socket.destroy();
        resolve(null);
      });
    } catch { resolve(null); }
  });
}

export default async ({ client, serverUrl }) => {
  const port = serverUrl ? parseInt(serverUrl.port) || 4096 : 4096;
  const internalFetch = client?._client?.getConfig?.()?.fetch || null;
  const event = (sessionID, extra) => ({
    session_id: `opencode-${sessionID}`,
    _source: "opencode",
    ...extra,
  });

  return {
    "event": async ({ event: incoming }) => {
      const type = incoming.type;
      const properties = incoming.properties || {};
      let payload = null;

      if (type === "session.created" && properties.info) {
        payload = event(properties.info.id, { hook_event_name: "SessionStart", cwd: properties.info.directory });
      } else if (type === "session.deleted" && properties.info) {
        payload = event(properties.info.id, { hook_event_name: "SessionEnd" });
      } else if (type === "message.part.updated" && properties.part?.type === "tool" && properties.part?.sessionID) {
        const state = properties.part.state?.status;
        const name = properties.part.tool || "Tool";
        if (state === "running" || state === "pending") {
          payload = event(properties.part.sessionID, { hook_event_name: "PreToolUse", tool_name: name });
        } else if (state === "completed" || state === "error") {
          payload = event(properties.part.sessionID, { hook_event_name: "PostToolUse", tool_name: name });
        }
      } else if (type === "permission.asked" && properties.id && properties.sessionID) {
        payload = event(properties.sessionID, {
          hook_event_name: "PermissionRequest",
          tool_name: properties.permission || "Permission",
          tool_input: { patterns: properties.patterns || [] },
        });
        if (internalFetch) {
          const answer = await exchange(payload, true);
          const behavior = answer?.hookSpecificOutput?.decision?.behavior;
          const reply = behavior === "allow" ? "once" : behavior === "always" ? "always" : "reject";
          try {
            await internalFetch(new Request(`http://localhost:${port}/permission/${properties.id}/reply`, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ reply }),
            }));
          } catch {}
          return;
        }
      }

      if (payload) await exchange(payload);
    },
  };
};
"""#

    private static let ampPlugin = #"""
// boring-notch — Amp lifecycle bridge
import { connect } from "net";
import os from "os";
const socketPath = os.homedir() + "/.boring-notch/run/agent-bridge.sock";
function send(name, detail = {}) {
  try {
    const socket = connect({ path: socketPath }, () => {
      socket.end(JSON.stringify({ hook_event_name: name, _source: "amp", ...detail }));
    });
    socket.on("error", () => {});
  } catch {}
}
export default (amp) => {
  const id = () => amp.threadId || ("amp-" + process.pid);
  amp.on("session.start", () => send("SessionStart", { session_id: id(), cwd: process.cwd() }));
  amp.on("agent.start", () => send("PreToolUse", { session_id: id(), tool_name: "Agent" }));
  amp.on("agent.end", () => send("Stop", { session_id: id() }));
  amp.on("tool.call", (value) => send("PreToolUse", { session_id: id(), tool_name: value.tool || "Tool" }));
  amp.on("tool.result", (value) => send("PostToolUse", { session_id: id(), tool_name: value.tool || "Tool" }));
};
"""#

    private static let hermesPlugin = #"""
// boring-notch — Hermes lifecycle bridge
import { connect } from "net";
import os from "os";
const socketPath = os.homedir() + "/.boring-notch/run/agent-bridge.sock";
function send(name, detail = {}) {
  try {
    const socket = connect({ path: socketPath }, () => {
      socket.end(JSON.stringify({ hook_event_name: name, _source: "hermes", ...detail }));
    });
    socket.on("error", () => {});
  } catch {}
}
export default (hermes) => {
  const id = () => hermes.sessionId || ("hermes-" + process.pid);
  hermes.on("session.start", () => send("SessionStart", { session_id: id(), cwd: process.cwd() }));
  hermes.on("session.end", () => send("SessionEnd", { session_id: id() }));
  hermes.on("tool.call", (value) => send("PreToolUse", { session_id: id(), tool_name: value.tool || "Tool" }));
  hermes.on("tool.result", (value) => send("PostToolUse", { session_id: id(), tool_name: value.tool || "Tool" }));
  hermes.on("idle", () => send("Stop", { session_id: id() }));
};
"""#

    private static let pythonHook = #"""
#!/usr/bin/env python3
import json, os, socket, subprocess, sys

SOCKET_PATH = os.path.expanduser("~/.boring-notch/run/agent-bridge.sock")

def get_tty():
    try:
        if os.isatty(0):
            return os.ttyname(0)
    except Exception:
        pass
    try:
        value = subprocess.check_output(["ps", "-o", "tty=", "-p", str(os.getppid())], timeout=1).decode().strip()
        return "/dev/" + value if value not in ("", "?", "??") else None
    except Exception:
        return None

def send(payload, held):
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(300 if held else 3)
        client.connect(SOCKET_PATH)
        client.sendall(json.dumps(payload).encode())
        if not held:
            client.close()
            return None
        chunks = []
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
        client.close()
        return b"".join(chunks).decode() if chunks else None
    except Exception:
        return None

def normalize(name):
    aliases = {
        "session.start": "SessionStart", "session_start": "SessionStart",
        "session.end": "SessionEnd", "session_end": "SessionEnd",
        "tool.start": "PreToolUse", "BeforeTool": "PreToolUse",
        "tool.end": "PostToolUse", "AfterTool": "PostToolUse",
        "permission.request": "PermissionRequest", "permission_request": "PermissionRequest",
        "turn.end": "Stop", "turn_end": "Stop"
    }
    return aliases.get(name, name)

def main():
    data = {}
    try:
        data = json.load(sys.stdin)
    except Exception:
        if len(sys.argv) > 1:
            try: data = json.loads(sys.argv[-1])
            except Exception: pass

    source = os.environ.get("BORING_NOTCH_SOURCE", data.get("source", "agent"))
    event_name = normalize(data.get("hook_event_name", data.get("type", os.environ.get("HOOK_EVENT", ""))))
    session_id = os.environ.get("BORING_NOTCH_MANAGED_SESSION_ID") or data.get("session_id", data.get("thread_id", data.get("conversation_id", "")))
    if not session_id:
        session_id = source + "-" + str(os.getppid())
    tool_name = data.get("tool_name", data.get("tool", {}).get("name", "") if isinstance(data.get("tool"), dict) else "")
    tool_input = data.get("tool_input", data.get("tool", {}).get("input", {}) if isinstance(data.get("tool"), dict) else {})

    is_question = event_name == "PreToolUse" and tool_name == "AskUserQuestion"
    bypass = os.environ.get("CLAUDE_BYPASS_PERMISSIONS", "") == "1"
    is_permission = (
        event_name == "PermissionRequest" or
        (source == "claude" and event_name == "PreToolUse" and tool_name not in ("", None, "AskUserQuestion") and not bypass)
    )
    if is_question or is_permission:
        event_name = "PermissionRequest"

    env = {key: value for key, value in os.environ.items() if key.startswith(("TERM", "TMUX", "SSH_", "COLORTERM", "KITTY_", "WEZTERM_"))}
    payload = {
        "session_id": session_id,
        "hook_event_name": event_name,
        "cwd": data.get("cwd", os.getcwd()),
        "tool_name": tool_name or None,
        "tool_input": tool_input,
        "prompt": data.get("prompt"),
        "last_assistant_message": data.get("last_assistant_message"),
        "codex_title": data.get("title"),
        "_source": source,
        "_tty": get_tty(),
        "_env": env
    }
    response = send(payload, is_question or is_permission)
    if response:
        print(response)

if __name__ == "__main__":
    main()
"""#
}

private final class AgentUnixSocketServer {
    private let path: String
    private let handler: (Data, Int32) -> Void
    private let acceptQueue = DispatchQueue(label: "theboringteam.boringnotch.agent-bridge.accept")
    private let readQueue = DispatchQueue(label: "theboringteam.boringnotch.agent-bridge.read")
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, handler: @escaping (Data, Int32) -> Void) throws {
        self.path = path
        self.handler = handler

        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw NSError(domain: "AgentBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Agent socket path is too long"])
        }

        _ = Darwin.unlink(path)
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError("Unable to create agent socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { sourcePath in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                    _ = strlcpy($0, sourcePath, pathCapacity)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = posixError("Unable to bind agent socket")
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }

        _ = chmod(path, 0o600)
        guard Darwin.listen(descriptor, 32) == 0 else {
            let error = posixError("Unable to listen on agent socket")
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    }

    func start() {
        guard source == nil, descriptor >= 0 else { return }
        let newSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        newSource.setEventHandler { [weak self] in self?.acceptConnections() }
        newSource.resume()
        source = newSource
    }

    func stop() {
        source?.cancel()
        source = nil
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        _ = Darwin.unlink(path)
    }

    deinit { stop() }

    private func acceptConnections() {
        while descriptor >= 0 {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { break }
            readQueue.async { [weak self] in self?.readConnection(client) }
        }
    }

    private func readConnection(_ client: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < 1_048_576 {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            if count > 0 {
                data.append(buffer, count: count)
                if (try? JSONSerialization.jsonObject(with: data)) != nil { break }
            } else {
                break
            }
        }

        guard !data.isEmpty, (try? JSONSerialization.jsonObject(with: data)) != nil else {
            Darwin.close(client)
            return
        }
        handler(data, client)
    }

    private func posixError(_ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(errno)))"])
    }
}
