import Foundation

/// How hard a model thinks. Which ones a model takes is its own: see `ModelOption.efforts`.
public struct Effort: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let auto = Self(rawValue: "auto")
    public static let none = Self(rawValue: "none")
    public static let minimal = Self(rawValue: "minimal")
    public static let low = Self(rawValue: "low")
    public static let medium = Self(rawValue: "medium")
    public static let high = Self(rawValue: "high")
    public static let xhigh = Self(rawValue: "xhigh")
    public static let max = Self(rawValue: "max")
    public static let ultra = Self(rawValue: "ultra")
}

extension Effort {
    /// Its name in the apps: "Extra high" for xhigh, otherwise the raw value capitalized.
    public var title: String {
        switch self {
        case .auto: "Auto"
        case .xhigh: "Extra high"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// One model the composer's Model row offers, with the efforts that model takes.
public struct ModelOption: Codable, Hashable, Sendable {
    /// "claude-opus-5-5"
    public let id: String
    /// "Opus 5.5"
    public let title: String
    public let agent: AgentProvider
    /// In the order to show them; empty when the model takes no effort setting.
    public let efforts: [Effort]
    public let defaultEffort: Effort?
    /// Whether a running session can switch effort; nil when the Mac doesn't know.
    public let canChangeEffortMidSession: Bool?
    /// The account's default model.
    public let isDefault: Bool?
    /// Takes Claude's fast mode.
    public let fast: Bool?
    public init(id: String, title: String, agent: AgentProvider, efforts: [Effort] = [], defaultEffort: Effort? = nil,
                canChangeEffortMidSession: Bool? = nil, isDefault: Bool? = nil, fast: Bool? = nil) {
        self.id = id; self.title = title; self.agent = agent; self.efforts = efforts; self.defaultEffort = defaultEffort
        self.canChangeEffortMidSession = canChangeEffortMidSession; self.isDefault = isDefault; self.fast = fast
    }
}

/// What the composer's Model, Effort and Commands rows offer for one agent, so the phone never hard-codes a model list.
public struct AgentOptions: Codable, Hashable, Sendable {
    public struct Option: Codable, Hashable, Sendable {
        public let id: String
        public let label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }
    public let agent: AgentProvider
    public let installed: Bool
    /// Each with its own efforts.
    public let models: [ModelOption]
    /// Slash commands, the user's own included.
    public let commands: [Option]
    public init(agent: AgentProvider, installed: Bool, models: [ModelOption] = [], commands: [Option] = []) {
        self.agent = agent; self.installed = installed; self.models = models; self.commands = commands
    }
}

/// `GET /v1/options`.
public struct OptionsList: Codable, Hashable, Sendable {
    public let agents: [AgentOptions]
    public init(agents: [AgentOptions]) { self.agents = agents }
}

/// `GET /v1/setup`: the Mac's setup state for the phone's one-time rows and Test Connection.
public struct SetupStatus: Codable, Hashable, Sendable {
    public struct PushStatus: Codable, Hashable, Sendable {
        public let registered: Bool
        /// The last push's `DiagnosticPush.Relay`: "ok", "gone", "retry", "rejected", "unreachable", or
        /// "unverified" while the phone hasn't yet confirmed its APNs token.
        public let lastResult: String?
        public init(registered: Bool, lastResult: String? = nil) { self.registered = registered; self.lastResult = lastResult }
    }
    public let claudeHooks: Bool
    /// "off", "unconfirmed", "trusted", "notInstalled".
    public let codexHooks: String
    public let codexLastHeardAt: Timestamp?
    /// "ok", "missing", "tooOld".
    public let tmux: String
    public let keepAwake: Bool
    public let onPower: Bool?
    /// "ok", "unreachable", "unregistered".
    public let relay: String
    /// For the calling device.
    public let push: PushStatus
    public init(claudeHooks: Bool, codexHooks: String, codexLastHeardAt: Timestamp? = nil, tmux: String, keepAwake: Bool, onPower: Bool? = nil,
                relay: String, push: PushStatus) {
        self.claudeHooks = claudeHooks; self.codexHooks = codexHooks; self.codexLastHeardAt = codexLastHeardAt; self.tmux = tmux
        self.keepAwake = keepAwake; self.onPower = onPower; self.relay = relay; self.push = push
    }
}

/// `POST /v1/diagnostics/push`: one `TEST` push to the calling device, and what the relay said.
public struct DiagnosticPush: Codable, Hashable, Sendable {
    public struct Relay: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let ok = Self(rawValue: "ok")
        public static let gone = Self(rawValue: "gone")
        public static let retry = Self(rawValue: "retry")
        public static let rejected = Self(rawValue: "rejected")
        public static let unreachable = Self(rawValue: "unreachable")
        /// The phone hasn't confirmed its APNs token yet, so nothing was sent.
        public static let unverified = Self(rawValue: "unverified")
    }
    public let id: String
    public let relay: Relay
    public init(id: String, relay: Relay) { self.id = id; self.relay = relay }
}
