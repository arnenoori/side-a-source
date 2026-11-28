import Foundation

public extension SessionAbility {
    /// `POST /v1/sessions/{id}/move` can send this session to a computer in `GET /v1/computers`. A host with
    /// `moves.when` offers it for a working session too, which then goes with `MoveRequest.when`.
    static let move = Self(rawValue: "move")
}

public extension Capability {
    /// `MoveRequest.when` is honoured: a working session can move when its turn ends or at once, and
    /// `DELETE /v1/moves/{id}` cancels one that is waiting.
    static let movesWhen = Self(rawValue: "moves.when")
}

/// The second half of linking two computers. The computer that just paired as a client (and so can reach the other)
/// sends this to `POST /v1/computers`, giving the other one the same standing in return: where it listens, the key
/// to pin, and a token for its server. After it, either can send the other a session.
public struct ComputerLink: Codable, Hashable, Sendable {
    public let mac: MacInfo
    public let endpoints: Endpoints
    /// base64url SHA-256 of the sender's TLS SPKI: what the receiver pins when it calls back.
    public let serverKeyHash: String
    public let relay: RelayInfo?
    /// A token for the sender's server, made for the receiver.
    public let token: String
    /// The device id and secret (32 bytes, base64url) the receiver shows the relay to reach the sender's tunnel.
    public let deviceID: String
    public let deviceSecret: String
    public init(mac: MacInfo, endpoints: Endpoints, serverKeyHash: String, relay: RelayInfo? = nil, token: String, deviceID: String, deviceSecret: String) {
        self.mac = mac; self.endpoints = endpoints; self.serverKeyHash = serverKeyHash; self.relay = relay
        self.token = token; self.deviceID = deviceID; self.deviceSecret = deviceSecret
    }
}

/// 200 from `POST /v1/computers`: the keys the receiver will sign its calls to the sender with (X9.63, base64url),
/// as a phone sends in `PairRequest`.
public struct ComputerLinked: Codable, Hashable, Sendable {
    public let confirmKey: String?
    public let unlockKey: String?
    public init(confirmKey: String? = nil, unlockKey: String? = nil) { self.confirmKey = confirmKey; self.unlockKey = unlockKey }
}

/// A computer this host is linked with, for the phone (`GET /v1/computers`).
public struct RemoteComputer: Codable, Hashable, Sendable, Identifiable {
    /// The other computer's host id: the `MacInfo.id` a phone paired with it knows it by.
    public let id: String
    public let name: String
    public let os: HostOS?
    public init(id: String, name: String, os: HostOS? = nil) { self.id = id; self.name = name; self.os = os }
}

public struct ComputerList: Codable, Hashable, Sendable {
    public let computers: [RemoteComputer]
    public init(computers: [RemoteComputer]) { self.computers = computers }
}

/// The body of `POST /v1/sessions/{id}/move` and of `.../move/preview`.
public struct MoveRequest: Codable, Hashable, Sendable {
    /// A `RemoteComputer.id`.
    public let computer: String
    /// When a working session goes (capability `moves.when`). Absent is `idle`, which a host without the capability
    /// assumes too; a signed move covers it, so a host that drops it refuses the signature.
    public let when: When?
    public init(computer: String, when: When? = nil) { self.computer = computer; self.when = when }

    public struct When: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Only if it is idle now; a working session is refused.
        public static let idle = Self(rawValue: "idle")
        /// When its turn ends, by itself: the record is `waiting` until then, and can be cancelled.
        public static let afterTurn = Self(rawValue: "afterTurn")
        /// Its turn is interrupted, cutting off the tool call in progress, and it moves once it is idle.
        public static let now = Self(rawValue: "now")
    }
}

/// What a move would do, asked of both computers before anything is stopped (`POST /v1/sessions/{id}/move/preview`).
public struct MovePreview: Codable, Hashable, Sendable {
    public let computer: RemoteComputer
    /// Where the work lands there: a folder beside a repository it has, or a new clone.
    public let landing: String?
    /// The mode the session will run with there, when it is not the one it has.
    public let permissionMode: PermissionMode?
    /// The account the session runs on, and what happens to its login.
    public let account: String?
    public let login: Login?
    public init(computer: RemoteComputer, landing: String? = nil, permissionMode: PermissionMode? = nil, account: String? = nil, login: Login? = nil) {
        self.computer = computer; self.landing = landing; self.permissionMode = permissionMode; self.account = account; self.login = login
    }

    public struct Login: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// The other computer is signed in to the account already.
        public static let there = Self(rawValue: "there")
        /// The login goes with the session and this computer stops using the account.
        public static let sent = Self(rawValue: "sent")
        /// The session will run on another account the other computer is signed in to.
        public static let other = Self(rawValue: "other")
    }
}

/// A session this host sent to another computer, or is sending (`GET /v1/moves`, and 202 from the move itself).
public struct MoveRecord: Codable, Hashable, Sendable, Identifiable {
    public struct State: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Stopped here and on its way. Nothing can be sent to it yet.
        public static let moving = Self(rawValue: "moving")
        /// Running on the other computer.
        public static let away = Self(rawValue: "away")
        /// The other computer was asked to start it and never answered: it may be running there.
        public static let unknown = Self(rawValue: "unknown")
        /// The move did not happen and the session runs here again; `message` says why.
        public static let failed = Self(rawValue: "failed")
        /// Running here, and moving by itself when its turn ends (`MoveRequest.when` `afterTurn`).
        /// `DELETE /v1/moves/{id}` cancels it; once it starts, the same id goes on as `moving`.
        public static let waiting = Self(rawValue: "waiting")
    }

    public let id: String
    public let conversationID: String
    public let agent: AgentProvider
    public let title: String?
    public let project: String?
    public let state: State
    /// The other computer: its host id and the name to show.
    public let computer: String
    public let computerName: String
    public let at: Timestamp
    /// The hosted session it runs in on the other computer, once it does.
    public let session: String?
    public let message: String?
    public init(id: String, conversationID: String, agent: AgentProvider, title: String? = nil, project: String? = nil, state: State,
                computer: String, computerName: String, at: Timestamp, session: String? = nil, message: String? = nil) {
        self.id = id; self.conversationID = conversationID; self.agent = agent; self.title = title; self.project = project
        self.state = state; self.computer = computer; self.computerName = computerName; self.at = at
        self.session = session; self.message = message
    }
}

public struct MoveList: Codable, Hashable, Sendable {
    public let moves: [MoveRecord]
    public init(moves: [MoveRecord]) { self.moves = moves }
}
