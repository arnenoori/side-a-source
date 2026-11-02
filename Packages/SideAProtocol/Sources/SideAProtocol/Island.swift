import Foundation

/// A destructive request never takes a keyboard shortcut or an "Always", so it can't be approved by reflex.
public enum IslandRisk: Int, Sendable, Comparable, Codable {
    case low, normal, destructive
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var name: String { ["low", "normal", "destructive"][rawValue] }
    // A value the client does not understand must never make a request easier to approve.
    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        self = name == "low" ? .low : name == "normal" ? .normal : .destructive
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(name) }
}

public struct IslandQuestion: Sendable, Equatable, Hashable, Codable {
    public struct Option: Sendable, Equatable, Hashable, Codable {
        public let label: String
        public let description: String?
        public init(label: String, description: String?) { self.label = label; self.description = description }
        /// Claude marks the answer it recommends with "(Recommended)" in the label; the tool has no field for it.
        public var recommended: Bool { label.range(of: Self.marker, options: [.regularExpression, .caseInsensitive]) != nil }
        /// The label without the marker, for display; answers send `label` unchanged.
        public var title: String {
            let bare = label.replacingOccurrences(of: Self.marker, with: "", options: [.regularExpression, .caseInsensitive])
            return bare.isEmpty ? label : bare
        }
        private static let marker = #"\s*[(\[]\s*recommended\s*[)\]]\s*"#
    }
    public let question: String
    public let header: String?
    public let options: [Option]
    public let multiSelect: Bool
    public init(question: String, header: String?, options: [Option], multiSelect: Bool) {
        self.question = question; self.header = header; self.options = options; self.multiSelect = multiSelect
    }

    /// Picked labels then typed text, joined with ", ": what goes back to Claude Code.
    public func answerText(picked: [String], other: String?) -> String {
        let typed = (other ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (picked + (typed.isEmpty ? [] : [typed])).joined(separator: ", ")
    }
}

public enum IslandAction: Sendable, Equatable, Hashable {
    case command(String)
    case edit(path: String, removed: String, added: String)
    case write(path: String, content: String)
    case patch(files: [String], text: String)
    case read(path: String)
    case fetch(String)
    case search(String)
    case mcp(server: String, tool: String, arguments: String)
    case question([IslandQuestion])
    case plan(String)
    case other(tool: String, arguments: String)

    public var headline: String {
        switch self {
        case .command: "Run a command"
        case .edit(let path, _, _): "Edit \(Self.file(path))"
        case .write(let path, _): "Write \(Self.file(path))"
        case .patch(let files, _): files.count == 1 ? "Edit \(Self.file(files[0]))" : "Edit \(files.count) files"
        case .read(let path): "Read \(Self.file(path))"
        case .fetch(let url): "Fetch \(URL(string: url)?.host ?? url)"
        case .search: "Search"
        case .mcp(let server, let tool, _): "Use \(tool) from \(server)"
        case .question(let questions): questions.count == 1 ? questions[0].question : "\(questions.count) questions for you"
        case .plan: "Review the plan"
        case .other(let tool, _): "Use \(tool)"
        }
    }

    public var detail: String {
        switch self {
        case .command(let command): command
        case .edit(let path, _, _), .write(let path, _), .read(let path): path
        case .patch(let files, let text): files.isEmpty ? text : files.joined(separator: "\n")
        case .fetch(let value), .search(let value): value
        case .mcp(_, _, let arguments), .other(_, let arguments): arguments
        case .question(let questions): questions.flatMap { $0.options.map(\.label) }.joined(separator: ", ")
        case .plan(let plan): plan
        }
    }

    public static func file(_ path: String) -> String { path.isEmpty ? "a file" : URL(fileURLWithPath: path).lastPathComponent }
}

// Tagged by `kind`. Every kind added later also carries `tool` and `arguments`, so an old decoder
// shows it as `.other` and no new case is ever needed on an old phone.
extension IslandAction: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let kind = try c.value("kind", as: String.self)
        switch kind {
        case "command": self = .command(try c.value("command"))
        case "edit": self = .edit(path: try c.value("path"), removed: try c.value("removed"), added: try c.value("added"))
        case "write": self = .write(path: try c.value("path"), content: try c.value("content"))
        case "patch": self = .patch(files: try c.value("files"), text: try c.value("text"))
        case "read": self = .read(path: try c.value("path"))
        case "fetch": self = .fetch(try c.value("url"))
        case "search": self = .search(try c.value("query"))
        case "mcp": self = .mcp(server: try c.value("server"), tool: try c.value("tool"), arguments: try c.value("arguments"))
        case "question": self = .question(try c.value("questions"))
        case "plan": self = .plan(try c.value("plan"))
        default: self = .other(tool: try c.optional("tool") ?? kind, arguments: try c.optional("arguments") ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case .command(let command): try c.put("command", "kind"); try c.put(command, "command")
        case .edit(let path, let removed, let added):
            try c.put("edit", "kind"); try c.put(path, "path"); try c.put(removed, "removed"); try c.put(added, "added")
        case .write(let path, let content): try c.put("write", "kind"); try c.put(path, "path"); try c.put(content, "content")
        case .patch(let files, let text): try c.put("patch", "kind"); try c.put(files, "files"); try c.put(text, "text")
        case .read(let path): try c.put("read", "kind"); try c.put(path, "path")
        case .fetch(let url): try c.put("fetch", "kind"); try c.put(url, "url")
        case .search(let query): try c.put("search", "kind"); try c.put(query, "query")
        case .mcp(let server, let tool, let arguments):
            try c.put("mcp", "kind"); try c.put(server, "server"); try c.put(tool, "tool"); try c.put(arguments, "arguments")
        case .question(let questions): try c.put("question", "kind"); try c.put(questions, "questions")
        case .plan(let plan): try c.put("plan", "kind"); try c.put(plan, "plan")
        case .other(let tool, let arguments): try c.put("other", "kind"); try c.put(tool, "tool"); try c.put(arguments, "arguments")
        }
    }
}
