import Foundation

public extension Capability {
    static let restartAgent = Self(rawValue: "restart.agent")
}

public struct HandoffLink: Codable, Hashable, Sendable {
    public let id: String
    public let conversationID: String
    public let agent: AgentProvider
    public let model: String?
    public let at: Timestamp
    /// False once the Mac's 30 days of keeping it are up.
    public let prompt: Bool
    /// Set only when the old mode had no equivalent and the default stood in.
    public let permissionMode: PermissionMode?
    /// The old session wouldn't end, so both run.
    // swiftlint:disable:next discouraged_optional_boolean -- absent from a Mac that never keeps both
    public var kept: Bool?
    /// It went back to the earlier conversation of that agent rather than starting a new one.
    // swiftlint:disable:next discouraged_optional_boolean -- absent from a Mac without the going-back handoff
    public var resumed: Bool?
    public init(id: String, conversationID: String, agent: AgentProvider, model: String? = nil, at: Timestamp, prompt: Bool = true,
                // swiftlint:disable:next discouraged_optional_boolean -- the initialiser mirrors the optional fields
                permissionMode: PermissionMode? = nil, kept: Bool? = nil, resumed: Bool? = nil) {
        self.id = id; self.conversationID = conversationID; self.agent = agent; self.model = model; self.at = at; self.prompt = prompt
        self.permissionMode = permissionMode; self.kept = kept; self.resumed = resumed
    }
}

public struct HandoffPrompt: Codable, Hashable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public extension PermissionMode {
    /// Codex can't start in Plan or Accept edits, so those fall back to the default (`exact` false).
    static func handedOff(_ mode: PermissionMode?, to agent: AgentProvider) -> (mode: PermissionMode, exact: Bool) {
        let mode = mode ?? .default
        switch (agent, mode) {
        case (.codex, .default), (.claude, .default): return (.default, true)
        case (.codex, .never), (.codex, .dangerFullAccess): return (mode, true)
        case (.codex, .dontAsk): return (.never, true)
        case (.codex, .bypassPermissions): return (.dangerFullAccess, true)
        case (.claude, .never): return (.dontAsk, true)
        case (.claude, .dangerFullAccess): return (.bypassPermissions, true)
        case (.claude, .plan), (.claude, .acceptEdits), (.claude, .auto), (.claude, .dontAsk), (.claude, .bypassPermissions): return (mode, true)
        default: return (.default, false)
        }
    }
}

public extension ConfirmPolicy {
    /// The session's own level, raised as a start's would be for the mode and message it starts with.
    static func restart(_ restart: RestartRequest, sessionMode: PermissionMode?) -> ConfirmLevel {
        if session(mode: sessionMode) == .biometric || restart.permissionMode?.raises == true || runsShell(restart.message ?? "") { return .biometric }
        return .unlock
    }
}

public extension Capability {
    /// `RestartRequest.attachments`: photos the phone uploaded go to the new agent's first prompt.
    static let restartAgentImages = Self(rawValue: "restart.agent.images")
}
