import Foundation

/// `GET /v1/state`, and the `snapshot` event.
public struct StateSnapshot: Codable, Hashable, Sendable {
    public let seq: Int
    public let epoch: String
    public let sessions: [RemoteSession]
    public let finished: [FinishedSession]
    public let requests: [RemoteRequest]
    public let hosted: [HostedSession]
    public let accounts: [RemoteAccount]
    public let mac: MacState?
    public let incidents: [Incident]?
    public let autopilot: AutopilotState?
    /// Capability `replies.dropped`: queued replies the Mac gave up on lately. Left out when there are none.
    public private(set) var droppedReplies: [DroppedReply]?
    public init(seq: Int, epoch: String, sessions: [RemoteSession] = [], finished: [FinishedSession] = [], requests: [RemoteRequest] = [],
                hosted: [HostedSession] = [], accounts: [RemoteAccount] = [], mac: MacState? = nil, incidents: [Incident]? = nil,
                autopilot: AutopilotState? = nil, droppedReplies: [DroppedReply]? = nil) {
        self.autopilot = autopilot
        self.droppedReplies = droppedReplies
        self.seq = seq; self.epoch = epoch; self.sessions = sessions; self.finished = finished; self.requests = requests
        self.hosted = hosted; self.accounts = accounts; self.mac = mac; self.incidents = incidents
    }
}

public extension StateSnapshot {
    /// What one device may read: its own dropped replies, and only that one of the others' exists.
    func scoped(to device: String) -> StateSnapshot {
        var scoped = self
        scoped.droppedReplies = droppedReplies?.map { $0.seen(by: device) }
        return scoped
    }
}

/// A reply answered `.queued` that won't be sent. It outlives the `finished.resolve` that announced it, which a phone away
/// past the replay window or a relaunched Mac never replays.
public struct DroppedReply: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sessionID: SessionKey
    /// Only for the device that sent it.
    public let text: String?
    public let at: Timestamp
    /// The device that sent it, told only to that device.
    public let device: String?
    public let reason: Reason

    public struct Reason: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let sessionEnded = Self(rawValue: "sessionEnded")
        /// The turn ended with a Stop hook that doesn't wait.
        public static let cannotWait = Self(rawValue: "cannotWait")
        /// The session asks more now than was proven when it was sent.
        public static let outranked = Self(rawValue: "outranked")
        /// Held in a file from an older Side A, which can't say who authorized it, so it carries no text or device: a phone
        /// gives back its own Queued turns in that session from before `at`.
        public static let oldQueue = Self(rawValue: "oldQueue")
    }

    public init(id: String, sessionID: SessionKey, text: String?, at: Timestamp, device: String?, reason: Reason) {
        self.id = id; self.sessionID = sessionID; self.text = text; self.at = at; self.device = device; self.reason = reason
    }

    public func seen(by viewer: String) -> DroppedReply {
        device == viewer ? self : DroppedReply(id: id, sessionID: sessionID, text: nil, at: at, device: nil, reason: reason)
    }
}

// REST list bodies. Each carries the event `seq` it reflects.

public struct SessionList: Codable, Hashable, Sendable {
    public let sessions: [RemoteSession]
    public let finished: [FinishedSession]
    public let seq: Int
    public init(sessions: [RemoteSession], finished: [FinishedSession], seq: Int) { self.sessions = sessions; self.finished = finished; self.seq = seq }
}

public struct RequestList: Codable, Hashable, Sendable {
    public let requests: [RemoteRequest]
    public let seq: Int
    public init(requests: [RemoteRequest], seq: Int) { self.requests = requests; self.seq = seq }
}

public struct HostedList: Codable, Hashable, Sendable {
    public let hosted: [HostedSession]
    public let seq: Int
    public init(hosted: [HostedSession], seq: Int) { self.hosted = hosted; self.seq = seq }
}

public struct AccountList: Codable, Hashable, Sendable {
    public let accounts: [RemoteAccount]
    public let seq: Int
    public init(accounts: [RemoteAccount], seq: Int) { self.accounts = accounts; self.seq = seq }
}

public struct ProjectList: Codable, Hashable, Sendable {
    public let projects: [RemoteProject]
    public init(projects: [RemoteProject]) { self.projects = projects }
}

public struct SearchResults: Codable, Hashable, Sendable {
    public let results: [PastSession]
    public let next: Cursor?
    public init(results: [PastSession], next: Cursor? = nil) { self.results = results; self.next = next }
}

public struct Welcome: Codable, Hashable, Sendable {
    public let epoch: String
    /// The server's current seq.
    public let seq: Int
    /// True: events lastSeq+1…seq follow. False: a snapshot follows.
    public let replay: Bool
    /// With `replay` false: the snapshot is over 512 KiB, so fetch `GET /v1/state` (held at this seq for 30 s).
    public let snapshotOverREST: Bool
    public let hello: Hello
    public init(epoch: String, seq: Int, replay: Bool, snapshotOverREST: Bool = false, hello: Hello) {
        self.epoch = epoch; self.seq = seq; self.replay = replay; self.snapshotOverREST = snapshotOverREST; self.hello = hello
    }
}

public struct TranscriptDelta: Codable, Hashable, Sendable {
    public let sessionID: SessionKey
    public let generation: String
    /// Ascending seq.
    public let messages: [TranscriptMessage]
    /// The new `after` cursor, covering these rows and revisions.
    public let cursor: Cursor
    public init(sessionID: SessionKey, generation: String, messages: [TranscriptMessage], cursor: Cursor) {
        self.sessionID = sessionID; self.generation = generation; self.messages = messages; self.cursor = cursor
    }
}

/// What the Mac sends on `/v1/ws/events`, as `{"type": …, "data": …}`.
public enum ServerEvent: Hashable, Sendable {
    // control
    case welcome(Welcome)
    case snapshot(StateSnapshot)
    /// quit, update, sleep
    case bye(reason: String)
    /// The `bye` reason that says the Mac is going to sleep. Any other reason, or none, is a Mac on its way back.
    public static let byeSleep = "sleep"
    // state (sequenced)
    case sessionUpsert(RemoteSession)
    case sessionRemove(id: SessionKey, replacedBy: SessionKey?)
    case requestAdd(RemoteRequest)
    case requestResolve(RequestResolution)
    case finishedAdd(FinishedSession)
    /// replied, resumed, released, expired
    case finishedResolve(sessionID: SessionKey, reason: String)
    /// Only the accounts that changed.
    case usageUpdate([RemoteAccount])
    /// An account removed from the Mac's library. An older phone decodes it as `.unknown` and drops the row at its
    /// next snapshot.
    case accountRemove(id: String)
    case hostedUpsert(HostedSession)
    case hostedRemove(name: String)
    /// A trust dialog, a stuck screen or an unsent prompt in a hosted session.
    case hostedAttention(HostedAttention)
    case macUpdate(MacState)
    /// Every open incident; an empty list clears them.
    case incidentUpdate([Incident])
    /// Autopilot's whole state, when it changed. An older phone decodes it as `.unknown` and reads `GET /v1/autopilot`.
    case autopilotUpdate(AutopilotState)
    // transcript (per subscription, unsequenced)
    case transcriptAppend(TranscriptDelta)
    case transcriptReplace(TranscriptDelta)
    case transcriptReset(sessionID: SessionKey, generation: String)
    /// Decoded and ignored.
    case unknown(type: String)

    public var type: String {
        switch self {
        case .welcome: "welcome"
        case .snapshot: "snapshot"
        case .bye: "bye"
        case .sessionUpsert: "session.upsert"
        case .sessionRemove: "session.remove"
        case .requestAdd: "request.add"
        case .requestResolve: "request.resolve"
        case .finishedAdd: "finished.add"
        case .finishedResolve: "finished.resolve"
        case .usageUpdate: "usage.update"
        case .accountRemove: "account.remove"
        case .hostedUpsert: "hosted.upsert"
        case .hostedRemove: "hosted.remove"
        case .hostedAttention: "hosted.attention"
        case .macUpdate: "mac.update"
        case .incidentUpdate: "incident.update"
        case .autopilotUpdate: "autopilot.update"
        case .transcriptAppend: "transcript.append"
        case .transcriptReplace: "transcript.replace"
        case .transcriptReset: "transcript.reset"
        case .unknown(let type): type
        }
    }

    /// State events carry a `seq` and are kept in the server's replay ring.
    public var isState: Bool {
        switch self {
        case .welcome, .snapshot, .bye, .transcriptAppend, .transcriptReplace, .transcriptReset, .unknown: false
        default: true
        }
    }
}

extension ServerEvent: Codable {
    private struct Reason: Codable { let reason: String }
    private struct Removal: Codable { let id: SessionKey; let replacedBy: SessionKey? }
    private struct FinishedResolution: Codable { let sessionID: SessionKey; let reason: String }
    private struct Name: Codable { let name: String }
    private struct Identity: Codable { let id: String }
    private struct Reset: Codable { let sessionID: SessionKey; let generation: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let type = try c.value("type", as: String.self)
        func data<T: Decodable>(_: T.Type = T.self) throws -> T { try c.value("data") }
        switch type {
        case "welcome": self = .welcome(try data())
        case "snapshot": self = .snapshot(try data())
        case "bye": self = .bye(reason: try data(Reason.self).reason)
        case "session.upsert": self = .sessionUpsert(try data())
        case "session.remove": let r = try data(Removal.self); self = .sessionRemove(id: r.id, replacedBy: r.replacedBy)
        case "request.add": self = .requestAdd(try data())
        case "request.resolve": self = .requestResolve(try data())
        case "finished.add": self = .finishedAdd(try data())
        case "finished.resolve": let r = try data(FinishedResolution.self); self = .finishedResolve(sessionID: r.sessionID, reason: r.reason)
        case "usage.update": self = .usageUpdate(try data())
        case "account.remove": self = .accountRemove(id: try data(Identity.self).id)
        case "hosted.upsert": self = .hostedUpsert(try data())
        case "hosted.remove": self = .hostedRemove(name: try data(Name.self).name)
        case "hosted.attention": self = .hostedAttention(try data())
        case "mac.update": self = .macUpdate(try data())
        case "incident.update": self = .incidentUpdate(try data())
        case "autopilot.update": self = .autopilotUpdate(try data())
        case "transcript.append": self = .transcriptAppend(try data())
        case "transcript.replace": self = .transcriptReplace(try data())
        case "transcript.reset": let r = try data(Reset.self); self = .transcriptReset(sessionID: r.sessionID, generation: r.generation)
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.put(type, "type")
        switch self {
        case .welcome(let value): try c.put(value, "data")
        case .snapshot(let value): try c.put(value, "data")
        case .bye(let reason): try c.put(Reason(reason: reason), "data")
        case .sessionUpsert(let value): try c.put(value, "data")
        case .sessionRemove(let id, let replacedBy): try c.put(Removal(id: id, replacedBy: replacedBy), "data")
        case .requestAdd(let value): try c.put(value, "data")
        case .requestResolve(let value): try c.put(value, "data")
        case .finishedAdd(let value): try c.put(value, "data")
        case .finishedResolve(let sessionID, let reason): try c.put(FinishedResolution(sessionID: sessionID, reason: reason), "data")
        case .usageUpdate(let value): try c.put(value, "data")
        case .accountRemove(let id): try c.put(Identity(id: id), "data")
        case .hostedUpsert(let value): try c.put(value, "data")
        case .hostedRemove(let name): try c.put(Name(name: name), "data")
        case .hostedAttention(let value): try c.put(value, "data")
        case .macUpdate(let value): try c.put(value, "data")
        case .incidentUpdate(let value): try c.put(value, "data")
        case .autopilotUpdate(let value): try c.put(value, "data")
        case .transcriptAppend(let value), .transcriptReplace(let value): try c.put(value, "data")
        case .transcriptReset(let sessionID, let generation): try c.put(Reset(sessionID: sessionID, generation: generation), "data")
        case .unknown: break
        }
    }
}

/// One server frame: `{"seq": 41, "at": …, "type": "session.upsert", "data": {…}}`.
public struct EventEnvelope: Codable, Hashable, Sendable {
    /// State events only; transcript and control events have none.
    public let seq: Int?
    public let at: Timestamp
    public let event: ServerEvent
    public init(seq: Int? = nil, at: Timestamp, event: ServerEvent) { self.seq = seq; self.at = at; self.event = event }

    private enum CodingKeys: String, CodingKey { case seq, at }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        at = try c.decode(Timestamp.self, forKey: .at)
        event = try ServerEvent(from: decoder)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(seq, forKey: .seq)
        try c.encode(at, forKey: .at)
        try event.encode(to: encoder)
    }
}

/// What the phone sends on `/v1/ws/events`, framed like `ServerEvent`.
public enum ClientMessage: Hashable, Sendable {
    case hello(epoch: String?, lastSeq: Int?, capabilities: Set<Capability>)
    /// Session → the latest `after` cursor held, unchanged (nil: nothing held yet).
    case subscribe(sessions: [SessionKey: Cursor?])
    case unsubscribe(sessions: [SessionKey])
    case presence(foreground: Bool, viewing: SessionKey?)
    case unknown(type: String)

    public var type: String {
        switch self {
        case .hello: "hello"
        case .subscribe: "subscribe"
        case .unsubscribe: "unsubscribe"
        case .presence: "presence"
        case .unknown(let type): type
        }
    }
}

extension ClientMessage: Codable {
    private struct Hello: Codable { let epoch: String?; let lastSeq: Int?; @Sorted var capabilities: Set<Capability> }
    private struct Subscribe: Codable { let sessions: [SessionKey: Cursor?] }
    private struct Unsubscribe: Codable { let sessions: [SessionKey] }
    private struct Presence: Codable { let foreground: Bool; let viewing: SessionKey? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let type = try c.value("type", as: String.self)
        switch type {
        case "hello": let h = try c.value("data", as: Hello.self); self = .hello(epoch: h.epoch, lastSeq: h.lastSeq, capabilities: h.capabilities)
        case "subscribe": self = .subscribe(sessions: try c.value("data", as: Subscribe.self).sessions)
        case "unsubscribe": self = .unsubscribe(sessions: try c.value("data", as: Unsubscribe.self).sessions)
        case "presence": let p = try c.value("data", as: Presence.self); self = .presence(foreground: p.foreground, viewing: p.viewing)
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.put(type, "type")
        switch self {
        case .hello(let epoch, let lastSeq, let capabilities): try c.put(Hello(epoch: epoch, lastSeq: lastSeq, capabilities: capabilities), "data")
        case .subscribe(let sessions): try c.put(Subscribe(sessions: sessions), "data")
        case .unsubscribe(let sessions): try c.put(Unsubscribe(sessions: sessions), "data")
        case .presence(let foreground, let viewing): try c.put(Presence(foreground: foreground, viewing: viewing), "data")
        case .unknown: break
        }
    }
}
