import Foundation

/// Capability `replies.receipts`: where a reply typed into a session's terminal stands, by the agent's own transcript.
public struct ReplyReceipt: Codable, Hashable, Sendable, Identifiable {
    public struct Stage: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let typed = Self(rawValue: "typed")
        /// Claude's `queue-operation` enqueue: it reads the message once its current step ends.
        public static let held = Self(rawValue: "held")
        public static let read = Self(rawValue: "read")
        public static let unsent = Self(rawValue: "unsent")
    }

    /// The reply's `Idempotency-Key`; a retry's `<key>:r<n>` reports under the key it retries.
    public let id: String
    public let stage: Stage
    public let at: Timestamp
    public var reason: String?

    public init(id: String, stage: Stage, at: Timestamp, reason: String? = nil) {
        self.id = id; self.stage = stage; self.at = at; self.reason = reason
    }

    /// `<key>:r<n>` is the n-th retry of `<key>`, and a retry of a retry is still one of `<key>`.
    public static func family(_ key: String) -> String {
        guard let range = key.range(of: #"(:r\d+)+$"#, options: .regularExpression) else { return key }
        return String(key[..<range.lowerBound])
    }

    /// The `n`-th retry of a key, which `family` reads back.
    public static func retry(of family: String, _ n: some BinaryInteger) -> String { "\(family):r\(n)" }

    /// About the reply sent under `key`, or under any retry of it.
    public func answers(_ key: String?) -> Bool { key.map { Self.family($0) == id } ?? false }

    /// A retry whose first attempt the Mac already typed is answered from that attempt, never typed again.
    public static func types(_ key: String, typed: Set<String>) -> Bool { !typed.contains(family(key)) }

    /// The reason of an `unsent` a Stop took off the prompt. The phone recognises it by `isStopReason`: its prompt is
    /// empty again, so a reply waiting to interrupt can go.
    public static func stopped(agent: AgentProvider) -> String { "\(stopPrefix) \(agent.title) read it." }

    public static func isStopReason(_ reason: String) -> Bool { reason.hasPrefix(stopPrefix) }

    private static let stopPrefix = "Stopped before"
}

public extension Capability {
    static let repliesReceipts = Self(rawValue: "replies.receipts")
}
