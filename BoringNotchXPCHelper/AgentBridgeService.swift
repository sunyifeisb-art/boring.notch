//
//  AgentBridgeService.swift
//  BoringNotchXPCHelper
//
//  Native Swift port of the local hook/session protocol used by Vibe Island.
//  The XPC helper owns the socket because the main app is sandboxed.
//

import Darwin
import Foundation
import AppKit

private enum BridgeJSONValue: Codable, Equatable {
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
    let transcriptPath: String?
    let ghosttyTerminalID: String?
    let turnID: String?

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
        case transcriptPath = "transcript_path"
        case ghosttyTerminalID = "_ghostty_terminal_id"
        case turnID = "turn_id"
    }
}

private enum BridgeSessionStatus: String, Codable, Equatable {
    case active
    case idle
    case pending
    case inProgress = "in_progress"
    case completed
    case waitingForApproval = "waiting_for_approval"
    case waitingForAnswer = "waiting_for_answer"

    var localizedLabel: String {
        switch self {
        case .active, .inProgress: return "工作中"
        case .idle: return "就绪"
        case .pending: return "等待中"
        case .completed: return "已完成"
        case .waitingForApproval: return "等待批准"
        case .waitingForAnswer: return "等待回答"
        }
    }
}

private struct BridgeSession: Codable, Equatable {
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
    var ghosttyTerminalID: String?
    var resumeID: String?
    var turnID: String?
    var isManaged: Bool
    var messages: [BridgeMessage]
    let startedAt: Date
    var lastActivity: Date
}

private struct BridgeMessage: Codable, Equatable {
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

private struct ClaudeTranscriptLine: Decodable {
    let type: String
    let message: ClaudeTranscriptMessage?
    let uuid: String?
}

private struct CodexTranscriptLine: Decodable {
    let type: String
    let payload: CodexTranscriptPayload?
}

private struct CodexTranscriptEvent: Decodable {
    let turnID: String?

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
    }
}

private struct CodexTranscriptPayload: Decodable {
    let type: String
    let id: String?
    let role: String?
    let content: [ClaudeTranscriptTextBlock]?

    var text: String {
        content?.compactMap { block in
            ["input_text", "output_text", "text"].contains(block.type) ? block.text : nil
        }.joined() ?? ""
    }
}

private struct ClaudeTranscriptMessage: Decodable {
    let id: String?
    let content: ClaudeTranscriptContent
}

private enum ClaudeTranscriptContent: Decodable {
    case text(String)
    case blocks([ClaudeTranscriptTextBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .blocks(try container.decode([ClaudeTranscriptTextBlock].self))
        }
    }

    var text: String {
        switch self {
        case .text(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        }
    }
}

private struct ClaudeTranscriptTextBlock: Decodable {
    let type: String
    let text: String?
}

private struct TranscriptState {
    var path: String
    var offset: UInt64
    var remainder = Data()
    var discardLeadingPartial: Bool
    var currentClaudeMessageID: String?
    var currentBridgeMessageID: UUID?
}

private final class AgentDataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()

    init(maximumBytes: Int = 256 * 1024) {
        self.maximumBytes = maximumBytes
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        if newData.count >= maximumBytes {
            data = Data(newData.suffix(maximumBytes))
        } else {
            let overflow = data.count + newData.count - maximumBytes
            if overflow > 0 {
                data.removeFirst(overflow)
            }
            data.append(newData)
        }
        lock.unlock()
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

final class AgentBridgeService {
    private static let relevantTranscriptTypeMarkers = [
        Data("\"type\":\"user\"".utf8),
        Data("\"type\":\"assistant\"".utf8),
        Data("\"type\": \"user\"".utf8),
        Data("\"type\": \"assistant\"".utf8)
    ]

    private let stateQueue = DispatchQueue(label: "theboringteam.boringnotch.agent-bridge.state")
    private let transcriptDecoder = JSONDecoder()
    private var sessionRevision: UInt64 = 1
    private var cachedSessionsJSON: Data?
    private var sessions: [String: BridgeSession] = [:] {
        didSet {
            sessionRevision &+= 1
            cachedSessionsJSON = nil
        }
    }
    private var streamCharacterCounts: [UUID: Int] = [:]
    private var pendingConnections: [String: Int32] = [:]
    private var runningProcesses: [String: Process] = [:]
    private var codexUsageProcess: Process?
    private var transcriptStates: [String: TranscriptState] = [:]
    private var codexManagedTurns = Set<String>()
    private var codexHookSessionIDs = Set<String>()
    private var codexDesktopFileSizes: [String: UInt64] = [:]
    private var codexDesktopTimer: DispatchSourceTimer?
    private var codexDesktopObservers: [NSObjectProtocol] = []
    private let codexDesktopQueue = DispatchQueue(label: "theboringteam.boringnotch.codex-desktop-sync", qos: .utility)
    private var dismissedSessionIDs = Set<String>()
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
            startCodexDesktopDiscoveryLocked()
        }
    }

    func stop() {
        stateQueue.sync {
            socketServer?.stop()
            socketServer = nil
            stopCodexDesktopDiscoveryLocked()
            codexDesktopObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            codexDesktopObservers.removeAll()
            pendingConnections.values.forEach { Darwin.close($0) }
            pendingConnections.removeAll()
            runningProcesses.values.forEach { $0.terminate() }
            runningProcesses.removeAll()
            codexUsageProcess?.terminate()
            codexUsageProcess = nil
            transcriptStates.removeAll()
            codexHookSessionIDs.removeAll()
            sessions.removeAll()
            streamCharacterCounts.removeAll(keepingCapacity: false)
            dismissedSessionIDs.removeAll()
            codexManagedTurns.removeAll()
            codexDesktopFileSizes.removeAll(keepingCapacity: false)
        }
    }

    private func startCodexDesktopDiscoveryLocked() {
        guard codexDesktopObservers.isEmpty else {
            startCodexDesktopPollingLocked()
            return
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = workspaceCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      runningApp.bundleIdentifier == "com.openai.codex"
                else { return }
                self?.stateQueue.async {
                    guard let self, self.socketServer != nil else { return }
                    if notification.name == NSWorkspace.didLaunchApplicationNotification {
                        self.startCodexDesktopPollingLocked()
                    } else {
                        self.stopCodexDesktopDiscoveryLocked()
                        for (identifier, var session) in self.sessions where session.source.lowercased() == "codex" {
                            if session.status == .active || session.status == .inProgress || session.status == .pending {
                                session.status = .idle
                                session.lastActivity = Date()
                                self.sessions[identifier] = session
                            }
                        }
                    }
                }
            }
            codexDesktopObservers.append(observer)
        }
        startCodexDesktopPollingLocked()
    }

    private func startCodexDesktopPollingLocked() {
        guard codexDesktopTimer == nil,
              !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
        else { return }
        let timer = DispatchSource.makeTimerSource(queue: codexDesktopQueue)
        timer.schedule(deadline: .now() + .milliseconds(300), repeating: .seconds(8), leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.discoverCodexDesktopThreads()
        }
        codexDesktopTimer = timer
        timer.resume()
    }

    private func stopCodexDesktopDiscoveryLocked() {
        codexDesktopTimer?.cancel()
        codexDesktopTimer = nil
    }

    private func discoverCodexDesktopThreads() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty,
              stateQueue.sync(execute: { socketServer != nil }),
              let data = codexDesktopThreadsJSON()
        else { return }

        stateQueue.async { [weak self] in
            guard let self, self.socketServer != nil else { return }
            self.mergeCodexDesktopThreads(from: data)
        }
    }

    private func codexDesktopThreadsJSON() -> Data? {
        guard let executable = codexExecutableURL() else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
            var buffer = Data()
            var nextID = 0

            func send(_ method: String, params: [String: Any], requestID: Int?) -> Bool {
                var request: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
                if let requestID { request["id"] = requestID }
                guard var encoded = try? JSONSerialization.data(withJSONObject: request) else { return false }
                encoded.append(0x0A)
                do {
                    try input.fileHandleForWriting.write(contentsOf: encoded)
                    return true
                } catch {
                    return false
                }
            }

            func response(for requestID: Int) -> [String: Any]? {
                while process.isRunning {
                    if let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        if (object["id"] as? Int) == requestID { return object }
                        continue
                    }
                    let chunk = output.fileHandleForReading.availableData
                    guard !chunk.isEmpty else { break }
                    buffer.append(chunk)
                    if buffer.count > 4 * 1024 * 1024 { return nil }
                }
                return nil
            }

            nextID += 1
            let initializeID = nextID
            guard send(
                "initialize",
                params: [
                    "clientInfo": ["name": "boring_notch", "title": "Boring Notch", "version": "1.0"],
                    "capabilities": NSNull()
                ],
                requestID: initializeID
            ), let initialize = response(for: initializeID), initialize["error"] == nil else {
                timeout.cancel()
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                return nil
            }

            _ = send("initialized", params: [:], requestID: nil)
            nextID += 1
            let listID = nextID
            guard send(
                "thread/list",
                params: ["limit": 30, "sortKey": "updated_at", "sortDirection": "desc", "archived": false],
                requestID: listID
            ), let listing = response(for: listID),
               let result = listing["result"] as? [String: Any],
               let threads = result["data"] as? [[String: Any]]
            else {
                timeout.cancel()
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                return nil
            }

            let desktopThreads: [[String: Any]] = threads.compactMap { thread in
                let originator = thread["originator"] as? String
                let sourceKind = (thread["sourceKind"] as? String ?? thread["source_kind"] as? String)?.lowercased()
                guard (originator.map(isCodexDesktopOriginator) == true || sourceKind == "desktop"),
                      let identifier = thread["id"] as? String,
                      let path = thread["path"] as? String
                else { return nil }
                return [
                    "id": identifier,
                    "path": path,
                    "title": thread["name"] as? String ?? "",
                    "cwd": thread["cwd"] as? String ?? "",
                    "createdAt": thread["createdAt"] ?? NSNull(),
                    "updatedAt": thread["updatedAt"] ?? NSNull(),
                    "recencyAt": thread["recencyAt"] ?? NSNull()
                ]
            }
            timeout.cancel()
            process.terminate()
            process.waitUntilExit()
            return try? JSONSerialization.data(withJSONObject: desktopThreads)
        } catch {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            if process.processIdentifier != 0 { process.waitUntilExit() }
            return nil
        }
    }

    private func mergeCodexDesktopThreads(from data: Data) {
        guard let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true).standardizedFileURL.path + "/"
        var needsTranscriptSeed = false
        var pendingStatuses: [(id: String, status: BridgeSessionStatus, activity: Date)] = []

        for record in records {
            guard let identifier = record["id"] as? String,
                  !dismissedSessionIDs.contains(identifier),
                  let path = record["path"] as? String,
                  URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(sessionsRoot)
            else { continue }

            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modifiedAt = attributes?[.modificationDate] as? Date
            let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            let updatedAt = codexDate(record["updatedAt"])
            let recencyAt = codexDate(record["recencyAt"])
            let createdAt = codexDate(record["createdAt"])
            let activity = updatedAt ?? recencyAt ?? modifiedAt ?? Date()
            let isRecentlyWritten = modifiedAt.map { Date().timeIntervalSince($0) < 30 } ?? false
            let previousSize = codexDesktopFileSizes[identifier]
            let fileChanged = previousSize.map { $0 != fileSize } ?? false
            let discoveredStatus: BridgeSessionStatus = (isRecentlyWritten || fileChanged) ? .inProgress : .completed

            var session: BridgeSession
            if let existing = sessions[identifier] {
                session = existing
                if let title = record["title"] as? String, !title.isEmpty { session.title = title }
                if let cwd = record["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
                session.resumeID = identifier
                if !codexHookSessionIDs.contains(identifier) {
                    session.status = discoveredStatus
                    session.lastActivity = fileChanged ? Date() : activity
                }
                if transcriptStates[identifier]?.path != path {
                    registerTranscript(path: path, sessionID: identifier, tailWindow: 64 * 1024)
                    needsTranscriptSeed = true
                }
                if session != existing { sessions[identifier] = session }
            } else {
                session = BridgeSession(
                    id: identifier,
                    source: "codex",
                    status: .inProgress,
                    cwd: record["cwd"] as? String,
                    lastUserText: nil,
                    lastAssistantMessage: nil,
                    toolName: nil,
                    toolInput: nil,
                    title: (record["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    environment: [:],
                    tty: nil,
                    terminalBundleID: "com.openai.codex",
                    ghosttyTerminalID: nil,
                    resumeID: identifier,
                    turnID: nil,
                    isManaged: false,
                    messages: [],
                    startedAt: createdAt ?? activity,
                    lastActivity: Date()
                )
                sessions[identifier] = session
                registerTranscript(path: path, sessionID: identifier, tailWindow: 64 * 1024)
                needsTranscriptSeed = true
            }

            if fileSize == 0, transcriptStates[identifier] == nil { continue }
            pendingStatuses.append((identifier, discoveredStatus, fileChanged ? Date() : activity))
            codexDesktopFileSizes[identifier] = fileSize
        }

        if needsTranscriptSeed { refreshTranscriptStreamsLocked() }
        for pending in pendingStatuses where !codexHookSessionIDs.contains(pending.id) {
            guard var session = sessions[pending.id] else { continue }
            session.status = pending.status
            session.lastActivity = pending.activity
            if sessions[pending.id] != session { sessions[pending.id] = session }
        }
    }

    private func codexDate(_ value: Any?) -> Date? {
        if let timestamp = value as? NSNumber {
            let seconds = timestamp.doubleValue > 10_000_000_000
                ? timestamp.doubleValue / 1_000
                : timestamp.doubleValue
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func isCodexDesktopOriginator(_ originator: String) -> Bool {
        let normalized = originator.lowercased()
        return normalized.contains("codex desktop") || normalized.contains("codex_work_desktop")
    }

    func sessionsRevision() -> UInt64 {
        stateQueue.sync {
            prepareSessionsLocked()
            return sessionRevision
        }
    }

    func sessionsJSON() -> Data {
        stateQueue.sync {
            // The client checks sessionsRevision immediately before asking for
            // this snapshot. That revision check already refreshes transcript
            // files; doing it again here doubled file reads and JSONL parsing
            // on every active streaming update.
            if let cachedSessionsJSON { return cachedSessionsJSON }

            let ordered = sessions.values.map(clientVisibleSession).sorted {
                let lhsAttention = $0.status == .waitingForApproval || $0.status == .waitingForAnswer
                let rhsAttention = $1.status == .waitingForApproval || $1.status == .waitingForAnswer
                if lhsAttention != rhsAttention { return lhsAttention }
                return $0.lastActivity > $1.lastActivity
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = (try? encoder.encode(ordered)) ?? Data("[]".utf8)
            cachedSessionsJSON = data
            return data
        }
    }

    func codexUsageJSON(completion: @escaping (Data) -> Void) {
        commandQueue.async { [weak self] in
            guard let self else {
                completion(Self.codexUsageJSON(error: "Agent 桥接已关闭"))
                return
            }
            completion(self.fetchCodexUsageJSON())
        }
    }

    private func fetchCodexUsageJSON() -> Data {
        guard let executable = codexExecutableURL() else {
            return Self.codexUsageJSON(error: "未找到 Codex 桌面 app-server")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        do {
            let started = stateQueue.sync { () -> Bool in
                guard socketServer != nil else { return false }
                do {
                    try process.run()
                    codexUsageProcess = process
                    return true
                } catch {
                    return false
                }
            }
            guard started else { return Self.codexUsageJSON(error: "Agent 灵动岛已关闭，未启动额度查询") }
            defer {
                stateQueue.sync {
                    if codexUsageProcess === process { codexUsageProcess = nil }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
            var buffer = Data()
            func rpc(_ method: String, params: [String: Any], id: Int?) -> [String: Any]? {
                var request: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
                if let id { request["id"] = id }
                guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
                data.append(0x0A)
                do { try input.fileHandleForWriting.write(contentsOf: data) } catch { return nil }
                guard let id else { return [:] }
                while process.isRunning {
                    if let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        if (object["id"] as? Int) == id { return object }
                        continue
                    }
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
                return nil
            }

            let initialized = rpc("initialize", params: [
                "clientInfo": ["name": "boring_notch", "title": "Boring Notch", "version": "1.0"],
                "capabilities": NSNull()
            ], id: 1)
            guard initialized?["error"] == nil else { throw CodexUsageError.unavailable }
            _ = rpc("initialized", params: [:], id: nil)
            let response = rpc("account/rateLimits/read", params: [:], id: 2)
            guard let result = response?["result"] as? [String: Any] else { throw CodexUsageError.unavailable }
            let snapshots = result["rateLimitsByLimitId"] as? [String: Any]
            let codex = snapshots?["codex"] as? [String: Any]
            let fallback = result["rateLimits"] as? [String: Any]
            let primary = (codex?["primary"] as? [String: Any]) ?? (fallback?["primary"] as? [String: Any])
            let secondary = (codex?["secondary"] as? [String: Any]) ?? (fallback?["secondary"] as? [String: Any])
            let fiveHour = primary?["usedPercent"] as? Double
            let weekly = secondary?["usedPercent"] as? Double
            guard fiveHour != nil || weekly != nil else { throw CodexUsageError.unavailable }
            timeout.cancel()
            process.terminate()
            process.waitUntilExit()
            return Self.codexUsageJSON(
                fiveHour: fiveHour.map { max(0, min(100, Int((100 - $0).rounded()))) },
                weekly: weekly.map { max(0, min(100, Int((100 - $0).rounded()))) },
                error: nil
            )
        } catch {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            if process.processIdentifier != 0 { process.waitUntilExit() }
            return Self.codexUsageJSON(error: "Codex 账户额度服务暂不可用，请稍后重试")
        }
    }

    private static func codexUsageJSON(fiveHour: Int? = nil, weekly: Int? = nil, error: String? = nil) -> Data {
        let value: [String: Any] = [
            "fiveHourRemainingPercent": fiveHour as Any? ?? NSNull(),
            "weeklyRemainingPercent": weekly as Any? ?? NSNull(),
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "error": error as Any? ?? NSNull()
        ]
        return (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
    }

    private enum CodexUsageError: Error { case unavailable }

    private func prepareSessionsLocked() {
        refreshTranscriptStreamsLocked()
        let staleCutoff = Date().addingTimeInterval(-12 * 60 * 60)
        var staleSessionIDs = sessions.compactMap { identifier, session in
            let needsAttention = session.status == .waitingForApproval || session.status == .waitingForAnswer
            return !needsAttention && session.lastActivity <= staleCutoff ? identifier : nil
        }
        let retainedCount = 30
        if sessions.count - staleSessionIDs.count > retainedCount {
            let additional = sessions.values
                .filter { $0.status == .completed || $0.status == .idle }
                .sorted { $0.lastActivity < $1.lastActivity }
                .prefix(max(0, sessions.count - staleSessionIDs.count - retainedCount))
                .map(\.id)
            staleSessionIDs.append(contentsOf: additional)
        }
        for identifier in staleSessionIDs {
            sessions.removeValue(forKey: identifier)
            transcriptStates.removeValue(forKey: identifier)
        }
    }

    private func clientVisibleSession(_ session: BridgeSession) -> BridgeSession {
        let maximumMessageCount = 40
        let maximumMessageCharacters = 40_000
        let maximumSessionCharacters = 100_000
        var remainingCharacters = maximumSessionCharacters
        var visibleMessages: [BridgeMessage] = []

        for message in session.messages.suffix(maximumMessageCount).reversed() {
            guard remainingCharacters > 0 else { break }
            var visibleMessage = message
            let allowance = min(maximumMessageCharacters, remainingCharacters)
            visibleMessage.text = boundedText(message.text, maximumCharacters: allowance)
            remainingCharacters -= visibleMessage.text.count
            visibleMessages.append(visibleMessage)
        }

        var visibleSession = session
        visibleSession.messages = visibleMessages.reversed()
        let latestAssistantText = session.messages.last(where: { $0.role == "assistant" })?.text
            ?? session.lastAssistantMessage
        visibleSession.lastAssistantMessage = latestAssistantText.map {
            boundedText($0, maximumCharacters: 4_000)
        }
        visibleSession.lastUserText = session.lastUserText.map {
            boundedText($0, maximumCharacters: 4_000)
        }
        return visibleSession
    }

    private func boundedText(_ text: String, maximumCharacters: Int) -> String {
        guard maximumCharacters > 0, text.count > maximumCharacters else { return text }
        let marker = "\n\n…内容过长，已省略中间部分；完整内容可在 Claude Code 中查看…\n\n"
        let available = max(0, maximumCharacters - marker.count)
        let prefixCount = available / 2
        let suffixCount = available - prefixCount
        return String(text.prefix(prefixCount)) + marker + String(text.suffix(suffixCount))
    }

    func closeSession(sessionID: String) -> Bool {
        var processToStop: Process?
        let removed = stateQueue.sync { () -> Bool in
            guard sessions[sessionID] != nil || runningProcesses[sessionID] != nil || transcriptStates[sessionID] != nil else {
                return false
            }

            dismissedSessionIDs.insert(sessionID)
            if let removed = sessions.removeValue(forKey: sessionID) {
                for message in removed.messages {
                    streamCharacterCounts.removeValue(forKey: message.id)
                }
            }
            transcriptStates.removeValue(forKey: sessionID)
            codexManagedTurns.remove(sessionID)
            processToStop = runningProcesses.removeValue(forKey: sessionID)
            if let descriptor = pendingConnections.removeValue(forKey: sessionID) {
                Darwin.shutdown(descriptor, SHUT_RDWR)
                Darwin.close(descriptor)
            }
            return true
        }

        processToStop?.terminate()
        return removed
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
        let isClaude = session.source.lowercased() == "claude"
        if isClaude, session.isManaged {
            return openClaudeInGhostty(sessionID: sessionID, session: session)
        }
        let tty = session.tty ?? ""
        let termProgram = session.environment["TERM_PROGRAM"]?.lowercased() ?? ""

        if !tty.isEmpty, session.environment["TMUX"] != nil {
            _ = focusTMUXPane(tty: tty)
        }

        if termProgram.contains("ghostty") || session.terminalBundleID == "com.mitchellh.ghostty" {
            if focusGhosttyTerminal(sessionID: sessionID, session: session) {
                return true
            }
            // The original Ghostty surface may have been closed or recreated.
            // Restore the Claude conversation in a fresh surface instead of
            // making the menu item appear to do nothing.
            if isClaude {
                return openClaudeInGhostty(sessionID: sessionID, session: session)
            }
            return false
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
        if let bundleID, run("/usr/bin/open", arguments: ["-b", bundleID]) {
            return true
        }

        // Hook-discovered Claude sessions can outlive their original terminal,
        // and older hook events may not include terminal metadata. A Claude
        // session ID is enough to reopen the exact conversation in Ghostty.
        if isClaude {
            return openClaudeInGhostty(sessionID: sessionID, session: session)
        }
        return false
    }

    private func openClaudeInGhostty(sessionID: String, session: BridgeSession) -> Bool {
        guard let executable = executableURL(named: "claude") else { return false }

        let processToStop = stateQueue.sync { runningProcesses.removeValue(forKey: sessionID) }
        if let processToStop, processToStop.isRunning {
            processToStop.terminate()
            for _ in 0..<20 where processToStop.isRunning {
                usleep(50_000)
            }
            if processToStop.isRunning {
                _ = Darwin.kill(processToStop.processIdentifier, SIGKILL)
            }
        }

        var claudeCommand = "\(shellQuoted(executable.path)) --permission-mode bypassPermissions"
        if let resumeID = session.resumeID,
           UUID(uuidString: resumeID) != nil
        {
            claudeCommand += " --resume \(shellQuoted(resumeID))"
        }
        // Ghostty's surface configuration can launch a command directly. Use
        // an explicit login shell so quoted executable paths and arguments are
        // interpreted consistently without relying on synthetic key presses.
        let launchCommand = "/bin/zsh -lc \(shellQuoted(claudeCommand))"

        let script = #"""
        on run argv
            set targetCWD to item 1 of argv
            set launchCommand to item 2 of argv
            set managedSessionID to item 3 of argv

            tell application "Ghostty"
                activate
                set config to new surface configuration
                if targetCWD is not "" then set initial working directory of config to targetCWD
                set environment variables of config to {"BORING_NOTCH_SOURCE=claude", "BORING_NOTCH_MANAGED_SESSION_ID=" & managedSessionID, "CLAUDE_BYPASS_PERMISSIONS=1"}
                set command of config to launchCommand
                set wait after command of config to true
                set createdWindow to new window with configuration config
                set targetTerm to focused terminal of selected tab of createdWindow
                focus targetTerm
                return id of targetTerm
            end tell
        end run
        """#

        guard let terminalID = runText(
            "/usr/bin/osascript",
            arguments: ["-e", script, "--", session.cwd ?? "", launchCommand, sessionID]
        ), !terminalID.isEmpty else { return false }

        stateQueue.sync {
            guard var updated = sessions[sessionID] else { return }
            updated.isManaged = false
            updated.terminalBundleID = "com.mitchellh.ghostty"
            updated.ghosttyTerminalID = terminalID
            updated.environment["TERM_PROGRAM"] = "ghostty"
            updated.status = .active
            updated.lastActivity = Date()
            sessions[sessionID] = updated
        }
        return true
    }

    private func focusGhosttyTerminal(sessionID: String, session: BridgeSession) -> Bool {
        let terminalID = session.ghosttyTerminalID ?? ""
        let cwd = session.cwd ?? ""
        guard !terminalID.isEmpty || !cwd.isEmpty else { return false }

        let script = #"""
        on run argv
            set targetID to item 1 of argv
            set targetCWD to item 2 of argv

            tell application "Ghostty"
                set targetTerm to missing value
                if targetID is not "" then
                    try
                        set targetTerm to terminal id targetID
                    end try
                end if

                if targetTerm is missing value and targetCWD is not "" then
                    set matches to every terminal whose working directory is targetCWD
                    if (count of matches) is 1 then set targetTerm to item 1 of matches
                end if

                if targetTerm is missing value then error "Claude terminal is ambiguous or unavailable"
                activate
                focus targetTerm
                return id of targetTerm
            end tell
        end run
        """#

        guard let resolvedID = runText("/usr/bin/osascript", arguments: ["-e", script, "--", terminalID, cwd]),
              !resolvedID.isEmpty
        else { return false }

        stateQueue.async { [weak self] in
            guard let self, var updated = self.sessions[sessionID] else { return }
            updated.ghosttyTerminalID = resolvedID
            self.sessions[sessionID] = updated
        }
        return true
    }

    func sendMessage(sessionID: String?, source: String, cwd: String?, message: String) -> String? {
        let trimmed = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100_000))
        guard !trimmed.isEmpty else { return nil }

        var launchRequest: (id: String, source: String, cwd: String?, resumeID: String?, prompt: String)?
        var codexRequest: (id: String, cwd: String?, turnID: String?, prompt: String)?
        var codexInterruptRequest: (id: String, turnID: String)?
        var terminalRequest: (id: String, commands: [String], interrupt: Bool)?
        let resultID: String? = stateQueue.sync {
            let existing = sessionID.flatMap { sessions[$0] }
            let resolvedSource = existing?.source ?? source.lowercased()
            let resolvedCWD = existing?.cwd ?? cwd

            guard resolvedSource == "claude" || resolvedSource == "codex" else { return nil }

            if resolvedSource == "codex" {
                guard let existing, !existing.isManaged else { return nil }
                if trimmed == "/stop" {
                    if let process = runningProcesses.removeValue(forKey: existing.id) {
                        codexManagedTurns.remove(existing.id)
                        process.terminate()
                        appendSystemMessage("已停止灵动岛发起的 Codex 请求。", to: existing.id, status: .idle)
                    } else if let turnID = existing.turnID {
                        codexInterruptRequest = (existing.id, turnID)
                    } else {
                        appendSystemMessage("当前 Codex 任务没有可中断的运行标识。", to: existing.id, status: existing.status)
                    }
                    return existing.id
                }
                guard !codexManagedTurns.contains(existing.id) else {
                    appendSystemMessage("上一条消息仍在提交，请稍候。", to: existing.id, status: existing.status)
                    return existing.id
                }
                let isSteerable = existing.status == .active || existing.status == .inProgress
                guard !isSteerable || existing.turnID != nil else {
                    appendSystemMessage("当前 Codex 任务状态尚未同步，稍后再试。", to: existing.id, status: existing.status)
                    return existing.id
                }
                codexManagedTurns.insert(existing.id)
                let userText = trimmed
                if existing.messages.last?.role != "user" || existing.messages.last?.text != userText {
                    var updated = existing
                    updated.messages.append(BridgeMessage(id: UUID(), role: "user", text: userText, createdAt: Date()))
                    trimMessageHistory(&updated)
                    updated.lastUserText = userText
                    updated.status = .inProgress
                    updated.lastActivity = Date()
                    sessions[existing.id] = updated
                }
                codexRequest = (existing.id, existing.cwd ?? resolvedCWD, isSteerable ? existing.turnID : nil, userText)
                return existing.id
            }

            if trimmed == "/stop", let sessionID {
                if let existing, !existing.isManaged {
                    terminalRequest = (existing.id, [], true)
                    return existing.id
                }
                runningProcesses[sessionID]?.terminate()
                runningProcesses.removeValue(forKey: sessionID)
                appendSystemMessage("已停止当前运行。", to: sessionID, status: .idle)
                return sessionID
            }

            if trimmed == "/current", let sessionID, let session = sessions[sessionID] {
                let summary = "\(session.source.capitalized) · \(session.status.localizedLabel) · \(session.cwd ?? "未设置工作目录")"
                appendSystemMessage(summary, to: sessionID, status: session.status)
                return sessionID
            }

            if trimmed == "/history", let sessionID, let session = sessions[sessionID] {
                let history = session.messages.suffix(6).map { message in
                    let role: String
                    switch message.role {
                    case "user": role = "我"
                    case "assistant": role = "Claude"
                    case "system": role = "系统"
                    case "error": role = "错误"
                    default: role = message.role
                    }
                    return "\(role)：\(message.text)"
                }.joined(separator: "\n")
                appendSystemMessage(history.isEmpty ? "暂无对话记录。" : history, to: sessionID, status: session.status)
                return sessionID
            }

            if trimmed == "/list", let sessionID {
                let available = sessions.values
                    .filter { $0.source == "claude" }
                    .sorted { $0.lastActivity > $1.lastActivity }
                    .enumerated()
                    .map { index, item in "\(index + 1). \(item.title ?? item.cwd ?? item.id) [\(item.status.localizedLabel)]" }
                    .joined(separator: "\n")
                appendSystemMessage(available.isEmpty ? "暂无 Claude 会话。" : available, to: sessionID, status: sessions[sessionID]?.status ?? .idle)
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
                    appendSystemMessage("已切换到 \(target.title ?? target.cwd ?? target.id)。", to: target.id, status: target.status)
                    return target.id
                }
                if let sessionID {
                    appendSystemMessage("未找到 Claude 会话：\(selector)", to: sessionID, status: sessions[sessionID]?.status ?? .idle)
                    return sessionID
                }
                return nil
            }

            if trimmed == "/help", let sessionID {
                appendSystemMessage("可用命令：/new [提示词]、/clear、/stop、/current、/list、/switch <序号或 ID>、/history、/compact、/dir <路径>、/help", to: sessionID, status: sessions[sessionID]?.status ?? .idle)
                return sessionID
            }

            if trimmed.hasPrefix("/dir "), let sessionID {
                let requestedPath = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                let base = URL(fileURLWithPath: resolvedCWD ?? FileManager.default.homeDirectoryForCurrentUser.path)
                let target = URL(fileURLWithPath: requestedPath, relativeTo: base).standardizedFileURL
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    sessions[sessionID]?.cwd = target.path
                    appendSystemMessage("工作目录已切换到 \(target.path)。", to: sessionID, status: .idle)
                } else {
                    appendSystemMessage("目录不存在：\(target.path)", to: sessionID, status: sessions[sessionID]?.status ?? .idle)
                }
                return sessionID
            }

            // Sessions discovered by Claude hooks are already running in Ghostty.
            // Route messages and native slash commands to that exact terminal
            // instead of starting a second claude --resume process.
            if let existing, !existing.isManaged {
                var commands = [trimmed]
                if trimmed == "/new" || trimmed == "/clear" {
                    commands = ["/clear"]
                } else if trimmed.hasPrefix("/new ") {
                    let prompt = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                    commands = prompt.isEmpty ? ["/clear"] : ["/clear", prompt]
                }
                var updated = existing
                updated.lastUserText = commands.last
                updated.status = .inProgress
                updated.lastActivity = Date()
                sessions[existing.id] = updated
                terminalRequest = (existing.id, commands, false)
                return existing.id
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
                    title: prompt.isEmpty ? "新建 \(resolvedSource.capitalized) 会话" : String(prompt.prefix(42)),
                    environment: [:],
                    tty: nil,
                    terminalBundleID: nil,
                    ghosttyTerminalID: nil,
                    resumeID: nil,
                    turnID: nil,
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
                if var updated = sessions[targetID] {
                    updated.messages.append(BridgeMessage(id: UUID(), role: "user", text: prompt, createdAt: Date()))
                    trimMessageHistory(&updated)
                    updated.lastUserText = prompt
                    updated.status = .inProgress
                    updated.lastActivity = Date()
                    sessions[targetID] = updated
                }
            }

            guard !prompt.isEmpty else { return targetID }
            launchRequest = (targetID, resolvedSource, resolvedCWD, startsNew ? nil : (existing?.resumeID ?? existing?.id), prompt)
            return targetID
        }

        if let terminalRequest {
            commandQueue.async { [weak self] in
                guard let self else { return }
                if !self.sendToInteractiveClaude(
                    sessionID: terminalRequest.id,
                    commands: terminalRequest.commands,
                    interrupt: terminalRequest.interrupt
                ) {
                    self.stateQueue.async {
                        self.appendSystemMessage(
                            "无法连接对应的 Ghostty Claude 会话。请允许 Boring Notch 自动化控制 Ghostty，或重新打开 Claude 会话后再试。",
                            to: terminalRequest.id,
                            status: .idle
                        )
                    }
                }
            }
        } else if let codexRequest {
            commandQueue.async { [weak self] in
                self?.runCodexTurn(
                    sessionID: codexRequest.id,
                    cwd: codexRequest.cwd,
                    turnID: codexRequest.turnID,
                    prompt: codexRequest.prompt
                )
            }
        } else if let codexInterruptRequest {
            commandQueue.async { [weak self] in
                self?.interruptCodexTurn(sessionID: codexInterruptRequest.id, turnID: codexInterruptRequest.turnID)
            }
        } else if let launchRequest {
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
                response: "未找到 Claude Code。请安装 Claude Code，或将 `claude` 可执行文件放到标准可执行目录。",
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
            "--permission-mode", "bypassPermissions",
            "--output-format", "stream-json",
            "--include-partial-messages",
            prompt
        ]
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // XPC helpers inherit the GUI launch environment, not the user's shell.
        // Claude Code provider credentials/model routing live in ~/.claude/settings.json
        // on this machine, so merge that environment explicitly for managed chats.
        for (key, value) in claudeSettingsEnvironment() {
            environment[key] = value
        }
        environment["BORING_NOTCH_MANAGED_SESSION_ID"] = sessionID
        environment["BORING_NOTCH_SOURCE"] = "claude"
        environment["CLAUDE_BYPASS_PERMISSIONS"] = "1"
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
            var discardOversizedLine = false
            let maximumStreamLineBytes = 2 * 1024 * 1024
            var fallbackText: String?
            var finalText: String?
            var latestSnapshot: String?
            var resolvedSessionID: String?
            var streamFailed = false
            var pendingDelta = ""
            var lastDeltaFlush = Date.distantPast

            func flushPendingDelta() {
                guard !pendingDelta.isEmpty else { return }
                let delta = pendingDelta
                pendingDelta.removeAll(keepingCapacity: true)
                lastDeltaFlush = Date()
                appendAgentStream(delta, sessionID: sessionID, messageID: streamMessageID)
            }

            func consumeLine(_ line: Data) {
                guard !line.isEmpty else { return }
                guard let event = parseClaudeStreamLine(line) else {
                    if let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty
                    {
                        fallbackText = boundedText(text, maximumCharacters: 80_000)
                    }
                    return
                }
                if let delta = event.delta, !delta.isEmpty {
                    pendingDelta += delta
                    // Batch at the active transcript's 30 Hz display cadence.
                    // This preserves smooth text while avoiding redundant full
                    // history snapshots between frames.
                    if Date().timeIntervalSince(lastDeltaFlush) >= 0.033 {
                        flushPendingDelta()
                    }
                }
                if let snapshot = event.snapshot, !snapshot.isEmpty {
                    latestSnapshot = boundedText(snapshot, maximumCharacters: 200_000)
                }
                if let result = event.result, !result.isEmpty {
                    finalText = boundedText(result, maximumCharacters: 200_000)
                }
                if let eventSessionID = event.sessionID, !eventSessionID.isEmpty {
                    resolvedSessionID = eventSessionID
                    self.rememberResumeID(eventSessionID, for: sessionID)
                }
                if event.failed == true { streamFailed = true }
            }

            while true {
                let chunk = outputPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if discardOversizedLine {
                    guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
                    discardOversizedLine = false
                    lineBuffer.append(contentsOf: chunk[chunk.index(after: newline)...])
                } else {
                    lineBuffer.append(chunk)
                }
                var lineStart = lineBuffer.startIndex
                while let newline = lineBuffer[lineStart...].firstIndex(of: 0x0A) {
                    let line = Data(lineBuffer[lineStart..<newline])
                    if line.count <= maximumStreamLineBytes {
                        consumeLine(line)
                    }
                    lineStart = lineBuffer.index(after: newline)
                }
                if lineStart > lineBuffer.startIndex {
                    lineBuffer.removeSubrange(lineBuffer.startIndex..<lineStart)
                }
                if lineBuffer.count > maximumStreamLineBytes {
                    lineBuffer.removeAll(keepingCapacity: false)
                    discardOversizedLine = true
                }
            }
            if !discardOversizedLine, !lineBuffer.isEmpty, lineBuffer.count <= maximumStreamLineBytes {
                consumeLine(lineBuffer)
            }
            flushPendingDelta()
            process.waitUntilExit()
            errorPipe.fileHandleForReading.readabilityHandler = nil
            errorCapture.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            let errorText = String(data: errorCapture.snapshot, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completeAgentRun(
                sessionID: sessionID,
                response: finalText ?? latestSnapshot ?? fallbackText ?? errorText,
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

    private func runCodexTurn(sessionID: String, cwd: String?, turnID: String?, prompt: String) {
        guard let executable = codexExecutableURL() else {
            stateQueue.async { [weak self] in
                guard let self else { return }
                self.codexManagedTurns.remove(sessionID)
                self.appendSystemMessage("未找到 Codex 桌面随附的 app-server。请确认 ChatGPT/Codex 桌面已安装。", to: sessionID, status: .idle)
            }
            return
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.environment = ProcessInfo.processInfo.environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let errorCapture = AgentDataCapture(maximumBytes: 16 * 1024)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { errorCapture.append($0.availableData) }

        let assistantMessageID = UUID()
        stateQueue.sync {
            runningProcesses[sessionID] = process
            if var session = sessions[sessionID] {
                session.messages.append(BridgeMessage(id: assistantMessageID, role: "assistant", text: "", createdAt: Date()))
                trimMessageHistory(&session)
                session.status = .inProgress
                session.lastActivity = Date()
                sessions[sessionID] = session
            }
        }

        var messageID = 0
        var lineBuffer = Data()
        var bufferedLineStart = 0
        var finalStatus = "Codex 任务已结束。"
        var failed = false

        do {
            try process.run()
            func send(_ method: String, params: [String: Any], notification: Bool = false) throws -> Int? {
                messageID += 1
                var request: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
                if !notification { request["id"] = messageID }
                var data = try JSONSerialization.data(withJSONObject: request)
                data.append(0x0A)
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
                return notification ? nil : messageID
            }

            func readMessage() throws -> [String: Any] {
                while true {
                    if bufferedLineStart < lineBuffer.endIndex,
                       let newline = lineBuffer[bufferedLineStart...].firstIndex(of: 0x0A) {
                        let line = Data(lineBuffer[bufferedLineStart..<newline])
                        bufferedLineStart = lineBuffer.index(after: newline)
                        if bufferedLineStart == lineBuffer.endIndex {
                            lineBuffer.removeAll(keepingCapacity: true)
                            bufferedLineStart = 0
                        } else if bufferedLineStart >= 64 * 1024 {
                            lineBuffer.removeSubrange(lineBuffer.startIndex..<bufferedLineStart)
                            bufferedLineStart = 0
                        }
                        if let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] { return object }
                        continue
                    }
                    let chunk = outputPipe.fileHandleForReading.availableData
                    guard !chunk.isEmpty else { throw NSError(domain: "CodexAppServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Codex app-server closed its output."]) }
                    lineBuffer.append(chunk)
                    if lineBuffer.count - bufferedLineStart > 2 * 1024 * 1024 {
                        throw NSError(domain: "CodexAppServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Codex app-server sent an oversized protocol message."])
                    }
                }
            }

            func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
                guard let id = try send(method, params: params) else { return [:] }
                while true {
                    let object = try readMessage()
                    if let responseID = object["id"] as? Int, responseID == id { return object }
                    _ = processCodexNotification(object, sessionID: sessionID, assistantMessageID: assistantMessageID, finished: &finalStatus)
                }
            }

            let initialize = try request("initialize", params: [
                "clientInfo": ["name": "boring_notch", "title": "Boring Notch", "version": "1.0"],
                "capabilities": NSNull()
            ])
            if let error = initialize["error"] as? [String: Any] {
                throw NSError(domain: "CodexAppServer", code: -1, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Codex 初始化失败"])
            }
            _ = try send("initialized", params: [:], notification: true)

            let resume = try request("thread/resume", params: ["threadId": sessionID, "cwd": cwd as Any? ?? NSNull(), "excludeTurns": true])
            if let error = resume["error"] as? [String: Any] {
                throw NSError(domain: "CodexAppServer", code: -2, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "无法恢复这个 Codex 桌面任务"])
            }

            var turnParams: [String: Any] = [
                "threadId": sessionID,
                "input": [["type": "text", "text": prompt, "text_elements": []]]
            ]
            if let cwd { turnParams["cwd"] = cwd }
            let method: String
            if let turnID {
                method = "turn/steer"
                turnParams["expectedTurnId"] = turnID
            } else {
                method = "turn/start"
                turnParams["approvalPolicy"] = "never"
            }
            let start = try request(method, params: turnParams)
            if let error = start["error"] as? [String: Any] {
                throw NSError(domain: "CodexAppServer", code: -3, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Codex 未接受这条消息"])
            }

            while process.isRunning {
                let object = try readMessage()
                if processCodexNotification(object, sessionID: sessionID, assistantMessageID: assistantMessageID, finished: &finalStatus) {
                    process.terminate()
                    break
                }
            }
            process.waitUntilExit()
            if finalStatus != "Codex 已完成。" { failed = true }
            errorPipe.fileHandleForReading.readabilityHandler = nil
            errorCapture.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            let errorText = String(data: errorCapture.snapshot, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus != 0 {
                failed = true
                if let errorText, !errorText.isEmpty { finalStatus = errorText }
            }
        } catch {
            failed = true
            finalStatus = error.localizedDescription
            if process.isRunning { process.terminate() }
            if process.processIdentifier != 0 { process.waitUntilExit() }
            errorPipe.fileHandleForReading.readabilityHandler = nil
        }

        stateQueue.async { [weak self] in
            guard let self, var session = self.sessions[sessionID] else { return }
            self.runningProcesses.removeValue(forKey: sessionID)
            let wasCanceled = !self.codexManagedTurns.contains(sessionID)
            self.codexManagedTurns.remove(sessionID)
            if wasCanceled {
                session.status = .idle
                session.lastActivity = Date()
                self.trimMessageHistory(&session)
                self.sessions[sessionID] = session
                return
            }
            if failed {
                if let index = session.messages.firstIndex(where: { $0.id == assistantMessageID }), session.messages[index].text.isEmpty {
                    session.messages[index].role = "error"
                    session.messages[index].text = finalStatus
                } else {
                    session.messages.append(BridgeMessage(id: UUID(), role: "error", text: finalStatus, createdAt: Date()))
                }
                session.status = .idle
            } else {
                session.status = .completed
            }
            self.trimMessageHistory(&session)
            session.lastActivity = Date()
            self.sessions[sessionID] = session
        }
    }

    private func processCodexNotification(
        _ object: [String: Any],
        sessionID: String,
        assistantMessageID: UUID,
        finished: inout String
    ) -> Bool {
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        if method == "item/agentMessage/delta", let delta = params["delta"] as? String, !delta.isEmpty {
            appendAgentStream(delta, sessionID: sessionID, messageID: assistantMessageID)
        } else if method == "turn/completed" {
            let status = (params["turn"] as? [String: Any])?["status"] as? String
            finished = status == "completed" ? "Codex 已完成。" : "Codex 任务状态：\(status ?? "未知")"
            return true
        } else if method == "error" {
            finished = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex app-server 返回错误。"
        }
        return false
    }

    private func interruptCodexTurn(sessionID: String, turnID: String) {
        guard let executable = codexExecutableURL() else {
            stateQueue.async { [weak self] in
                self?.appendSystemMessage("找不到 Codex app-server，无法中断任务。", to: sessionID, status: .inProgress)
            }
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            var buffer = Data()
            func request(_ id: Int, _ method: String, _ params: [String: Any]) -> [String: Any]? {
                var data = (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])) ?? Data()
                data.append(0x0A)
                guard !data.isEmpty, (try? input.fileHandleForWriting.write(contentsOf: data)) != nil else { return nil }
                while process.isRunning {
                    if let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard let result = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        if result["id"] as? Int == id { return result }
                    } else {
                        let chunk = output.fileHandleForReading.availableData
                        if chunk.isEmpty { return nil }
                        buffer.append(chunk)
                    }
                }
                return nil
            }
            let initialized = request(1, "initialize", [
                "clientInfo": ["name": "boring_notch", "title": "Boring Notch", "version": "1.0"],
                "capabilities": NSNull()
            ])
            guard initialized?["error"] == nil else { throw CodexUsageError.unavailable }
            var notification = (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "initialized", "params": [:]])) ?? Data()
            notification.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: notification)
            let resumed = request(2, "thread/resume", ["threadId": sessionID, "excludeTurns": true])
            guard resumed?["error"] == nil else { throw CodexUsageError.unavailable }
            let interrupted = request(3, "turn/interrupt", ["threadId": sessionID, "turnId": turnID])
            guard interrupted?["error"] == nil, interrupted?["result"] != nil else { throw CodexUsageError.unavailable }
            process.terminate()
            process.waitUntilExit()
            stateQueue.async { [weak self] in
                self?.appendSystemMessage("已向 Codex 桌面发送停止请求。", to: sessionID, status: .idle)
            }
        } catch {
            if process.isRunning { process.terminate() }
            if process.processIdentifier != 0 { process.waitUntilExit() }
            stateQueue.async { [weak self] in
                self?.appendSystemMessage("Codex 桌面未接受停止请求，请在桌面任务中确认状态。", to: sessionID, status: .inProgress)
            }
        }
    }

    private func codexExecutableURL() -> URL? {
        var installedCodexApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .compactMap(\.bundleURL)
        installedCodexApps.append(contentsOf: [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
            URL(fileURLWithPath: "/Applications/Codex.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app")
        ].compactMap { $0 })
        for appURL in installedCodexApps {
            let executable = appURL.appendingPathComponent("Contents/Resources/codex")
            if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        }

        let installedChatGPTApps = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app")
        ]
        for appURL in installedChatGPTApps {
            let executable = appURL.appendingPathComponent("Contents/Resources/codex")
            if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        }
        return executableURL(named: "codex")
    }

    private func beginAgentStream(sessionID: String, messageID: UUID) {
        stateQueue.async { [weak self] in
            guard let self, var session = self.sessions[sessionID] else { return }
            session.messages.append(BridgeMessage(id: messageID, role: "assistant", text: "", createdAt: Date()))
            self.trimMessageHistory(&session)
            session.status = .inProgress
            session.lastActivity = Date()
            self.sessions[sessionID] = session
        }
    }

    private func rememberResumeID(_ resumeID: String, for sessionID: String) {
        stateQueue.async { [weak self] in
            guard let self,
                  var session = self.sessions[sessionID],
                  session.resumeID != resumeID
            else { return }
            session.resumeID = resumeID
            self.sessions[sessionID] = session
        }
    }

    private func appendAgentStream(_ delta: String, sessionID: String, messageID: UUID) {
        stateQueue.async { [weak self] in
            guard let self,
                  let index = self.sessions[sessionID]?.messages.firstIndex(where: { $0.id == messageID })
            else { return }

            let characterCount = (self.streamCharacterCounts[messageID] ?? 0) + delta.count
            // Mutate the stored String directly. Copying the whole session and
            // rebuilding its complete response for every stream delta made long
            // replies increasingly expensive to render and relay.
            self.modifySession(sessionID) { session in
                session.messages[index].text.append(contentsOf: delta)
                if characterCount >= 110_000 {
                    session.messages[index].text = self.boundedText(
                        session.messages[index].text,
                        maximumCharacters: 100_000
                    )
                }
                session.status = .inProgress
                session.lastActivity = Date()
            }
            if characterCount >= 110_000 {
                self.streamCharacterCounts[messageID] = 100_000
            } else {
                self.streamCharacterCounts[messageID] = characterCount
            }
        }
    }

    private func modifySession(_ sessionID: String, _ modify: (inout BridgeSession) -> Void) {
        guard sessions[sessionID] != nil else { return }
        modify(&sessions[sessionID]!)
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
            let cleaned = response.map {
                self.boundedText(
                    $0.trimmingCharacters(in: .whitespacesAndNewlines),
                    maximumCharacters: 100_000
                )
            }
            if let streamMessageID,
               let index = session.messages.firstIndex(where: { $0.id == streamMessageID })
            {
                self.streamCharacterCounts.removeValue(forKey: streamMessageID)
                if let cleaned, !cleaned.isEmpty {
                    session.messages[index].text = cleaned
                } else if session.messages[index].text.isEmpty {
                    session.messages[index].text = failed ? "Claude Code 因错误停止。" : "Claude 未返回内容"
                }
                session.messages[index].role = failed ? "error" : "assistant"
                session.lastAssistantMessage = session.messages[index].text
                self.trimMessageHistory(&session)
            } else {
                let text = (cleaned?.isEmpty == false ? cleaned : nil) ?? (failed ? "Claude Code 因错误停止。" : "Claude 未返回内容")
                session.messages.append(
                    BridgeMessage(id: UUID(), role: failed ? "error" : "assistant", text: text, createdAt: Date())
                )
                self.trimMessageHistory(&session)
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
        trimMessageHistory(&session)
        session.status = status
        session.lastActivity = Date()
        sessions[sessionID] = session
    }

    private func trimMessageHistory(_ session: inout BridgeSession) {
        let maximumMessageCount = 32
        let maximumMessageCharacters = 40_000
        let maximumSessionCharacters = 100_000
        for index in session.messages.indices {
            session.messages[index].text = boundedText(
                session.messages[index].text,
                maximumCharacters: maximumMessageCharacters
            )
        }
        if session.messages.count > maximumMessageCount {
            session.messages.removeFirst(session.messages.count - maximumMessageCount)
        }
        while session.messages.count > 1,
              session.messages.reduce(0, { $0 + $1.text.count }) > maximumSessionCharacters
        {
            session.messages.removeFirst()
        }
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

    private func claudeSettingsEnvironment() -> [String: String] {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEnvironment = root["env"] as? [String: Any]
        else { return [:] }

        return rawEnvironment.reduce(into: [String: String]()) { result, entry in
            if let value = entry.value as? String {
                result[entry.key] = value
            }
        }
    }

    private func sendToInteractiveClaude(sessionID: String, commands: [String], interrupt: Bool = false) -> Bool {
        guard let session = stateQueue.sync(execute: { sessions[sessionID] }) else { return false }
        let terminalID = session.ghosttyTerminalID ?? ""
        let cwd = session.cwd ?? ""
        guard !terminalID.isEmpty || !cwd.isEmpty else { return false }

        let script = #"""
        on run argv
            set targetID to item 1 of argv
            set targetCWD to item 2 of argv
            set shouldInterrupt to item 3 of argv
            set commandCount to (item 4 of argv) as integer

            tell application "Ghostty"
                set targetTerm to missing value
                if targetID is not "" then
                    try
                        set targetTerm to terminal id targetID
                    end try
                end if

                if targetTerm is missing value and targetCWD is not "" then
                    set matches to every terminal whose working directory is targetCWD
                    if (count of matches) is 1 then set targetTerm to item 1 of matches
                end if

                if targetTerm is missing value then error "Claude terminal is ambiguous or unavailable"

                if shouldInterrupt is "1" then
                    send key "c" to targetTerm modifiers "control"
                else
                    repeat with commandIndex from 1 to commandCount
                        set payload to item (4 + commandIndex) of argv
                        input text payload to targetTerm
                        send key "enter" to targetTerm
                        if commandIndex < commandCount then delay 0.20
                    end repeat
                end if

                return id of targetTerm
            end tell
        end run
        """#

        var arguments = ["-e", script, "--", terminalID, cwd, interrupt ? "1" : "0", String(commands.count)]
        arguments.append(contentsOf: commands)
        guard let resolvedID = runText("/usr/bin/osascript", arguments: arguments), !resolvedID.isEmpty else { return false }

        stateQueue.async { [weak self] in
            guard let self, var updated = self.sessions[sessionID] else { return }
            updated.ghosttyTerminalID = resolvedID
            updated.status = interrupt ? .idle : .inProgress
            updated.lastActivity = Date()
            self.sessions[sessionID] = updated
        }
        return true
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

            return [
                installClaudeHook(script: hookURL),
                installCodexHook(script: hookURL)
            ]
        } catch {
            return ["Agent Hooks 安装失败：\(error.localizedDescription)"]
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

            let eventName = self.normalizedEventName(event.hookEventName)
            if event.source?.lowercased() == "codex" {
                self.codexHookSessionIDs.insert(event.sessionID)
            }
            if self.dismissedSessionIDs.contains(event.sessionID) {
                if eventName == "SessionEnd" {
                    self.dismissedSessionIDs.remove(event.sessionID)
                    self.transcriptStates.removeValue(forKey: event.sessionID)
                    self.runningProcesses.removeValue(forKey: event.sessionID)
                    if let pending = self.pendingConnections.removeValue(forKey: event.sessionID) {
                        Darwin.shutdown(pending, SHUT_RDWR)
                        Darwin.close(pending)
                    }
                }
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
                ghosttyTerminalID: event.ghosttyTerminalID,
                resumeID: event.sessionID,
                turnID: event.turnID,
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
            session.ghosttyTerminalID = event.ghosttyTerminalID ?? session.ghosttyTerminalID
            session.turnID = event.turnID ?? session.turnID
            if event.ghosttyTerminalID != nil {
                session.isManaged = false
            }
            session.lastActivity = now

            if !session.isManaged, let transcriptPath = event.transcriptPath, !transcriptPath.isEmpty {
                self.registerTranscript(path: transcriptPath, sessionID: event.sessionID)
            }

            var holdsConnection = false
            switch eventName {
            case "SessionEnd":
                self.transcriptStates.removeValue(forKey: event.sessionID)
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
                let promptText = event.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
                let shouldAppendCodexPrompt = session.source.lowercased() == "codex"
                    && !(promptText?.isEmpty ?? true)
                    && (session.messages.last?.role != "user" || session.messages.last?.text != promptText)
                if session.source.lowercased() == "codex",
                   shouldAppendCodexPrompt,
                   let prompt = promptText
                {
                    session.messages.append(BridgeMessage(id: UUID(), role: "user", text: prompt, createdAt: now))
                    self.trimMessageHistory(&session)
                }
                if var transcript = self.transcriptStates[event.sessionID] {
                    transcript.currentClaudeMessageID = nil
                    transcript.currentBridgeMessageID = nil
                    self.transcriptStates[event.sessionID] = transcript
                }
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
            case "QuestionRequest":
                session.toolName = event.toolName
                session.toolInput = event.toolInput
                session.status = .waitingForAnswer
                self.sessions[event.sessionID] = session
                if let old = self.pendingConnections.updateValue(descriptor, forKey: event.sessionID) { Darwin.close(old) }
                holdsConnection = true
                self.schedulePermissionTimeout(sessionID: event.sessionID, descriptor: descriptor)
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
                session.status = session.source.lowercased() == "codex" ? .completed : .idle
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

    private func registerTranscript(path: String, sessionID: String, tailWindow: UInt64 = 256 * 1024) {
        guard transcriptStates[sessionID]?.path != path else { return }
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.uint64Value ?? 0
        let startOffset = fileSize > tailWindow ? fileSize - tailWindow : 0
        transcriptStates[sessionID] = TranscriptState(
            path: path,
            offset: startOffset,
            discardLeadingPartial: startOffset > 0,
            currentClaudeMessageID: nil,
            currentBridgeMessageID: nil
        )
    }

    private func refreshTranscriptStreamsLocked() {
        for sessionID in Array(transcriptStates.keys) {
            guard var state = transcriptStates[sessionID],
                  var session = sessions[sessionID],
                  !session.isManaged
            else { continue }

            let isActivelyUpdating = [BridgeSessionStatus.active, .inProgress, .pending, .waitingForApproval, .waitingForAnswer]
                .contains(session.status)
            let isFinishing = Date().timeIntervalSince(session.lastActivity) < 3
            guard isActivelyUpdating || isFinishing else {
                state.remainder.removeAll(keepingCapacity: false)
                transcriptStates[sessionID] = state
                continue
            }

            let fileSize = ((try? FileManager.default.attributesOfItem(atPath: state.path)[.size]) as? NSNumber)?.uint64Value ?? 0
            if fileSize < state.offset {
                state.offset = 0
                state.remainder.removeAll(keepingCapacity: true)
                state.discardLeadingPartial = false
                state.currentClaudeMessageID = nil
                state.currentBridgeMessageID = nil
            }
            guard fileSize > state.offset,
                  let handle = FileHandle(forReadingAtPath: state.path)
            else {
                transcriptStates[sessionID] = state
                continue
            }

            do {
                try handle.seek(toOffset: state.offset)
            } catch {
                try? handle.close()
                transcriptStates[sessionID] = state
                continue
            }
            let maximumReadSize = 64 * 1024
            let newData = (try? handle.read(upToCount: maximumReadSize)) ?? Data()
            try? handle.close()
            state.offset += UInt64(newData.count)
            guard !newData.isEmpty else {
                transcriptStates[sessionID] = state
                continue
            }

            state.remainder.append(newData)
            // One oversized JSONL row must not reserve a megabyte for every
            // discovered session. The display itself is capped at 40k chars.
            let maximumRemainderSize = 256 * 1024
            if state.remainder.count > maximumRemainderSize {
                state.remainder = Data(state.remainder.suffix(maximumRemainderSize))
                state.discardLeadingPartial = true
            }
            if state.discardLeadingPartial {
                guard let newline = state.remainder.firstIndex(of: 0x0A) else {
                    transcriptStates[sessionID] = state
                    continue
                }
                state.remainder.removeSubrange(...newline)
                state.discardLeadingPartial = false
            }

            while let newline = state.remainder.firstIndex(of: 0x0A) {
                let line = Data(state.remainder[..<newline])
                state.remainder.removeSubrange(...newline)
                consumeTranscriptLine(line, session: &session, state: &state)
            }

            sessions[sessionID] = session
            transcriptStates[sessionID] = state
        }
    }

    private func consumeTranscriptLine(_ line: Data, session: inout BridgeSession, state: inout TranscriptState) {
        guard !line.isEmpty else { return }

        if session.source.lowercased() == "codex" {
            consumeCodexTranscriptLine(line, session: &session, state: &state)
            return
        }

        // Claude transcript rows can contain hundreds of kilobytes of image data or tool output.
        // Reject unrelated rows before decoding, then decode only the text fields we display so
        // large unknown payloads never become Foundation object graphs.
        let isRelevant = Self.relevantTranscriptTypeMarkers.contains { line.range(of: $0) != nil }
        guard isRelevant,
              let object = try? transcriptDecoder.decode(ClaudeTranscriptLine.self, from: line),
              let message = object.message
        else { return }

        if object.type == "user" {
            let cleaned = boundedText(
                message.content.text.trimmingCharacters(in: .whitespacesAndNewlines),
                maximumCharacters: 40_000
            )
            guard !cleaned.isEmpty else { return }
            session.messages.append(BridgeMessage(id: UUID(), role: "user", text: cleaned, createdAt: Date()))
            session.lastUserText = cleaned
            state.currentClaudeMessageID = nil
            state.currentBridgeMessageID = nil
            trimMessageHistory(&session)
            session.lastActivity = Date()
            return
        }

        guard object.type == "assistant" else { return }

        let text = boundedText(message.content.text, maximumCharacters: 80_000)
        guard !text.isEmpty else { return }

        let claudeMessageID = message.id ?? object.uuid ?? UUID().uuidString
        let bridgeMessageID: UUID
        if state.currentClaudeMessageID == claudeMessageID,
           let existingID = state.currentBridgeMessageID,
           let index = session.messages.firstIndex(where: { $0.id == existingID })
        {
            let currentText = session.messages[index].text
            if text == currentText || currentText.hasSuffix(text) {
                // Already represented by the current snapshot/delta.
            } else if text.hasPrefix(currentText) {
                // Claude transcript rows can contain cumulative snapshots.
                session.messages[index].text = text
            } else {
                session.messages[index].text = boundedText(
                    currentText + text,
                    maximumCharacters: 80_000
                )
            }
            bridgeMessageID = existingID
        } else {
            bridgeMessageID = UUID()
            session.messages.append(BridgeMessage(id: bridgeMessageID, role: "assistant", text: text, createdAt: Date()))
            state.currentClaudeMessageID = claudeMessageID
            state.currentBridgeMessageID = bridgeMessageID
        }

        if let index = session.messages.firstIndex(where: { $0.id == bridgeMessageID }) {
            session.lastAssistantMessage = session.messages[index].text
        }
        trimMessageHistory(&session)
        if session.status != .waitingForApproval && session.status != .waitingForAnswer {
            session.status = .inProgress
        }
        session.lastActivity = Date()
    }

    private func consumeCodexTranscriptLine(_ line: Data, session: inout BridgeSession, state: inout TranscriptState) {
        guard !codexManagedTurns.contains(session.id) else { return }
        // Codex transcript rows are append-only JSONL envelopes. Decode only
        // message rows; tool payloads and image blocks can be very large.
        if line.range(of: Data("\"type\":\"event_msg\"".utf8)) != nil
            || line.range(of: Data("\"type\": \"event_msg\"".utf8)) != nil
        {
            if let event = try? transcriptDecoder.decode(CodexTranscriptEvent.self, from: line),
               let turnID = event.turnID {
                session.turnID = turnID
            }
            return
        }
        guard line.range(of: Data("\"type\":\"response_item\"".utf8)) != nil
                || line.range(of: Data("\"type\": \"response_item\"".utf8)) != nil,
              let entry = try? transcriptDecoder.decode(CodexTranscriptLine.self, from: line),
              entry.type == "response_item",
              let payload = entry.payload,
              payload.type == "message",
              let role = payload.role,
              role == "user" || role == "assistant"
        else { return }

        let text = boundedText(payload.text.trimmingCharacters(in: .whitespacesAndNewlines), maximumCharacters: 80_000)
        guard !text.isEmpty else { return }
        let messageID = payload.id ?? UUID().uuidString

        if role == "user" {
            if session.messages.last?.role != "user" || session.messages.last?.text != text {
                session.messages.append(BridgeMessage(id: UUID(), role: "user", text: text, createdAt: Date()))
                trimMessageHistory(&session)
            }
            session.lastUserText = text
            state.currentClaudeMessageID = nil
            state.currentBridgeMessageID = nil
        } else {
            let bridgeMessageID: UUID
            if state.currentClaudeMessageID == messageID,
               let existingID = state.currentBridgeMessageID,
               let index = session.messages.firstIndex(where: { $0.id == existingID })
            {
                session.messages[index].text = boundedText(text, maximumCharacters: 80_000)
                bridgeMessageID = existingID
            } else {
                bridgeMessageID = UUID()
                session.messages.append(BridgeMessage(id: bridgeMessageID, role: "assistant", text: text, createdAt: Date()))
                state.currentClaudeMessageID = messageID
                state.currentBridgeMessageID = bridgeMessageID
                trimMessageHistory(&session)
            }
            session.lastAssistantMessage = text
        }

        if session.status != .waitingForApproval && session.status != .waitingForAnswer {
            session.status = .inProgress
        }
        trimMessageHistory(&session)
        session.lastActivity = Date()
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
        case "questionrequest", "question_request": return "QuestionRequest"
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
            for event in ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop"] {
                var entries = hooks[event] as? [[String: Any]] ?? []
                let alreadyInstalled = entries.contains { String(describing: $0).contains("BORING_NOTCH_SOURCE=claude") }
                if !alreadyInstalled {
                    entries.append(["matcher": "", "hooks": [["type": "command", "command": command, "timeout": 300000]]])
                }
                hooks[event] = entries
            }
            root["hooks"] = hooks
            try writeJSONObject(root, to: settingsURL)
            return "Claude Code Hook 已安装"
        } catch { return "Claude Code Hook 安装失败：\(error.localizedDescription)" }
    }

    private func installCodexHook(script: URL) -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let hooksURL = directory.appendingPathComponent("hooks.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var root = readJSONObject(at: hooksURL)
            // Codex reads event groups from hooks.json's `hooks` object. A
            // top-level `boring-notch` command/events record is silently
            // ignored, which made the old UI claim a connection that never ran.
            root.removeValue(forKey: "boring-notch")
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            let command = "BORING_NOTCH_SOURCE=codex /usr/bin/python3 \(shellQuoted(script.path))"
            let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Interrupt"]
            for event in events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                let alreadyInstalled = groups.contains { String(describing: $0).contains("BORING_NOTCH_SOURCE=codex") }
                if !alreadyInstalled {
                    groups.append([
                        "matcher": "",
                        "hooks": [["type": "command", "command": command, "timeout": 3]]
                    ])
                }
                hooks[event] = groups
            }
            root["hooks"] = hooks
            try writeJSONObject(root, to: hooksURL)
            return "Codex Hook 已安装"
        } catch { return "Codex Hook 安装失败：\(error.localizedDescription)" }
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

    private func runText(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
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
  const permissionFetch = internalFetch || globalThis.fetch?.bind(globalThis);
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
          hook_event_name: "PermissionBypassed",
          tool_name: properties.permission || "Permission",
          tool_input: { patterns: properties.patterns || [] },
        });
        if (permissionFetch) {
          // The user has asked to run supported agents without approval cards.
          // Record the event without waiting on the island, then persist the
          // permission in OpenCode so later tool calls do not block either.
          await exchange(payload);
          try {
            await permissionFetch(new Request(`http://localhost:${port}/permission/${properties.id}/reply`, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ reply: "always" }),
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

def get_ghostty_terminal_id(event_name, cwd):
    if "ghostty" not in os.environ.get("TERM_PROGRAM", "").lower():
        return None
    if event_name not in ("SessionStart", "UserPromptSubmit"):
        return None
    script = r'''
    on run argv
        set expectedCWD to item 1 of argv
        tell application "Ghostty"
            try
                set targetTerm to focused terminal of selected tab of front window
                if expectedCWD is "" or working directory of targetTerm is expectedCWD then
                    return id of targetTerm
                end if
            end try
        end tell
        return ""
    end run
    '''
    try:
        value = subprocess.check_output(
            ["/usr/bin/osascript", "-e", script, "--", cwd or ""],
            timeout=2,
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return value or None
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

    permission_mode = data.get("permission_mode") or os.environ.get("CLAUDE_PERMISSION_MODE", "")
    bypass_permissions = (
        os.environ.get("CLAUDE_BYPASS_PERMISSIONS", "") == "1" or
        permission_mode == "bypassPermissions"
    )
    # The user has explicitly configured this integration for unattended agent
    # work. Resolve Claude's PermissionRequest hook locally with the documented
    # event name, so it never blocks on an island approval card or socket wait.
    if event_name == "PermissionRequest":
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"}
            }
        }))
        return

    is_question = event_name == "PreToolUse" and tool_name == "AskUserQuestion"
    is_permission = event_name == "PermissionRequest" and not bypass_permissions
    bridge_event_name = (
        "QuestionRequest" if is_question else
        "PermissionBypassed" if event_name == "PermissionRequest" and bypass_permissions else
        event_name
    )

    env = {key: value for key, value in os.environ.items() if key.startswith(("TERM", "TMUX", "SSH_", "COLORTERM", "KITTY_", "WEZTERM_"))}
    payload = {
        "session_id": session_id,
        "hook_event_name": bridge_event_name,
        "cwd": data.get("cwd", os.getcwd()),
        "tool_name": tool_name or None,
        "tool_input": tool_input,
        "prompt": data.get("prompt"),
        "last_assistant_message": data.get("last_assistant_message"),
        "codex_title": data.get("title"),
        "transcript_path": data.get("transcript_path"),
        "_source": source,
        "_tty": get_tty(),
        "_ghostty_terminal_id": get_ghostty_terminal_id(event_name, data.get("cwd", os.getcwd())),
        "_env": env
    }
    response = send(payload, is_question or is_permission)
    if response and is_question:
        try:
            answer = json.loads(response)
        except Exception:
            answer = {}
        answers = answer.get("hookSpecificOutput", {}).get("decision", {}).get("updatedInput", {}).get("answers", {})
        normalized_answers = {}
        if isinstance(answers, dict):
            for question, value in answers.items():
                if isinstance(value, list):
                    normalized_answers[question] = ", ".join(str(item) for item in value)
                else:
                    normalized_answers[question] = str(value)
        updated_input = dict(tool_input) if isinstance(tool_input, dict) else {}
        updated_input["answers"] = normalized_answers
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": updated_input
            }
        }))
    elif response and is_permission:
        # The island UI returns a compact decision object. Translate it to the
        # schema Claude Code requires for a PermissionRequest hook.
        try:
            answer = json.loads(response)
        except Exception:
            answer = {}
        decision = answer.get("hookSpecificOutput", {}).get("decision", {})
        behavior = decision.get("behavior", "deny")
        if behavior in ("allow", "always"):
            resolved = {"behavior": "allow"}
            if behavior == "always":
                suggestions = data.get("permission_suggestions") or data.get("permissionSuggestions")
                if suggestions:
                    resolved["updatedPermissions"] = suggestions
        else:
            resolved = {"behavior": "deny", "message": "Denied from Boring Notch"}
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": resolved
            }
        }))

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
