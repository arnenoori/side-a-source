import Foundation

// What only Side A offers (ios-app.md 4.14): history, steering, ports, the Mac itself, Clean Up,
// Autopilot and incidents. Each is gated by its capability in `Hello`.

public extension Capability {
    static let history = Self(rawValue: "history")
    static let interruptNextStep = Self(rawValue: "interrupt.nextStep")
    static let restart = Self(rawValue: "restart")
    static let ports = Self(rawValue: "ports")
    static let quit = Self(rawValue: "quit")
    static let mac = Self(rawValue: "mac")
    static let cleanup = Self(rawValue: "cleanup")
    static let autopilot = Self(rawValue: "autopilot")
    /// `POST /v1/autopilot` turns Autopilot on or off.
    static let autopilotToggle = Self(rawValue: "autopilot.toggle")
    /// `POST /v1/autopilot/answers` turns answering with the recommended choice on or off; `AutopilotState.answersRecommended`.
    static let autopilotAnswers = Self(rawValue: "autopilot.answers")
    static let worth = Self(rawValue: "worth")
    static let incidents = Self(rawValue: "incidents")
    static let options = Self(rawValue: "options")
    static let updateCheck = Self(rawValue: "update.check")
    static let lan = Self(rawValue: "lan")
    static let setup = Self(rawValue: "setup")
}

public extension ErrorCode {
    /// 404: no listening port by that number on this session.
    static let portNotFound = Self(rawValue: "port_not_found")
    /// 409: Clean Up keeps this worktree; `details.reason` says why.
    static let worktreeKept = Self(rawValue: "worktree_kept")
    /// 409: Autopilot has no move waiting.
    static let nothingToMove = Self(rawValue: "nothing_to_move")
}

/// `GET /v1/approvals?cursor=`: the Remote approvals log.
public struct ApprovalsPage: Codable, Hashable, Sendable {
    /// One answered request: how it was answered, and what was asked.
    public struct Approval: Codable, Hashable, Sendable {
        public let resolution: RequestResolution
        public let request: RequestSummary
        public init(resolution: RequestResolution, request: RequestSummary) { self.resolution = resolution; self.request = request }
    }
    public let approvals: [Approval]
    public let next: Cursor?
    public init(approvals: [Approval], next: Cursor? = nil) { self.approvals = approvals; self.next = next }
}

/// What a request asked, kept after it resolved so the history row can say it.
public struct RequestSummary: Codable, Hashable, Sendable {
    /// "Bash", "Edit", "AskUserQuestion", or an MCP tool's name.
    public let tool: String
    /// `RemoteRequest.headline` as it was: "Run a command", "Edit Island.swift".
    public let headline: String
    public let sessionTitle: String?
    public let agent: AgentProvider
    public init(tool: String, headline: String, sessionTitle: String? = nil, agent: AgentProvider) {
        self.tool = tool; self.headline = headline; self.sessionTitle = sessionTitle; self.agent = agent
    }
}

// MARK: Steer

/// The body of `POST /v1/sessions/{id}/interrupt`. Missing means `.now`.
public struct InterruptRequest: Codable, Hashable, Sendable {
    public struct When: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Hosted: Esc right away. Otherwise stop mail.
        public static let now = Self(rawValue: "now")
        /// Always stop mail: the agent stops after its current step.
        public static let nextStep = Self(rawValue: "nextStep")
    }
    public let when: When
    public init(when: When) { self.when = when }
}

/// What Restart Fresh hands the new session, drafted by the Mac and edited on the phone.
public struct Handoff: Codable, Hashable, Sendable {
    public var goal: String
    public var branch: String?
    /// What was tried and failed.
    public var failed: String
    public var next: String
    /// The last few turns, as markdown.
    public var lastMessages: String
    /// Read-only on the phone: the new session starts in the same folder.
    public let cwd: String
    public let project: String
    /// The defaults the sheet starts on: the session's account or Autopilot's pick, and its model.
    public var accountID: String?
    public var model: String?
    public init(goal: String, branch: String? = nil, failed: String, next: String, lastMessages: String, cwd: String, project: String,
                accountID: String? = nil, model: String? = nil) {
        self.goal = goal; self.branch = branch; self.failed = failed; self.next = next; self.lastMessages = lastMessages
        self.cwd = cwd; self.project = project; self.accountID = accountID; self.model = model
    }
}

/// `POST /v1/sessions/{id}/restart`: ends the session and starts a hosted one with the handoff as its first prompt.
public struct RestartRequest: Codable, Hashable, Sendable {
    public let handoff: Handoff
    public let accountID: String?
    public let model: String?
    public init(handoff: Handoff, accountID: String? = nil, model: String? = nil) { self.handoff = handoff; self.accountID = accountID; self.model = model }
}

/// `POST /v1/sessions/quit-idle`.
public struct QuitIdleRequest: Codable, Hashable, Sendable {
    public let olderThanMinutes: Int
    public init(olderThanMinutes: Int = 30) { self.olderThanMinutes = olderThanMinutes }
}

public struct QuitIdleResult: Codable, Hashable, Sendable {
    /// The sessions quit.
    public let quit: [SessionKey]
    public init(quit: [SessionKey]) { self.quit = quit }
}

// MARK: Ports

/// A port a session's process tree listens on.
public struct ListeningPort: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { port }
    public let port: Int
    /// "node", "vite".
    public let process: String
    /// Set while a preview of it is up.
    public let previewURL: String?
    public init(port: Int, process: String, previewURL: String? = nil) { self.port = port; self.process = process; self.previewURL = previewURL }
}

/// `POST /v1/sessions/{id}/ports/{port}/preview`: a URL on the tailnet that reaches `localhost:<port>` on the Mac.
public struct Preview: Codable, Hashable, Sendable {
    public let url: String
    public init(url: String) { self.url = url }
}

// MARK: History

/// `GET /v1/history?cursor=&archived=&project=`: pinned first, then by last activity.
public struct HistoryPage: Codable, Hashable, Sendable {
    public let sessions: [PastSession]
    public let next: Cursor?
    public init(sessions: [PastSession], next: Cursor? = nil) { self.sessions = sessions; self.next = next }
}

/// `POST /v1/history/{id}`: only the fields given change. A title of "" clears the custom title.
public struct HistoryChange: Codable, Hashable, Sendable {
    public let pinned: Bool?
    public let title: String?
    public let archived: Bool?
    public init(pinned: Bool? = nil, title: String? = nil, archived: Bool? = nil) { self.pinned = pinned; self.title = title; self.archived = archived }
}

// MARK: The Mac

public struct MacState: Codable, Hashable, Sendable {
    public struct Pressure: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let normal = Self(rawValue: "normal")
        public static let warning = Self(rawValue: "warning")
        public static let critical = Self(rawValue: "critical")
    }
    public let onPower: Bool
    /// Percent, 0–100; nil on a Mac without a battery.
    public let battery: Int?
    public let memoryUsed: Int
    public let memoryTotal: Int
    public let memoryPressure: Pressure
    /// What sessions hold together, for "sessions hold 9.2 GB".
    public let sessionMemory: Int
    public let keepAwake: Bool
    /// What the Mac's usage would have cost at API prices, across every account: the usage report has no per-account split.
    public let worth: Worth?
    public init(onPower: Bool, battery: Int? = nil, memoryUsed: Int, memoryTotal: Int, memoryPressure: Pressure = .normal,
                sessionMemory: Int = 0, keepAwake: Bool, worth: Worth? = nil) {
        self.onPower = onPower; self.battery = battery; self.memoryUsed = memoryUsed; self.memoryTotal = memoryTotal
        self.memoryPressure = memoryPressure; self.sessionMemory = sessionMemory; self.keepAwake = keepAwake; self.worth = worth
    }
}

/// `POST /v1/mac/settings`: only the fields given change.
public struct MacSettings: Codable, Hashable, Sendable {
    public let keepAwake: Bool?
    public init(keepAwake: Bool? = nil) { self.keepAwake = keepAwake }
}

// MARK: Clean Up

public struct CleanupReport: Codable, Hashable, Sendable {
    public struct Archivable: Codable, Hashable, Sendable {
        public let olderThanDays: Int
        /// Conversations Archive would move: pinned and running ones stay.
        public let count: Int
        public let bytes: Int
        public init(olderThanDays: Int, count: Int, bytes: Int) { self.olderThanDays = olderThanDays; self.count = count; self.bytes = bytes }
    }
    /// What conversations take on disk.
    public let conversationBytes: Int
    public let conversations: Int
    /// For 30, 60 and 90 days.
    public let archivable: [Archivable]
    public let archived: Int
    public let worktrees: [LeftWorktree]
    public init(conversationBytes: Int, conversations: Int, archivable: [Archivable], archived: Int, worktrees: [LeftWorktree]) {
        self.conversationBytes = conversationBytes; self.conversations = conversations; self.archivable = archivable
        self.archived = archived; self.worktrees = worktrees
    }
}

public extension CleanupReport {
    /// A worktree no session uses. Removal never forces: a kept one says why instead.
    struct LeftWorktree: Codable, Hashable, Sendable, Identifiable {
        public struct Keep: OpenEnum {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            public static let changes = Self(rawValue: "changes")
            public static let inUse = Self(rawValue: "inUse")
            public static let noBranch = Self(rawValue: "noBranch")
            public static let ignoredFiles = Self(rawValue: "ignoredFiles")
        }
        public let id: String
        public let path: String
        public let branch: String?
        public let bytes: Int?
        public let keep: Keep?
        /// The Mac's words for `keep`, e.g. "Holds .env".
        public let keepReason: String?
        public init(id: String, path: String, branch: String? = nil, bytes: Int? = nil, keep: Keep? = nil, keepReason: String? = nil) {
            self.id = id; self.path = path; self.branch = branch; self.bytes = bytes; self.keep = keep; self.keepReason = keepReason
        }
    }
}

/// `POST /v1/cleanup/archive`.
public struct ArchiveRequest: Codable, Hashable, Sendable {
    public let olderThanDays: Int
    public init(olderThanDays: Int) { self.olderThanDays = olderThanDays }
}

/// `POST /v1/cleanup/archive` and `POST /v1/cleanup/restore`.
public struct CleanupResult: Codable, Hashable, Sendable {
    public let count: Int
    public init(count: Int) { self.count = count }
}

// MARK: Autopilot

public struct AutopilotDecision: Codable, Hashable, Sendable, Identifiable {
    public struct Moved: Codable, Hashable, Sendable {
        public let sessionID: SessionKey
        public let title: String
        public init(sessionID: SessionKey, title: String) { self.sessionID = sessionID; self.title = title }
    }
    public struct Kind: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let moved = Self(rawValue: "moved")
        public static let waiting = Self(rawValue: "waiting")
        public static let failed = Self(rawValue: "failed")
        public static let primed = Self(rawValue: "primed")
        /// A question or plan the Mac answered by itself after a minute; `title` names the session, `reason` the answer.
        public static let answered = Self(rawValue: "answered")
        /// An account at its limit with no free account to move to.
        public static let stuck = Self(rawValue: "stuck")
        /// A move only for priority, held back because the login moved recently.
        public static let priorityWait = Self(rawValue: "priorityWait")
    }
    public let id: String
    public let at: Timestamp
    public let kind: Kind
    /// "Moved 2 sessions Work → Personal", from the Mac.
    public let title: String
    /// "Work reached 95% of its 5-hour limit".
    public let reason: String
    public let from: String?
    public let to: String?
    public let sessions: [Moved]
    /// On a held move: tokens its sessions would write to cache again. Nil when the Mac can't tell.
    public let recacheTokens: Int?
    public init(id: String, at: Timestamp, kind: Kind, title: String, reason: String, from: String? = nil, to: String? = nil, sessions: [Moved] = [],
                recacheTokens: Int? = nil) {
        self.id = id; self.at = at; self.kind = kind; self.title = title; self.reason = reason; self.from = from; self.to = to; self.sessions = sessions
        self.recacheTokens = recacheTokens
    }
}

/// `GET /v1/autopilot`, and what `POST /v1/autopilot/move` returns.
public struct AutopilotState: Codable, Hashable, Sendable {
    public let enabled: Bool
    /// A move Autopilot is holding, e.g. waiting for a pause; Move Now runs it.
    public let pending: AutopilotDecision?
    /// Newest first.
    public let decisions: [AutopilotDecision]
    /// Whether a question with a recommended choice, or a plan, is answered by the Mac after a minute unanswered.
    /// Nil from a Mac without `autopilot.answers`.
    public let answersRecommended: Bool?
    /// Every move held, oldest first; `pending` is the first, which Move Now runs. Nil from a Mac without `rotation`, as are the fields below.
    public let held: [AutopilotDecision]?
    /// Per login in use, where its sessions go next.
    public let next: [NextMove]?
    /// When sessions stopped on a limit can go on.
    public let waiting: WaitingSummary?
    /// The percentage at which Autopilot moves off an account.
    public let swapAt: Int?
    public let followFable: Bool?
    /// Claude Code is running Fable and Autopilot is following it, so Fable's room is what counts.
    public let fableMode: Bool?
    public init(enabled: Bool, pending: AutopilotDecision? = nil, decisions: [AutopilotDecision] = [], answersRecommended: Bool? = nil,
                held: [AutopilotDecision]? = nil, next: [NextMove]? = nil, waiting: WaitingSummary? = nil, swapAt: Int? = nil,
                followFable: Bool? = nil, fableMode: Bool? = nil) {
        self.enabled = enabled; self.pending = pending; self.decisions = decisions; self.answersRecommended = answersRecommended
        self.held = held; self.next = next; self.waiting = waiting; self.swapAt = swapAt; self.followFable = followFable; self.fableMode = fableMode
    }
}

/// The body of `POST /v1/autopilot` and `POST /v1/autopilot/answers`, which answer with the `AutopilotState`. Signed with
/// `ConfirmPurpose.autopilot` by the confirm key, either way.
public struct AutopilotChange: Codable, Hashable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// What an account's usage would have cost at API prices.
public struct Worth: Codable, Hashable, Sendable {
    public let days7: Double
    public let days30: Double
    public let currency: String
    public init(days7: Double, days30: Double, currency: String = "USD") { self.days7 = days7; self.days30 = days30; self.currency = currency }
}

// MARK: Incidents

/// An incident on Anthropic's or OpenAI's status page.
public struct Incident: Codable, Hashable, Sendable, Identifiable {
    public struct Status: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let investigating = Self(rawValue: "investigating")
        public static let identified = Self(rawValue: "identified")
        public static let monitoring = Self(rawValue: "monitoring")
        public static let resolved = Self(rawValue: "resolved")
    }
    public let id: String
    public let provider: AgentProvider
    public let title: String
    public let status: Status
    public let url: String
    public let startedAt: Timestamp?
    public init(id: String, provider: AgentProvider = .claude, title: String, status: Status, url: String, startedAt: Timestamp? = nil) {
        self.id = id; self.provider = provider; self.title = title; self.status = status; self.url = url; self.startedAt = startedAt
    }
}
