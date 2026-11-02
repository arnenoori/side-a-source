import Foundation

public struct TranscriptRole: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let user = Self(rawValue: "user")
    public static let assistant = Self(rawValue: "assistant")
    public static let tools = Self(rawValue: "tools")
    public static let compact = Self(rawValue: "compact")
    public static let error = Self(rawValue: "error")
    /// Claude's thinking or a Codex reasoning summary; `text` may be empty when it was redacted.
    public static let thinking = Self(rawValue: "thinking")
}

public struct TranscriptMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { seq }
    /// Position in this generation, 0-based, dense.
    public let seq: Int
    /// The transcript entry's uuid. Not unique: one entry can yield several messages.
    public let uuid: String
    public let role: TranscriptRole
    public let at: Timestamp?
    public let model: String?
    /// Copied from the parent of a fork.
    public let inherited: Bool
    /// Markdown; nil for `.tools`.
    public let text: String?
    /// Cut at 6,000 characters; `GET …/messages/{seq}` has it whole.
    public let textTruncated: Bool
    /// Empty unless the role is `.tools`.
    public let tools: [TranscriptTool]
    /// Pasted images on a user message.
    public let images: [ImageRef]
    /// How long a `.thinking` message took, for "Thought for 4s".
    public let durationMS: Int?

    public init(seq: Int, uuid: String, role: TranscriptRole, at: Timestamp? = nil, model: String? = nil, inherited: Bool = false,
                text: String? = nil, textTruncated: Bool = false, tools: [TranscriptTool] = [], images: [ImageRef] = [], durationMS: Int? = nil) {
        self.seq = seq; self.uuid = uuid; self.role = role; self.at = at; self.model = model; self.inherited = inherited
        self.text = text; self.textTruncated = textTruncated; self.tools = tools; self.images = images; self.durationMS = durationMS
    }
}

/// One item of a todo list written by `TodoWrite`, `TaskCreate`/`TaskUpdate` or Codex `update_plan`.
public struct TranscriptTodo: Codable, Hashable, Sendable {
    public struct Status: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let pending = Self(rawValue: "pending")
        public static let inProgress = Self(rawValue: "inProgress")
        public static let completed = Self(rawValue: "completed")
    }
    /// `content` (Claude) or `step` (Codex).
    public let text: String
    public let status: Status
    /// Claude's present-tense line for the item in progress.
    public let activeForm: String?
    public init(text: String, status: Status, activeForm: String? = nil) { self.text = text; self.status = status; self.activeForm = activeForm }
}

public struct TranscriptTool: Codable, Hashable, Sendable, Identifiable {
    public struct Status: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let running = Self(rawValue: "running")
        public static let ok = Self(rawValue: "ok")
        public static let failed = Self(rawValue: "failed")
        public static let denied = Self(rawValue: "denied")
    }
    /// `tool_use` id (Claude) or `call_id` (Codex).
    public let id: String
    /// "Bash", "Edit", "mcp__github__create_issue", "exec_command".
    public let name: String
    /// One line, at most 400 characters.
    public let summary: String
    /// The same parse the island uses, strings cut at 64 KiB.
    public let action: IslandAction?
    public var status: Status
    public let startedAt: Timestamp?
    public var endedAt: Timestamp?
    /// The result text, cut at 4,000 characters.
    public var output: String?
    public var outputTruncated: Bool
    /// Edit/Write structuredPatch, Codex FileChange.
    public var diffs: [FileDiff]
    /// Read results, MCP and browser screenshots, Codex screenshots.
    public var images: [ImageRef]
    /// Task/Agent tool: the subagent's description.
    public let subagent: String?
    /// The subagent's id once its result names it; pages its own transcript.
    public var agentID: String?
    /// The list a todo tool wrote; nil for every other tool.
    public var todos: [TranscriptTodo]?
    /// `ExitPlanMode`'s plan.
    public let plan: String?
    /// Codex `exec` that ran several commands: the phone folds the ones after it.
    public let group: Bool
    /// On a Codex child command: the id of the `exec` it ran under.
    public let parent: String?

    public init(id: String, name: String, summary: String, action: IslandAction? = nil, status: Status, startedAt: Timestamp? = nil,
                endedAt: Timestamp? = nil, output: String? = nil, outputTruncated: Bool = false, diffs: [FileDiff] = [],
                images: [ImageRef] = [], subagent: String? = nil, agentID: String? = nil, todos: [TranscriptTodo]? = nil,
                plan: String? = nil, group: Bool = false, parent: String? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.action = action; self.status = status
        self.startedAt = startedAt; self.endedAt = endedAt; self.output = output; self.outputTruncated = outputTruncated
        self.diffs = diffs; self.images = images; self.subagent = subagent; self.agentID = agentID; self.todos = todos
        self.plan = plan; self.group = group; self.parent = parent
    }
}

public struct ImageRef: Codable, Hashable, Sendable, Identifiable {
    public struct Source: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let read = Self(rawValue: "read")
        public static let mcp = Self(rawValue: "mcp")
        public static let pasted = Self(rawValue: "pasted")
        /// Codex tool output.
        public static let screenshot = Self(rawValue: "screenshot")
        /// Codex `ImageView` / `local_image`.
        public static let view = Self(rawValue: "view")
        public static let other = Self(rawValue: "other")
    }
    /// Lowercase hex SHA-1 of the bytes; also the ETag.
    public let id: String
    public let mime: String
    public let bytes: Int
    public let width: Int?
    public let height: Int?
    public let source: Source
    /// The file name when it came from one.
    public let name: String?
    /// The transcript message it sits in.
    public let seq: Int?
    public init(id: String, mime: String, bytes: Int, width: Int? = nil, height: Int? = nil, source: Source, name: String? = nil, seq: Int? = nil) {
        self.id = id; self.mime = mime; self.bytes = bytes; self.width = width; self.height = height; self.source = source; self.name = name
        self.seq = seq
    }
}

public struct FileDiff: Codable, Hashable, Sendable {
    public struct Change: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let modified = Self(rawValue: "modified")
        public static let added = Self(rawValue: "added")
        public static let deleted = Self(rawValue: "deleted")
        public static let renamed = Self(rawValue: "renamed")
    }
    public let path: String
    public let oldPath: String?
    public let change: Change
    public let additions: Int
    public let deletions: Int
    public let hunks: [DiffHunk]
    /// More than 2,000 lines; the rest is left out.
    public let truncated: Bool
    public init(path: String, oldPath: String? = nil, change: Change, additions: Int, deletions: Int, hunks: [DiffHunk], truncated: Bool = false) {
        self.path = path; self.oldPath = oldPath; self.change = change; self.additions = additions; self.deletions = deletions
        self.hunks = hunks; self.truncated = truncated
    }
}

public struct DiffHunk: Codable, Hashable, Sendable {
    public let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
    /// Each starts with " ", "+", "-" or "\".
    public let lines: [String]
    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [String]) {
        self.oldStart = oldStart; self.oldCount = oldCount; self.newStart = newStart; self.newCount = newCount; self.lines = lines
    }
}

public struct TranscriptPage: Codable, Hashable, Sendable {
    public let sessionID: SessionKey
    /// Changes when the Mac rebuilds this transcript's view.
    public let generation: String
    /// Ascending seq.
    public let messages: [TranscriptMessage]
    /// Rows at or below the `after` cursor's seq that changed since that cursor (a result landed on a
    /// row the client already had). Only on `after` pages; ascending seq.
    public let replaced: [TranscriptMessage]
    /// Nil at the start of the conversation.
    public let before: Cursor?
    /// Continue forward from the last message (or from `before` if empty).
    public let after: Cursor
    public let hasMoreAfter: Bool
    /// Messages in this generation.
    public let count: Int
    /// Inherited messages before the page (fork display).
    public let inheritedBefore: Int
    /// The cursor sent was from another generation, so this is the newest page instead.
    public let reset: Bool
    /// Set when the page is a subagent's own transcript.
    public let agentID: String?

    public init(sessionID: SessionKey, generation: String, messages: [TranscriptMessage], replaced: [TranscriptMessage] = [],
                before: Cursor?, after: Cursor, hasMoreAfter: Bool = false, count: Int, inheritedBefore: Int = 0, reset: Bool = false,
                agentID: String? = nil) {
        self.sessionID = sessionID; self.generation = generation; self.messages = messages; self.replaced = replaced
        self.before = before; self.after = after; self.hasMoreAfter = hasMoreAfter; self.count = count
        self.inheritedBefore = inheritedBefore; self.reset = reset; self.agentID = agentID
    }
}
