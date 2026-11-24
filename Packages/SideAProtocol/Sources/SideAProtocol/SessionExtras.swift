import Foundation

public extension Capability {
    static let pullRequests = Self(rawValue: "sessions.pullRequest")
    static let snooze = Self(rawValue: "sessions.snooze")
    static let failures = Self(rawValue: "sessions.failure")
}

/// `state` and `checks` come from `gh pr view`, at most once a minute and only when `gh` is installed and signed in;
/// without it the Mac sends the link alone.
public struct PullRequest: Codable, Hashable, Sendable {
    public struct State: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let open = Self(rawValue: "open")
        public static let draft = Self(rawValue: "draft")
        public static let merged = Self(rawValue: "merged")
        public static let closed = Self(rawValue: "closed")
    }

    public struct Checks: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let passing = Self(rawValue: "passing")
        public static let failing = Self(rawValue: "failing")
        public static let pending = Self(rawValue: "pending")
    }

    public let url: String
    public let number: Int?
    public let title: String?
    public let state: State?
    public let checks: Checks?
    public init(url: String, number: Int? = nil, title: String? = nil, state: State? = nil, checks: Checks? = nil) {
        self.url = url; self.number = number ?? Self.number(in: url); self.title = title; self.state = state; self.checks = checks
    }

    public static func number(in url: String) -> Int? {
        guard let range = url.range(of: "/pull/") else { return nil }
        return Int(url[range.upperBound...].prefix { $0.isNumber })
    }
}

/// Kept on the Mac so every phone shows the same list. It wakes early when the session asks something, fails or stalls,
/// is sent a message, or, for `needsMe`, finishes.
public struct SessionSnooze: Codable, Hashable, Sendable {
    public struct Choice: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let hour = Self(rawValue: "hour")
        public static let threeHours = Self(rawValue: "threeHours")
        public static let morning = Self(rawValue: "morning")
        public static let needsMe = Self(rawValue: "needsMe")
    }

    public let choice: Choice
    /// Nil for `needsMe`.
    public let until: Timestamp?
    public let at: Timestamp
    public init(choice: Choice, until: Timestamp?, at: Timestamp) { self.choice = choice; self.until = until; self.at = at }
}

/// `POST /v1/sessions/{id}/snooze`. The phone works out `until`, since "Tomorrow morning" is 9:00 where the person is,
/// not where the Mac is. A nil `choice` wakes the session.
public struct SnoozeRequest: Codable, Hashable, Sendable {
    public let choice: SessionSnooze.Choice?
    public let until: Timestamp?
    public init(choice: SessionSnooze.Choice?, until: Timestamp? = nil) { self.choice = choice; self.until = until }
}

/// Only failures the Mac recognises; keys and tokens are taken out of anything quoted before it leaves the Mac.
public struct SessionFailure: Codable, Hashable, Sendable {
    public struct Kind: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let contextFull = Self(rawValue: "contextFull")
        public static let folderPermission = Self(rawValue: "folderPermission")
        public static let signedOut = Self(rawValue: "signedOut")
        public static let gitAuth = Self(rawValue: "gitAuth")
        /// A limit or a server error: another try gets past it.
        public static let transient = Self(rawValue: "transient")
    }

    public struct Fix: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// `SessionAbility.compact`, else `/compact` typed into its terminal.
        public static let compact = Self(rawValue: "compact")
        public static let atMac = Self(rawValue: "atMac")
        public static let terminal = Self(rawValue: "terminal")
        public static let wait = Self(rawValue: "wait")
    }

    public let kind: Kind
    public let message: String
    /// Auto-continue never tries a failure again when this is false.
    public let retryable: Bool
    public let fix: Fix?
    public let at: Timestamp?
    /// The agent's own words, cut short.
    public var detail: String?
    public init(kind: Kind, message: String, retryable: Bool, fix: Fix? = nil, at: Timestamp? = nil, detail: String? = nil) {
        self.kind = kind; self.message = message; self.retryable = retryable; self.fix = fix; self.at = at; self.detail = detail
    }
}
