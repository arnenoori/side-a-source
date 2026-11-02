import Foundation

// How the Mac rotates sessions between accounts, for the phone to explain and steer.

public extension Capability {
    /// From the Mac: `RemoteAccount`'s and `RemoteSession`'s rotation fields, `AutopilotState.next` and friends,
    /// `autopilot.update`, `GET /v1/usage/outlook` and the signed rotation routes. From a phone's `hello`: it can show
    /// ROTATION pushes.
    static let rotation = Self(rawValue: "rotation")
}

/// Which accounts Autopilot and the pool spend before the others.
public struct PriorityLevel: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let first = Self(rawValue: "first")
    public static let normal = Self(rawValue: "normal")
    public static let last = Self(rawValue: "last")
    public static let all = [first, normal, last]
}

/// Why Autopilot skips an account, or is about to.
public struct AccountIssue: Codable, Hashable, Sendable {
    public struct Kind: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Signed out, or not signed in yet.
        public static let signedOut = Self(rawValue: "signedOut")
        /// Its login ended.
        public static let signIn = Self(rawValue: "signIn")
        /// Another account's login sits where its was; `replacedBy` names that account.
        public static let replaced = Self(rawValue: "replaced")
        /// Its sign-in stops renewing soon; `endsAt` says when.
        public static let signInEnds = Self(rawValue: "signInEnds")
        /// The Mac can't confirm whose login this is.
        public static let verifying = Self(rawValue: "verifying")
        /// Its limits couldn't be read.
        public static let offline = Self(rawValue: "offline")
    }
    public let kind: Kind
    public let endsAt: Timestamp?
    public let replacedBy: String?
    public init(kind: Kind, endsAt: Timestamp? = nil, replacedBy: String? = nil) {
        self.kind = kind; self.endsAt = endsAt; self.replacedBy = replacedBy
    }
}

/// A session stopped because its account hit a limit.
public struct SessionLimit: Codable, Hashable, Sendable {
    /// The `UsageWindow` id: "five_hour", "seven_day", "model:fable".
    public let window: String
    public let accountID: String
    /// When that window resets.
    public let until: Timestamp?
    /// The reply gave the reset only in words, so `until` is the longest it could take.
    public let worstCase: Bool
    public init(window: String, accountID: String, until: Timestamp? = nil, worstCase: Bool = false) {
        self.window = window; self.accountID = accountID; self.until = until; self.worstCase = worstCase
    }
}

/// What the sessions stopped on a limit are waiting for: the first account that gets room back.
public struct WaitingSummary: Codable, Hashable, Sendable {
    public let account: String
    public let at: Timestamp
    public let worstCase: Bool
    public init(account: String, at: Timestamp, worstCase: Bool = false) { self.account = account; self.at = at; self.worstCase = worstCase }
}

/// Where one running login's sessions go when it fills up.
public struct NextMove: Codable, Hashable, Sendable, Identifiable {
    /// The account now in use.
    public let id: String
    public let from: String
    /// Nil: no free account has room.
    public let to: String?
    /// The swap threshold.
    public let atPercent: Int
    /// An estimate at the recent pace, rounded to five minutes. Nil when the pace says nothing or the window resets first.
    public let minutes: Int?
    /// Already decided, and waiting only for its sessions to pause.
    public let held: Bool
    public init(id: String, from: String, to: String?, atPercent: Int, minutes: Int? = nil, held: Bool = false) {
        self.id = id; self.from = from; self.to = to; self.atPercent = atPercent; self.minutes = minutes; self.held = held
    }
}

/// `GET /v1/usage/outlook`: what is left across each provider's accounts that Autopilot may use.
public struct UsageOutlook: Codable, Hashable, Sendable {
    public struct Room: Codable, Hashable, Sendable, Identifiable {
        public var id: String { provider.rawValue }
        public let provider: AgentProvider
        public let accounts: Int
        /// Percent left of the week, weighted by plan size.
        public let weeklyLeft: Int
        public let fiveHourLeft: Int?
        /// Accounts out of room now.
        public let limited: Int
        /// When combined weekly room runs out at the user's pace. Nil when it doesn't before quota returns, or the data is too thin to say.
        public let runsOut: Timestamp?
        public init(provider: AgentProvider, accounts: Int, weeklyLeft: Int, fiveHourLeft: Int? = nil, limited: Int = 0, runsOut: Timestamp? = nil) {
            self.provider = provider; self.accounts = accounts; self.weeklyLeft = weeklyLeft; self.fiveHourLeft = fiveHourLeft
            self.limited = limited; self.runsOut = runsOut
        }
    }
    public let rooms: [Room]
    public init(rooms: [Room]) { self.rooms = rooms }
}

/// `POST /v1/accounts/{id}/priority`, signed. Answers with the `AccountList`.
public struct PriorityChange: Codable, Hashable, Sendable {
    public let priority: PriorityLevel
    public init(priority: PriorityLevel) { self.priority = priority }
}

/// `POST /v1/rotation/swap-at`, signed. Answers with the `AutopilotState`.
public struct SwapAtChange: Codable, Hashable, Sendable {
    /// The choices Settings on the Mac offers.
    public static let choices = [80, 85, 90, 95, 97, 99]
    public let percent: Int
    public init(percent: Int) { self.percent = percent }
}
