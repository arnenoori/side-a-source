import Foundation

public extension Capability {
    /// This computer accepts sessions moved from another of the user's computers, and can send its own.
    static let moves = Self(rawValue: "moves")
    /// A client that is another computer running Side A, not a phone: it gets no pushes and is listed with computers.
    static let computer = Self(rawValue: "computer")
}

public extension ErrorCode {
    /// The conversation is on another computer now; `details.host` names it.
    static let moved = Self(rawValue: "moved")
    static let moveRefused = Self(rawValue: "move_refused")
    static let noMove = Self(rawValue: "no_move")
    /// 403: a route for linked computers was called with a phone's token.
    static let notComputer = Self(rawValue: "not_computer")
}

/// One computer asks another to take a session (`POST /v1/moves`). Nothing has been stopped yet.
public struct MoveOffer: Codable, Hashable, Sendable {
    public let id: String
    public let conversationID: String
    public let agent: AgentProvider
    /// The repository's short name, for the landing folder and the session's name.
    public let project: String
    public let title: String?
    /// Commits the workspace builds on, nearest first: the answer says which the receiver has.
    public let commits: [String]
    public let origin: String?
    public let model: String?
    public let effort: String?
    public let permissionMode: PermissionMode?
    /// Who is sending, as the receiver shows it.
    public let from: MacInfo
    /// The account the session runs on, when it runs on one of its own (a pooled session has none).
    public let account: MoveAccount?
    public init(id: String, conversationID: String, agent: AgentProvider, project: String, title: String? = nil, commits: [String],
                origin: String? = nil, model: String? = nil, effort: String? = nil, permissionMode: PermissionMode? = nil, from: MacInfo,
                account: MoveAccount? = nil) {
        self.id = id; self.conversationID = conversationID; self.agent = agent; self.project = project; self.title = title
        self.commits = commits; self.origin = origin; self.model = model; self.effort = effort
        self.permissionMode = permissionMode; self.from = from; self.account = account
    }
}

/// Which account a session runs on, by what both computers can compare: the email its login belongs to.
public struct MoveAccount: Codable, Hashable, Sendable {
    public let email: String
    public let name: String
    public init(email: String, name: String) { self.email = email; self.name = name }
}

public struct MoveAnswer: Codable, Hashable, Sendable {
    /// The commits from the offer this computer already has; the sender leaves them out.
    public let have: [String]
    /// The mode the session will run with here, when it is not the one it had.
    public let permissionMode: PermissionMode?
    /// Where it will land, for the sheet: a worktree of a repository already here, or a new clone.
    public let landing: String?
    /// What this computer has for the offer's account. Absent when the offer named none, or from a build that predates it.
    public let account: Account?
    public init(have: [String], permissionMode: PermissionMode? = nil, landing: String? = nil, account: Account? = nil) {
        self.have = have; self.permissionMode = permissionMode; self.landing = landing; self.account = account
    }

    public struct Account: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Signed in to that account here: the session runs on it and no login is sent.
        public static let here = Self(rawValue: "here")
        /// Not signed in to it. Send the login with `commit`; without one the session runs on another account here.
        public static let wanted = Self(rawValue: "wanted")
        /// Not signed in to anything for this agent: without the login the session cannot run here.
        public static let missing = Self(rawValue: "missing")
    }
}

/// A login handed over with a session, inside `MoveCommit`. A login lives on one computer at a time: the sender has
/// taken it out of use before sending, and deletes its copy only when `MoveState.account` says it is stored.
public struct MoveLogin: Codable, Hashable, Sendable {
    public let email: String
    public let name: String
    /// The CLI's own stored login, as JSON text: Claude Code's credential item, or Codex's `auth.json`.
    public let login: String
    public init(email: String, name: String, login: String) { self.email = email; self.name = name; self.login = login }
}

/// The body of `POST /v1/moves/{id}/commit`. An empty object from a sender with nothing to add.
public struct MoveCommit: Codable, Hashable, Sendable {
    public let login: MoveLogin?
    public init(login: MoveLogin? = nil) { self.login = login }
}

/// A file that was sent in pieces (`POST /v1/moves/{id}/parts/{name}/{index}`), as the receiver must have it.
public struct MovePart: Codable, Hashable, Sendable {
    public let name: String
    public let sha256: String
    public let size: Int
    public init(name: String, sha256: String, size: Int) { self.name = name; self.sha256 = sha256; self.size = size }
}

/// Everything is sent: check it and put it in place, without starting it (`POST /v1/moves/{id}/stage`).
public struct MoveStage: Codable, Hashable, Sendable {
    public let parts: [MovePart]
    public init(parts: [MovePart]) { self.parts = parts }
}

/// Where a move stands on the receiving computer.
public struct MoveState: Codable, Hashable, Sendable {
    public struct Status: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Never heard of it, and it will not be started here.
        public static let none = Self(rawValue: "none")
        public static let staging = Self(rawValue: "staging")
        /// Checked and in place, not running.
        public static let staged = Self(rawValue: "staged")
        /// Asked to start and starting. It may yet fail: the sender waits and asks again, and does nothing on this.
        public static let starting = Self(rawValue: "starting")
        public static let live = Self(rawValue: "live")
        public static let discarded = Self(rawValue: "discarded")
    }

    public let id: String
    public let status: Status
    /// The hosted session it runs in here, once live.
    public let session: String?
    public let folder: String?
    /// The email of the account whose login arrived with this move and is stored here.
    public let account: String?
    public init(id: String, status: Status, session: String? = nil, folder: String? = nil, account: String? = nil) {
        self.id = id; self.status = status; self.session = session; self.folder = folder; self.account = account
    }
}
