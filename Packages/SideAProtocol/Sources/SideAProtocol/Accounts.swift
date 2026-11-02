import Foundation

public struct RemoteAccount: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let email: String
    public let provider: AgentProvider
    public let ready: Bool
    /// Holds the Mac-wide login for its provider.
    public let active: Bool
    public let usage: AccountUsage?
    /// When `usage` was read; the phone shows its age when stale.
    public let readAt: Timestamp?
    /// Live sessions running on it.
    public let sessions: Int
    /// Which accounts Autopilot and the pool spend first. Nil from a Mac without `rotation`, as are the fields below.
    public let priority: PriorityLevel?
    /// Whether Autopilot may use this account.
    public let allowAuto: Bool?
    /// Out on its 5-hour or weekly limit by the Mac's own Planner, not by the phone's reading of the percentages.
    public let limited: Bool?
    /// Has room, but not for Fable.
    public let fableOut: Bool?
    /// When `limited` or `fableOut` ends; the phone stops saying so after this.
    public let backAt: Timestamp?
    /// What keeps Autopilot off this account, now or soon.
    public let issue: AccountIssue?
    public init(id: String, name: String, email: String = "", provider: AgentProvider, ready: Bool, active: Bool = false,
                usage: AccountUsage? = nil, readAt: Timestamp? = nil, sessions: Int = 0, priority: PriorityLevel? = nil, allowAuto: Bool? = nil,
                limited: Bool? = nil, fableOut: Bool? = nil, backAt: Timestamp? = nil, issue: AccountIssue? = nil) {
        self.id = id; self.name = name; self.email = email; self.provider = provider; self.ready = ready
        self.active = active; self.usage = usage; self.readAt = readAt; self.sessions = sessions; self.priority = priority
        self.allowAuto = allowAuto; self.limited = limited; self.fableOut = fableOut; self.backAt = backAt; self.issue = issue
    }
}

public extension Capability {
    /// `POST /v1/accounts/{id}/use` makes an account its provider's Mac-wide login. It answers with the `AccountList`, signed
    /// with `ConfirmPurpose.account` by the confirm key; the empty body is `{}`.
    static let accountsUse = Self(rawValue: "accounts.use")
}

public extension ErrorCode {
    /// 409: the account isn't `ready` (signed out, or its login expired), so it can't be made active.
    static let accountNotReady = Self(rawValue: "account_not_ready")
}
