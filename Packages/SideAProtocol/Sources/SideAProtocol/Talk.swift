import Foundation

public enum ReplyMode: String, Codable, Sendable { case auto, followUp, note, keys }

/// "enter", "esc", "tab", "up", "down", "left", "right", "ctrl-c", "backspace", or one printable character.
public struct Key: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let enter = Self(rawValue: "enter")
    public static let esc = Self(rawValue: "esc")
    public static let tab = Self(rawValue: "tab")
    public static let up = Self(rawValue: "up")
    public static let down = Self(rawValue: "down")
    public static let left = Self(rawValue: "left")
    public static let right = Self(rawValue: "right")
    public static let ctrlC = Self(rawValue: "ctrl-c")
    public static let backspace = Self(rawValue: "backspace")
}

/// How a reply to a hosted or `replyTerminal` session that is mid-turn is submitted.
public struct ReplySubmit: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// The next turn: Tab in Codex, Enter in Claude Code.
    public static let queue = Self(rawValue: "queue")
    /// Into the running turn: Enter in Codex. Claude treats it as `.queue`.
    public static let steer = Self(rawValue: "steer")
}

public struct RemoteReply: Codable, Hashable, Sendable {
    /// May be empty only in `.keys` mode.
    public let text: String
    public let mode: ReplyMode
    /// `.keys` mode only; hosted sessions only.
    public let keys: [Key]?
    /// Upload ids (`Upload.id`), never paths.
    public let attachments: [String]
    /// Required when the session is finished: `FinishedSession.turnID`.
    public let turnID: String?
    /// Hosted and `replyTerminal` sessions only; missing means `.queue` on a hosted session and `.steer` on a
    /// `replyTerminal` one.
    public let submit: ReplySubmit?
    /// Capability `replies.queue`: the `QueuedReply.id` this takes the place of, keeping its turn in the queue. 409
    /// `queue_changed` when that reply has gone or changed since.
    public var replaces: String?
    /// Capability `replies.seen`; sent only to a Mac that lists it, since the signature covers the body.
    public var seen: String?
    /// Capability `replies.promote`.
    public var promotes: String?
    public init(text: String, mode: ReplyMode = .auto, keys: [Key]? = nil, attachments: [String] = [], turnID: String? = nil,
                submit: ReplySubmit? = nil) {
        self.text = text; self.mode = mode; self.keys = keys; self.attachments = attachments; self.turnID = turnID; self.submit = submit
    }
}

/// The phone and the Mac must name where a session stands the same way, or `seen` would refuse every reply.
public enum ReplyMark {
    public static let statusPrefix = "status "

    /// The one a reply records as `seen` first. Several, because a turn has one id while it runs and another once
    /// finished, and a notification knows only the finished one.
    public static func marks(_ session: RemoteSession?, _ finished: FinishedSession?) -> [String] {
        let turns = [session?.turnID, finished?.turnID].compactMap { $0 }
        return turns.isEmpty ? [session?.statusAt.map { "\(statusPrefix)\($0)" }].compactMap { $0 } : turns
    }
}

/// The Mac's rule for a reply that names where the session stood (`RemoteReply.seen`): 409 `session_moved_on` unless
/// this still says it.
///
/// The phone is stricter with a reply it held back (`ReplyFlight.movedOn`, `ReplyFlights.unsendable`): it lets one go
/// only while its own mark is still one of the session's, and never with no mark at all. The person typed it hours ago,
/// perhaps, and nothing they saw since says what it now answers. The Mac judges a reply as it arrives, a moment after it
/// was typed, so it also lets through what can't have been a turn the person missed: a session that names no turn, a
/// status mark while it isn't working, and the sender's own earlier reply having started the turn (`chain`).
public enum ReplyAdmission {
    public static func admits(seen: String, marks: Set<String>, working: Bool, chained: @autoclosure () -> Bool) -> Bool {
        if marks.contains(seen) || chained() { return true }
        // A status change names no turn, so only working again says another began; with no turn named now, nothing tells.
        if seen.hasPrefix(ReplyMark.statusPrefix) { return !working }
        return !marks.contains { !$0.hasPrefix(ReplyMark.statusPrefix) }
    }

    /// One of a sender's earlier replies with the same `seen`: the turn it starts is one they meant, so their next reply,
    /// sent before the phone heard of that turn, still names the one before it.
    public struct Earlier: Sendable, Equatable {
        public let at: Timestamp
        public let words: String
        /// The turn it started or joined, once the session's record showed it.
        public let turn: String?
        public init(at: Timestamp, words: String, turn: String?) { self.at = at; self.words = words; self.turn = turn }
    }

    /// Until its turn shows in the record; after that, as long as that turn is the session's.
    public static let chainWindow: TimeInterval = 30
    public static let chainKept: TimeInterval = 3600

    public static func keeps(age: TimeInterval, turnKnown: Bool) -> Bool {
        age < (turnKnown ? chainKept : chainWindow)
    }

    public enum Chain: Equatable, Sendable {
        case none
        case known
        /// The newest turn is this earlier reply's, by its words, and the caller records it.
        case claims(Int)
    }

    /// Time alone can't tell the sender's own new turn from one someone at the Mac started meanwhile; the record can.
    /// Newest first; a turn may be recorded up to 2 s before the reply was, as clocks go.
    public static func chain(_ earlier: [Earlier], newest: (id: String, at: Timestamp, text: String)?, sameWords: (String, String) -> Bool) -> Chain {
        guard !earlier.isEmpty, let newest else { return .none }
        for (index, reply) in earlier.enumerated().reversed() {
            if let turn = reply.turn {
                if turn == newest.id { return .known }
                continue
            }
            guard newest.at >= reply.at - 2, sameWords(newest.text, reply.words) else { continue }
            return .claims(index)
        }
        return .none
    }
}

public extension Capability {
    /// `RemoteReply.seen`, and 409 `session_moved_on`.
    static let repliesSeen = Self(rawValue: "replies.seen")
    /// `RemoteReply.promotes`.
    static let repliesPromote = Self(rawValue: "replies.promote")
}

public struct ReplyResult: Codable, Hashable, Sendable {
    public struct Delivery: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Pasted into the hosted pane, Enter sent; for `replyTerminal`, a steer or a new turn.
        public static let typed = Self(rawValue: "typed")
        /// Handed to the waiting Stop hook.
        public static let followUp = Self(rawValue: "followUp")
        /// Delivered when the session next finishes; for `replyTerminal`, in Codex's own queue.
        public static let queued = Self(rawValue: "queued")
        /// Left as mail.
        public static let note = Self(rawValue: "note")
        /// Left in a `replyInbox` session's inbox; its hook takes it within a second.
        public static let inbox = Self(rawValue: "inbox")
    }
    public let delivery: Delivery
    public let sessionID: SessionKey
    public init(delivery: Delivery, sessionID: SessionKey) { self.delivery = delivery; self.sessionID = sessionID }
}

public struct InterruptResult: Codable, Hashable, Sendable {
    public struct Method: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Hosted: Esc sent.
        public static let escape = Self(rawValue: "escape")
        /// Stop mail left.
        public static let stop = Self(rawValue: "stop")
        /// Codex's app server interrupted the turn (`replyTerminal` sessions).
        public static let turnInterrupt = Self(rawValue: "turnInterrupt")
    }
    public let method: Method
    public init(method: Method) { self.method = method }
}

public struct Upload: Codable, Hashable, Sendable {
    public let id: String
    /// Where it is on the Mac, for the prompt.
    public let path: String
    public let mime: String
    public let bytes: Int
    public init(id: String, path: String, mime: String, bytes: Int) { self.id = id; self.path = path; self.mime = mime; self.bytes = bytes }
}
