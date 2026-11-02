import Foundation

public struct SessionStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// "busy" and "shell" in Claude Code's registry.
    public static let working = Self(rawValue: "working")
    public static let waiting = Self(rawValue: "waiting")
    public static let idle = Self(rawValue: "idle")
    public static let finished = Self(rawValue: "finished")
    public static let starting = Self(rawValue: "starting")
    public static let exited = Self(rawValue: "exited")
    /// The Mac couldn't establish the state (a Codex rollout tail with no turn marker). It
    /// authorizes nothing: no Continue on phone, no interrupt, no `auto` typing.
    public static let unknown = Self(rawValue: "unknown")
}

public struct SessionFlag: Codable, Hashable, Sendable {
    public struct Kind: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let stuck = Self(rawValue: "stuck")
        public static let loop = Self(rawValue: "loop")
        public static let failing = Self(rawValue: "failing")
        public static let bloated = Self(rawValue: "bloated")
        /// A reply that didn't arrive. `replyTerminal`: a steer Codex dropped, still pending when the turn was interrupted
        /// or unseen 30 s after the thread went idle, «Didn't reach Codex: "…"». `replyInbox`: no hook took it from the
        /// inbox within 5 s, so the Mac took it back, «Didn't reach Claude: "…"». The quote is the first 80 characters;
        /// the next message that goes through clears it.
        public static let unsent = Self(rawValue: "unsent")
    }
    public let kind: Kind
    public let text: String
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

/// What the phone may do with a session right now, decided on the Mac.
public struct SessionAbility: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let transcript = Self(rawValue: "transcript")
    public static let followUp = Self(rawValue: "followUp")
    public static let note = Self(rawValue: "note")
    public static let interrupt = Self(rawValue: "interrupt")
    /// Hosted: free text at any time.
    public static let type = Self(rawValue: "type")
    public static let terminal = Self(rawValue: "terminal")
    public static let continueOnPhone = Self(rawValue: "continueOnPhone")
    public static let end = Self(rawValue: "end")
    /// A Codex session outside Side A's panes, reached through Codex's shared app server: a reply shows in its terminal
    /// as the user's message. Idle starts a turn; mid-turn `.auto` steers, while `.followUp` or `submit: .queue` waits
    /// for the turn's end. `.note` is 409 `cannot_deliver`, `.keys` 409 `not_hosted`.
    public static let replyTerminal = Self(rawValue: "replyTerminal")
    /// A Claude session outside Side A's panes, idle or finished, whose inbox hook is waiting: a reply wakes it and
    /// Claude Code shows the model the text as a note, not as user input. Delivery `.inbox`.
    public static let replyInbox = Self(rawValue: "replyInbox")
    /// `POST /v1/sessions/{id}/settings` takes `model`.
    public static let settingsModel = Self(rawValue: "settings.model")
    /// … takes `effort`.
    public static let settingsEffort = Self(rawValue: "settings.effort")
    /// … takes `mode`.
    public static let settingsMode = Self(rawValue: "settings.mode")
    /// … takes `fast`.
    public static let settingsFast = Self(rawValue: "settings.fast")
    /// `GET /v1/sessions/{id}/turns/{turnID}/diff` for `turnID`.
    public static let turnDiff = Self(rawValue: "turnDiff")
    /// `POST /v1/sessions/{id}/compact`, idle only (Codex `thread/compact/start`).
    public static let compact = Self(rawValue: "compact")
    /// `POST /v1/sessions/{id}/review`, idle only (Codex `review/start`).
    public static let review = Self(rawValue: "review")
}

public struct MailState: Codable, Hashable, Sendable {
    public struct Kind: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let note = Self(rawValue: "note")
        public static let stop = Self(rawValue: "stop")
    }
    public let kind: Kind
    public let at: Timestamp
    public init(kind: Kind, at: Timestamp) { self.kind = kind; self.at = at }
}

/// One row per live agent process, plus hosted tmux sessions that have no agent process yet.
public struct RemoteSession: Codable, Hashable, Sendable, Identifiable {
    /// The conversation id when known; otherwise `pid-<pid>-<started>`, or `tmux-<name>` for a hosted session still starting.
    public let id: SessionKey
    /// Claude session id or Codex thread id; transcripts are keyed by it.
    public var conversationID: String?
    public var agent: AgentProvider
    /// The same title the Mac shows.
    public var title: String
    public var cwd: String?
    /// A worktree names its main repo.
    public var project: String
    public var branch: String?
    public var worktree: Bool
    public var accountID: String?
    public var accountName: String?
    /// The same as `settings.model`, for phones that predate `settings`.
    public var model: String?
    /// The same as `settings.effort`, for phones that predate `settings`.
    public var effort: String?
    public var status: SessionStatus
    /// Claude Code's own words, e.g. "permission".
    public var waitingFor: String?
    public var statusAt: Timestamp?
    public var lastReplyAt: Timestamp?
    /// The current step line.
    public var step: String?
    /// Tokens.
    public var context: Int?
    /// How full the context window is, 0–100: Claude's statusline `used_percentage`, Codex's last tokens over the window.
    public var contextPercent: Double?
    public var flag: SessionFlag?
    /// USD so far: Claude's statusline or transcript, Codex's `threadUsage.estimatedUsageUsdMicros`.
    public var cost: Double?
    /// In arrival order.
    public var openRequests: [RequestID]
    /// A note or stop not yet taken.
    public var mail: MailState?
    /// The tmux session name when hosted.
    public var hosted: String?
    @Sorted public var abilities: Set<SessionAbility>
    /// Why an ability the phone shows is missing, keyed by its raw value: "Claude is working. Try when it's idle."
    public var abilityReasons: [String: String]?
    /// Model, effort, mode and fast as the session runs now.
    public var settings: SessionSettings?
    /// The running turn, else the last one: what `turnDiff` reads.
    public var turnID: String?
    /// The turn's live plan list.
    public var plan: TurnPlan?
    /// Subagents and background shells still running (Claude's `background_tasks`, Codex subagents).
    public var backgroundTasks: Int?
    /// Stopped on its account's limit, by its own last reply. Nil from a Mac without `rotation`.
    public var limit: SessionLimit?
    /// `claude -p` and SDK runs: listed, never offered Reply.
    public var headless: Bool
    /// What its process tree listens on.
    public var ports: [ListeningPort]?
    /// Its process tree's memory.
    public var memoryBytes: Int?

    public init(id: SessionKey, conversationID: String? = nil, agent: AgentProvider, title: String, cwd: String? = nil, project: String,
                branch: String? = nil, worktree: Bool = false, accountID: String? = nil, accountName: String? = nil, model: String? = nil,
                effort: String? = nil, status: SessionStatus, waitingFor: String? = nil, statusAt: Timestamp? = nil,
                lastReplyAt: Timestamp? = nil, step: String? = nil, context: Int? = nil, flag: SessionFlag? = nil, cost: Double? = nil,
                openRequests: [RequestID] = [], mail: MailState? = nil, hosted: String? = nil, abilities: Set<SessionAbility> = [],
                headless: Bool = false, ports: [ListeningPort]? = nil, memoryBytes: Int? = nil, contextPercent: Double? = nil,
                abilityReasons: [String: String]? = nil, settings: SessionSettings? = nil, turnID: String? = nil, plan: TurnPlan? = nil,
                backgroundTasks: Int? = nil, limit: SessionLimit? = nil) {
        self.limit = limit
        self.id = id; self.conversationID = conversationID; self.agent = agent; self.title = title; self.cwd = cwd
        self.project = project; self.branch = branch; self.worktree = worktree; self.accountID = accountID
        self.accountName = accountName; self.model = model; self.effort = effort; self.status = status
        self.waitingFor = waitingFor; self.statusAt = statusAt; self.lastReplyAt = lastReplyAt; self.step = step
        self.context = context; self.flag = flag; self.cost = cost; self.openRequests = openRequests; self.mail = mail
        self.hosted = hosted; self.abilities = abilities; self.headless = headless; self.ports = ports; self.memoryBytes = memoryBytes
        self.contextPercent = contextPercent; self.abilityReasons = abilityReasons; self.settings = settings; self.turnID = turnID
        self.plan = plan; self.backgroundTasks = backgroundTasks
    }

    /// Why `ability` is off, when the Mac said.
    public func reason(_ ability: SessionAbility) -> String? { abilityReasons?[ability.rawValue] }
}

/// The twin of `Island.Ready`: a turn that ended with nothing left running.
public struct FinishedSession: Codable, Hashable, Sendable, Identifiable {
    public var id: SessionKey { sessionID }
    public let sessionID: SessionKey
    /// Names this finished turn and no other; a follow-up carries it so it can't land on a later turn.
    public let turnID: String
    public let title: String
    /// First line of prose, at most 160 characters.
    public let summary: String
    public let at: Timestamp
    /// A Stop hook is waiting, or the session is hosted.
    public let canFollowUp: Bool
    public init(sessionID: SessionKey, turnID: String, title: String, summary: String, at: Timestamp, canFollowUp: Bool) {
        self.sessionID = sessionID; self.turnID = turnID; self.title = title; self.summary = summary; self.at = at
        self.canFollowUp = canFollowUp
    }
}

public struct Worktree: Codable, Hashable, Sendable {
    public let path: String
    public let branch: String
    public init(path: String, branch: String) { self.path = path; self.branch = branch }
}

public struct HostedSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    /// `sa-<project>-<4hex>`.
    public let name: String
    public let agent: AgentProvider
    public let cwd: String
    public let project: String
    public let worktree: Worktree?
    /// The `RemoteSession` running in it, once known.
    public let sessionID: SessionKey?
    public let createdAt: Timestamp
    public let macAttached: Bool
    /// Phone terminal viewers.
    public let viewers: Int
    /// The pane is still running (remain-on-exit keeps dead panes).
    public let alive: Bool
    public let exitStatus: Int?
    public init(name: String, agent: AgentProvider, cwd: String, project: String, worktree: Worktree? = nil, sessionID: SessionKey? = nil,
                createdAt: Timestamp, macAttached: Bool = false, viewers: Int = 0, alive: Bool = true, exitStatus: Int? = nil) {
        self.name = name; self.agent = agent; self.cwd = cwd; self.project = project; self.worktree = worktree
        self.sessionID = sessionID; self.createdAt = createdAt; self.macAttached = macAttached; self.viewers = viewers
        self.alive = alive; self.exitStatus = exitStatus
    }
}

/// Event `hosted.attention`: a hosted session needs someone at its screen.
public struct HostedAttention: Codable, Hashable, Sendable {
    public struct Kind: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// A folder-trust dialog. With capability `hosted.trust`, Trust and Start is `POST /v1/hosted/{name}/trust`.
        public static let trust = Self(rawValue: "trust")
        /// The screen stopped changing in a state Side A doesn't recognise.
        public static let screen = Self(rawValue: "screen")
        /// A typed prompt that may not have been submitted.
        public static let unsent = Self(rawValue: "unsent")
    }
    public let name: String
    public let kind: Kind
    /// The last screen lines, or the trust dialog's question.
    public let text: String
    public init(name: String, kind: Kind, text: String) { self.name = name; self.kind = kind; self.text = text }
}

public struct StartHosted: Codable, Hashable, Sendable {
    /// A `RemoteProject.path`.
    public let cwd: String
    public let agent: AgentProvider
    public let model: String?
    public let effort: String?
    /// `--permission-mode` (Claude) or `-a`/`-s` (Codex). A mode that `raises` needs the confirm key after Face ID.
    public let permissionMode: PermissionMode?
    /// A new worktree on `sidea/<name>`.
    public let worktree: Bool
    /// Nil: whatever the shell line picks.
    public let accountID: String?
    public let prompt: String?
    public let attachments: [String]
    /// Conversation id to resume.
    public let resume: String?
    public let fork: Bool
    public init(cwd: String, agent: AgentProvider, model: String? = nil, effort: String? = nil, worktree: Bool = false,
                accountID: String? = nil, prompt: String? = nil, attachments: [String] = [], resume: String? = nil, fork: Bool = false,
                permissionMode: PermissionMode? = nil) {
        self.cwd = cwd; self.agent = agent; self.model = model; self.effort = effort; self.worktree = worktree
        self.permissionMode = permissionMode
        self.accountID = accountID; self.prompt = prompt; self.attachments = attachments; self.resume = resume; self.fork = fork
    }
}

public struct RemoteProject: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let gitRoot: String?
    public let branch: String?
    /// Up to 20, most recently committed first.
    public let branches: [String]
    public let lastUsedAt: Timestamp?
    public let liveSessions: Int
    public init(path: String, name: String, gitRoot: String? = nil, branch: String? = nil, branches: [String] = [],
                lastUsedAt: Timestamp? = nil, liveSessions: Int = 0) {
        self.path = path; self.name = name; self.gitRoot = gitRoot; self.branch = branch; self.branches = branches
        self.lastUsedAt = lastUsedAt; self.liveSessions = liveSessions
    }
}

/// A search result.
public struct PastSession: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let agent: AgentProvider
    public let title: String
    public let project: String
    public let cwd: String?
    public let branch: String?
    public let firstAt: Timestamp?
    public let lastAt: Timestamp?
    public let snippet: String?
    public let snippetUUID: String?
    /// The conversation this one was forked from.
    public let parentID: String?
    public let pinned: Bool?
    public let archived: Bool?
    /// A title given in Side A; `title` already shows it.
    public let customTitle: String?
    public init(id: String, agent: AgentProvider, title: String, project: String, cwd: String? = nil, branch: String? = nil,
                firstAt: Timestamp? = nil, lastAt: Timestamp? = nil, snippet: String? = nil, snippetUUID: String? = nil,
                parentID: String? = nil, pinned: Bool? = nil, archived: Bool? = nil, customTitle: String? = nil) {
        self.id = id; self.agent = agent; self.title = title; self.project = project; self.cwd = cwd; self.branch = branch
        self.firstAt = firstAt; self.lastAt = lastAt; self.snippet = snippet; self.snippetUUID = snippetUUID
        self.parentID = parentID; self.pinned = pinned; self.archived = archived; self.customTitle = customTitle
    }
}
