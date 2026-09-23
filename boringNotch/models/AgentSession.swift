//
//  AgentSession.swift
//  boringNotch
//
//  Agent session protocol adapted from NetVar1337/vibe-island (GPL-3.0).
//

import Foundation
import SwiftUI

enum AgentJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AgentJSONValue])
    case array([AgentJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AgentJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AgentJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
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

    subscript(key: String) -> AgentJSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var arrayValue: [AgentJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var displayText: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array(let values):
            return values.map(\.displayText).joined(separator: ", ")
        case .object(let values):
            let preferredKeys = ["command", "file_path", "path", "query", "description", "prompt"]
            for key in preferredKeys {
                if let value = values[key]?.displayText, !value.isEmpty { return value }
            }
            return values.prefix(3).map { "\($0.key): \($0.value.displayText)" }.joined(separator: " · ")
        case .null:
            return ""
        }
    }
}

enum AgentSessionStatus: String, Codable {
    case active
    case idle
    case pending
    case inProgress = "in_progress"
    case completed
    case waitingForApproval = "waiting_for_approval"
    case waitingForAnswer = "waiting_for_answer"

    var needsAttention: Bool {
        self == .waitingForApproval || self == .waitingForAnswer
    }

    var label: String {
        switch self {
        case .active, .inProgress: return "Working"
        case .idle: return "Ready"
        case .pending: return "Pending"
        case .completed: return "Done"
        case .waitingForApproval: return "Needs approval"
        case .waitingForAnswer: return "Needs answer"
        }
    }

    var color: Color {
        switch self {
        case .active, .inProgress: return .blue
        case .idle, .completed: return .green
        case .pending: return .yellow
        case .waitingForApproval: return .orange
        case .waitingForAnswer: return .cyan
        }
    }
}

struct AgentHookEvent: Decodable {
    let sessionID: String
    let hookEventName: String
    let cwd: String?
    let toolName: String?
    let toolInput: AgentJSONValue?
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

struct AgentQuestionOption: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let value: String
}

struct AgentMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: String
    let text: String
    let createdAt: Date
}

struct AgentSession: Identifiable, Codable, Equatable {
    let id: String
    var source: String
    var status: AgentSessionStatus
    var cwd: String?
    var lastUserText: String?
    var lastAssistantMessage: String?
    var toolName: String?
    var toolInput: AgentJSONValue?
    var title: String?
    var environment: [String: String]
    var tty: String?
    var terminalBundleID: String?
    var resumeID: String?
    var isManaged: Bool
    var messages: [AgentMessage]
    let startedAt: Date
    var lastActivity: Date

    var displayName: String {
        if let title, !title.isEmpty { return title }
        if let cwd, !cwd.isEmpty { return URL(fileURLWithPath: cwd).lastPathComponent }
        return source.capitalized
    }

    var liveAssistantText: String? {
        if let message = messages.last(where: { ($0.role == "assistant" || $0.role == "error") && !$0.text.isEmpty }) {
            return message.text
        }
        if let text = lastAssistantMessage, !text.isEmpty { return text }
        return nil
    }

    var detail: String {
        // Claude cards should prioritize the actual streaming reply. Tool names
        // are useful fallback state, but hiding the reply behind "Bash"/"Read"
        // makes the island look stuck while Claude is actively answering.
        if source.lowercased() == "claude", let text = liveAssistantText {
            return text
        }
        if let toolName, !toolName.isEmpty {
            let input = toolInput?.displayText ?? ""
            return input.isEmpty ? toolName : "\(toolName) · \(input)"
        }
        if let message = messages.last, !message.text.isEmpty { return message.text }
        if let text = lastAssistantMessage, !text.isEmpty { return text }
        if let text = lastUserText, !text.isEmpty { return text }
        return status.label
    }

    func elapsedLabel(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    var questionTitle: String? {
        guard toolName == "AskUserQuestion" else { return nil }
        return toolInput?["questions"]?.arrayValue?.first?["question"]?.stringValue
    }

    var questionHeader: String? {
        guard toolName == "AskUserQuestion" else { return nil }
        return toolInput?["questions"]?.arrayValue?.first?["header"]?.stringValue ?? questionTitle
    }

    var questionOptions: [AgentQuestionOption] {
        guard let options = toolInput?["questions"]?.arrayValue?.first?["options"]?.arrayValue else { return [] }
        return options.compactMap { option in
            if let label = option["label"]?.stringValue {
                return AgentQuestionOption(label: label, value: label)
            }
            if let value = option.stringValue {
                return AgentQuestionOption(label: value, value: value)
            }
            return nil
        }
    }
}
