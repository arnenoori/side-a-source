import Foundation

public struct AnswerKind: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let allow = Self(rawValue: "allow")
    public static let always = Self(rawValue: "always")
    public static let deny = Self(rawValue: "deny")
    public static let terminal = Self(rawValue: "terminal")
    public static let answers = Self(rawValue: "answers")
    public static let approvePlan = Self(rawValue: "approvePlan")
    /// Listed when the Mac takes `AnswerBody.mode` with `.allow`: allow, and switch the session to one of
    /// `RemoteRequest.modes` (Claude `updatedPermissions setMode`). Never an answer's own kind.
    public static let allowMode = Self(rawValue: "allowMode")
}

/// Where Allow may be tapped, decided on the Mac; the phone never derives it.
public struct AllowGate: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Reads of plain files and searches inside the project: Allow works from the Lock Screen.
    public static let lockScreen = Self(rawValue: "lockScreen")
    /// Any shell, MCP or unknown tool, and answers that widen permissions: the phone must be unlocked.
    public static let unlock = Self(rawValue: "unlock")
    /// Destructive: Face ID, in the app only.
    public static let biometric = Self(rawValue: "biometric")
}

public struct RemoteSuggestion: Codable, Hashable, Sendable, Identifiable {
    /// First 16 hex of SHA-256 of the suggestion's rule JSON.
    public let id: String
    /// "Always allow Bash(npm run test:*) in this project".
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// The twin of `Island.Pending`.
public struct RemoteRequest: Codable, Hashable, Sendable, Identifiable {
    public let id: RequestID
    public let sessionID: SessionKey?
    public let agent: AgentProvider
    public let tool: String
    public let action: IslandAction
    /// Computed on the Mac; shown when `action` is `.other` on an old phone.
    public let headline: String
    public let detail: String
    public let reason: String?
    public let risk: IslandRisk
    public let riskReason: String?
    /// Empty when the risk is destructive or the agent is Codex.
    public let suggestions: [RemoteSuggestion]
    /// Which answers the Mac accepts for this request.
    @Sorted public var answers: Set<AnswerKind>
    /// Session title, project, or agent name, as the island shows.
    public let title: String
    public let project: String?
    public let accountName: String?
    public let headless: Bool
    public let arrivedAt: Timestamp
    /// Codex and headless: handed back to the terminal then.
    public let handBackAt: Timestamp?
    /// Some string in `action` was cut; `GET /v1/requests/{id}` has it whole.
    public let truncated: Bool
    public let gate: AllowGate?
    /// What `allowMode` may switch to, best first; nil when the Mac offers none.
    public let modes: [PermissionMode]?

    /// What the phone enforces: a Mac that doesn't say asks for an unlocked phone, and a value
    /// this phone doesn't know asks for Face ID, so nothing unknown is easier to approve.
    public var allowGate: AllowGate {
        switch gate {
        case nil: .unlock
        case .some(let gate) where [.lockScreen, .unlock, .biometric].contains(gate): gate
        default: .biometric
        }
    }

    public init(id: RequestID, sessionID: SessionKey? = nil, agent: AgentProvider, tool: String, action: IslandAction,
                headline: String? = nil, detail: String? = nil, reason: String? = nil, risk: IslandRisk, riskReason: String? = nil,
                suggestions: [RemoteSuggestion] = [], answers: Set<AnswerKind>, title: String, project: String? = nil,
                accountName: String? = nil, headless: Bool = false, arrivedAt: Timestamp, handBackAt: Timestamp? = nil, truncated: Bool = false,
                gate: AllowGate? = nil, modes: [PermissionMode]? = nil) {
        self.id = id; self.sessionID = sessionID; self.agent = agent; self.tool = tool; self.action = action
        self.headline = headline ?? action.headline; self.detail = detail ?? action.detail; self.reason = reason
        self.risk = risk; self.riskReason = riskReason; self.suggestions = suggestions; self.answers = answers
        self.title = title; self.project = project; self.accountName = accountName; self.headless = headless
        self.arrivedAt = arrivedAt; self.handBackAt = handBackAt; self.truncated = truncated; self.gate = gate
        self.modes = modes
    }
}

public struct QuestionAnswer: Codable, Hashable, Sendable {
    /// `IslandQuestion.question`, verbatim: it is the key Claude Code expects.
    public let question: String
    /// Option labels, verbatim, "(Recommended)" included.
    public let picked: [String]
    /// Typed text.
    public let other: String?
    public init(question: String, picked: [String], other: String? = nil) { self.question = question; self.picked = picked; self.other = other }
}

public enum RemoteAnswer: Hashable, Sendable {
    /// `confirmDestructive` still decodes, but a Mac with `confirm.signed` ignores it and checks `X-SideA-Confirm` instead.
    case allow(confirmDestructive: Bool)
    case always(suggestionID: String)
    case deny(message: String?)
    case terminal
    case answers([QuestionAnswer])
    case approvePlan(acceptEdits: Bool)

    public var kind: AnswerKind {
        switch self {
        case .allow: .allow
        case .always: .always
        case .deny: .deny
        case .terminal: .terminal
        case .answers: .answers
        case .approvePlan: .approvePlan
        }
    }
}

extension RemoteAnswer: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        switch try c.value("kind", as: String.self) {
        case "allow": self = .allow(confirmDestructive: try c.optional("confirmDestructive") ?? false)
        case "always": self = .always(suggestionID: try c.value("suggestionID"))
        case "deny": self = .deny(message: try c.optional("message"))
        case "terminal": self = .terminal
        case "answers": self = .answers(try c.value("answers"))
        case "approvePlan": self = .approvePlan(acceptEdits: try c.optional("acceptEdits") ?? false)
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: AnyKey("kind"), in: c, debugDescription: "Unknown answer kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.put(kind.rawValue, "kind")
        switch self {
        case .allow(let confirm): try c.put(confirm, "confirmDestructive")
        case .always(let id): try c.put(id, "suggestionID")
        case .deny(let message): try c.put(message, "message")
        case .terminal: break
        case .answers(let answers): try c.put(answers, "answers")
        case .approvePlan(let acceptEdits): try c.put(acceptEdits, "acceptEdits")
        }
    }
}

/// The body of `POST /v1/requests/{rid}/answer`.
public struct AnswerBody: Codable, Hashable, Sendable {
    public let answer: RemoteAnswer
    /// With `.allow`, on a request whose `answers` has `allowMode`: switch the session to this mode, one of the request's
    /// `modes`. A mode that `raises` needs the confirm key after Face ID, whatever the gate.
    public let mode: PermissionMode?
    public init(answer: RemoteAnswer, mode: PermissionMode? = nil) { self.answer = answer; self.mode = mode }
}

public struct RequestResolution: Codable, Hashable, Sendable {
    public struct By: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// The island or a Mac notification.
        public static let mac = Self(rawValue: "mac")
        public static let device = Self(rawValue: "device")
        /// Answered in the CLI.
        public static let terminal = Self(rawValue: "terminal")
        /// Codex timeout.
        public static let handedBack = Self(rawValue: "handedBack")
        public static let sessionEnded = Self(rawValue: "sessionEnded")
        public static let turnFinished = Self(rawValue: "turnFinished")
        /// The Mac answered by itself after a minute (`AutopilotState.answersRecommended`); `answer` says how.
        public static let autoAnswered = Self(rawValue: "autoAnswered")
    }
    public let requestID: RequestID
    public let by: By
    /// When `by` is `.device`.
    public let deviceID: String?
    public let deviceName: String?
    /// Nil when not answered by a person or by `.autoAnswered`.
    public let answer: AnswerKind?
    public let at: Timestamp
    public init(requestID: RequestID, by: By, deviceID: String? = nil, deviceName: String? = nil, answer: AnswerKind? = nil, at: Timestamp) {
        self.requestID = requestID; self.by = by; self.deviceID = deviceID; self.deviceName = deviceName; self.answer = answer; self.at = at
    }
}
