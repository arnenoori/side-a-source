import Foundation

/// The bridge's `sessions show --format remote` and `sessions message` answers, turned into the wire's transcript
/// types. The bridge sends snake_case, raw tool input and its own todo shape; the phone gets protocol's camelCase,
/// the island's parse of each tool (strings cut at 64 KiB) and protocol's todo statuses.
public enum RemoteTranscript {
    public struct Failure: Error, Sendable, Equatable {
        public let message: String
        /// The session's transcript is gone, or was never there.
        public var missing: Bool { message.contains("transcript is gone") || message.contains("Unknown subagent") }
        public var badCursor: Bool { message == "Bad cursor" || message == "Use one cursor" }
    }

    /// A whole `{"id", "result"|"error"}` reply line from the bridge.
    public static func page(_ reply: Data) throws -> TranscriptPage {
        let page = try open(reply, as: Page.self)
        return TranscriptPage(sessionID: page.sessionID, generation: page.generation, messages: page.messages.map(\.wire),
                              replaced: page.replaced.map(\.wire), before: page.before.map(Cursor.init), after: Cursor(page.after),
                              hasMoreAfter: page.hasMoreAfter, count: page.count, inheritedBefore: page.inheritedBefore, reset: page.reset,
                              agentID: page.agentID)
    }

    /// nil when the generation moved on or the row's lines changed (`{"error": "changed"}`).
    public static func message(_ reply: Data) throws -> TranscriptMessage? {
        if (try? open(reply, as: Changed.self))?.error == "changed" { return nil }
        return try open(reply, as: Message.self).wire
    }

    /// The bridge's `sessions turn-diff` answer, for the session the phone knows by `key`.
    public static func turnDiff(_ reply: Data, key: SessionKey) throws -> TurnDiff {
        let turn = try open(reply, as: Turn.self)
        return TurnDiff(sessionID: key, turnID: turn.turnID, files: turn.files, running: turn.running, note: turn.note)
    }

    private struct Turn: Decodable {
        let turnID: String
        let files: [FileDiff]
        let running: Bool
        /// What the bridge can't see: shell changes, for Claude.
        let note: String?
    }

    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: String?
    }

    private struct Changed: Decodable { let error: String? }

    private static func open<T: Decodable>(_ reply: Data, as type: T.Type) throws -> T {
        let envelope = try decoder.decode(Envelope<T>.self, from: reply)
        if let error = envelope.error { throw Failure(message: error) }
        guard let result = envelope.result else { throw Failure(message: "The bridge didn't answer.") }
        return result
    }

    /// snake_case to protocol's names, where `id` and `ms` are capitals (`agent_id` is `agentID`, `duration_ms` is
    /// `durationMS`). Tool input keeps its own keys, which the island's parse reads as Claude Code wrote them.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let last = path.last!.stringValue
            if path.dropLast().contains(where: { $0.stringValue == "input" }) { return Key(last) }
            let parts = last.split(separator: "_").map(String.init)
            guard parts.count > 1 else { return Key(last) }
            return Key(parts[0] + parts.dropFirst().map { ["id", "ms"].contains($0) ? $0.uppercased() : $0.prefix(1).uppercased() + $0.dropFirst() }.joined())
        }
        return decoder
    }()

    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    // MARK: The bridge's shapes

    private struct Page: Decodable {
        let sessionID: String
        let agentID: String?
        let generation: String
        let messages: [Message]
        let replaced: [Message]
        let before: String?
        let after: String
        let hasMoreAfter: Bool
        let count: Int
        let inheritedBefore: Int
        let reset: Bool
    }

    private struct Message: Decodable {
        let seq: Int
        let role: String
        let uuid: String?
        let ts: Double?
        let model: String?
        let inherited: Bool?
        let text: String?
        let textTruncated: Bool?
        let images: [Image]?
        let tools: [Tool]?
        let durationMS: Int?

        var wire: TranscriptMessage {
            TranscriptMessage(seq: seq, uuid: uuid ?? "", role: TranscriptRole(rawValue: role), at: ts, model: model, inherited: inherited ?? false,
                              text: text, textTruncated: textTruncated ?? false, tools: (tools ?? []).map { $0.wire(seq: seq) },
                              images: (images ?? []).map { $0.wire(seq: seq) }, durationMS: durationMS)
        }
    }

    private struct Image: Decodable {
        let id: String
        let mime: String
        let bytes: Int
        let width: Int?
        let height: Int?
        let source: String?
        let name: String?

        func wire(seq: Int) -> ImageRef {
            ImageRef(id: id, mime: mime, bytes: bytes, width: width, height: height, source: ImageRef.Source(rawValue: source ?? "other"), name: name, seq: seq)
        }
    }

    private struct Todo: Decodable {
        let content: String?
        let status: String?
        let activeForm: String?

        var wire: TranscriptTodo {
            let status: TranscriptTodo.Status = switch self.status {
            case "in_progress"?, "inProgress"?: .inProgress
            case "completed"?: .completed
            default: .pending
            }
            return TranscriptTodo(text: content ?? "", status: status, activeForm: activeForm)
        }
    }

    private struct Tool: Decodable {
        let id: String
        let name: String
        let summary: String?
        let input: JSON?
        let status: String?
        let startedAt: Double?
        let endedAt: Double?
        let output: String?
        let outputTruncated: Bool?
        let diffs: [FileDiff]?
        let images: [Image]?
        let subagent: String?
        let agentID: String?
        let todos: [Todo]?
        let plan: String?
        let group: Bool?
        let parent: String?

        func wire(seq: Int) -> TranscriptTool {
            let action = (input?.value as? [String: Any]).map { RemoteTranscript.cut(IslandRequest.action(name, $0, mcp: nil)) }
            return TranscriptTool(id: id, name: name, summary: String((summary ?? name).prefix(400)), action: action,
                                  status: TranscriptTool.Status(rawValue: status ?? "running"), startedAt: startedAt, endedAt: endedAt,
                                  output: output, outputTruncated: outputTruncated ?? false, diffs: diffs ?? [],
                                  images: (images ?? []).map { $0.wire(seq: seq) }, subagent: subagent, agentID: agentID,
                                  todos: todos?.map(\.wire), plan: plan, group: group ?? false, parent: parent)
        }
    }

    /// Any JSON value, as JSONSerialization would give it.
    struct JSON: Decodable {
        let value: Any
        init(from decoder: Decoder) throws {
            if var list = try? decoder.unkeyedContainer() {
                var values: [Any] = []
                while !list.isAtEnd { values.append(try list.decode(JSON.self).value) }
                value = values
            } else if let object = try? decoder.container(keyedBy: Key.self) {
                var values: [String: Any] = [:]
                for key in object.allKeys { values[key.stringValue] = try object.decode(JSON.self, forKey: key).value }
                value = values
            } else {
                let single = try decoder.singleValueContainer()
                if single.decodeNil() { value = NSNull() }
                else if let bool = try? single.decode(Bool.self) { value = bool }
                else if let number = try? single.decode(Double.self) { value = number }
                else { value = try single.decode(String.self) }
            }
        }
    }

    // MARK: Cuts

    /// Any one string in a list or event is cut here; the uncut value is a separate fetch.
    public static let maxString = 64 << 10

    /// The action with each long string cut, and whether anything was.
    public static func cutting(_ action: IslandAction) -> (IslandAction, Bool) {
        var truncated = false
        func c(_ text: String) -> String {
            guard text.utf8.count > maxString else { return text }
            truncated = true
            return String(decoding: Data(text.utf8.prefix(maxString)), as: UTF8.self)
        }
        let out: IslandAction
        switch action {
        case .command(let command): out = .command(c(command))
        case .edit(let path, let removed, let added): out = .edit(path: path, removed: c(removed), added: c(added))
        case .write(let path, let content): out = .write(path: path, content: c(content))
        case .patch(let files, let text): out = .patch(files: files, text: c(text))
        case .read, .fetch, .search, .question: out = action
        case .mcp(let server, let tool, let arguments): out = .mcp(server: server, tool: tool, arguments: c(arguments))
        case .plan(let plan): out = .plan(c(plan))
        case .other(let tool, let arguments): out = .other(tool: tool, arguments: c(arguments))
        }
        return (out, truncated)
    }

    static func cut(_ action: IslandAction) -> IslandAction { cutting(action).0 }
}
