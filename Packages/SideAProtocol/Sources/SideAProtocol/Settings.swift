import Foundation

/// A session's permission mode. Claude: Claude Code's `permission_mode`. Codex: `collaborationMode` (`default`, `plan`),
/// and the approval and sandbox raises `never` and `dangerFullAccess`.
public struct PermissionMode: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let `default` = Self(rawValue: "default")
    public static let plan = Self(rawValue: "plan")
    public static let acceptEdits = Self(rawValue: "acceptEdits")
    public static let auto = Self(rawValue: "auto")
    public static let dontAsk = Self(rawValue: "dontAsk")
    public static let bypassPermissions = Self(rawValue: "bypassPermissions")
    /// Codex `approvalPolicy: never`.
    public static let never = Self(rawValue: "never")
    /// Codex `sandboxPolicy: dangerFullAccess`.
    public static let dangerFullAccess = Self(rawValue: "dangerFullAccess")

    /// The modes this phone knows to be safe to enter with the unlock key. Auto and don't-ask run tools unprompted.
    public static let known: Set<Self> = [.default, .plan, .acceptEdits]

    /// Entering it needs Face ID and is never offered from the Lock Screen: anything permissive, and any mode this phone doesn't know.
    public var raises: Bool { !Self.known.contains(self) }
}

extension PermissionMode {
    /// Its name in the apps: "Accept edits", "Full access"; one this build doesn't know, as sent.
    public var title: String {
        switch self {
        case .default: "Default"
        case .plan: "Plan"
        case .acceptEdits: "Accept edits"
        case .auto: "Auto"
        case .dontAsk: "Don't ask"
        case .bypassPermissions: "Bypass permissions"
        case .never: "Never ask"
        case .dangerFullAccess: "Full access"
        default: rawValue
        }
    }
}

/// What a session runs with now. Nil fields are ones the Mac couldn't read.
public struct SessionSettings: Codable, Hashable, Sendable {
    /// "claude-opus-5-5", "gpt-5.5-codex".
    public let model: String?
    public let effort: Effort?
    public let mode: PermissionMode?
    /// Claude's fast mode; nil for Codex.
    public let fast: Bool?
    public init(model: String? = nil, effort: Effort? = nil, mode: PermissionMode? = nil, fast: Bool? = nil) {
        self.model = model; self.effort = effort; self.mode = mode; self.fast = fast
    }
}

/// The body of `POST /v1/sessions/{id}/settings`: only the fields to change. Signed with `ConfirmPurpose.settings`.
public struct SettingsChange: Codable, Hashable, Sendable {
    public let model: String?
    public let effort: Effort?
    public let mode: PermissionMode?
    public let fast: Bool?
    public init(model: String? = nil, effort: Effort? = nil, mode: PermissionMode? = nil, fast: Bool? = nil) {
        self.model = model; self.effort = effort; self.mode = mode; self.fast = fast
    }

    /// Needs the confirm key after Face ID: it enters a mode that `raises`.
    public var raises: Bool { mode?.raises ?? false }
}

/// The answer to `POST /v1/sessions/{id}/settings`.
public struct SettingsResult: Codable, Hashable, Sendable {
    /// The session's settings after the change, as far as the Mac can tell.
    public let settings: SessionSettings
    /// The change reaches the next turn, not the running one (Codex mid-turn).
    public let nextTurn: Bool
    public init(settings: SessionSettings, nextTurn: Bool = false) { self.settings = settings; self.nextTurn = nextTurn }
}

/// `GET /v1/models?kind=claude|codex[&session=<id>]`: the models a settings sheet or New Session offers. Codex's list is
/// per Codex home, so `session` picks the home that session runs in; without it, the default one.
public struct ModelList: Codable, Hashable, Sendable {
    public let agent: AgentProvider
    public let models: [ModelOption]
    public init(agent: AgentProvider, models: [ModelOption]) { self.agent = agent; self.models = models }
}

/// The live plan list: Codex `turn/plan/updated`, Claude's todos.
public struct TurnPlan: Codable, Hashable, Sendable {
    public let explanation: String?
    public let steps: [TranscriptTodo]
    public init(explanation: String? = nil, steps: [TranscriptTodo]) { self.explanation = explanation; self.steps = steps }
}

extension TurnPlan {
    /// How many steps are done.
    public var done: Int { steps.filter { $0.status == .completed }.count }
    /// The step in progress, else the first one left.
    public var current: TranscriptTodo? { steps.first { $0.status == .inProgress } ?? steps.first { $0.status != .completed } }
}

/// `GET /v1/sessions/{id}/turns/{turnID}/diff`: everything a turn changed. Codex `turn/diff/updated`, Claude the turn's
/// Edit and Write items.
public struct TurnDiff: Codable, Hashable, Sendable {
    public let sessionID: SessionKey
    public let turnID: String
    public let files: [FileDiff]
    /// The turn is still running, so more may come.
    public let running: Bool
    /// What the diff leaves out, for the diff screen: "Edits made with Claude's file tools; shell changes aren't shown."
    public let note: String?
    public init(sessionID: SessionKey, turnID: String, files: [FileDiff], running: Bool = false, note: String? = nil) {
        self.sessionID = sessionID; self.turnID = turnID; self.files = files; self.running = running; self.note = note
    }
}

/// The body of `POST /v1/sessions/{id}/review` (Codex `review/start`).
public struct ReviewRequest: Codable, Hashable, Sendable {
    public struct Target: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let uncommittedChanges = Self(rawValue: "uncommittedChanges")
    }
    public let target: Target
    public init(target: Target = .uncommittedChanges) { self.target = target }
}
