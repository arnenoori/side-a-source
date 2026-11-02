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
    public init(text: String, mode: ReplyMode = .auto, keys: [Key]? = nil, attachments: [String] = [], turnID: String? = nil,
                submit: ReplySubmit? = nil) {
        self.text = text; self.mode = mode; self.keys = keys; self.attachments = attachments; self.turnID = turnID; self.submit = submit
    }
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
