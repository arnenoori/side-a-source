import Foundation
import SideAProtocol

/// The wire of Codex's shared app-server daemon, which the 0.163 TUI runs on by default: JSON-RPC without the
/// `"jsonrpc"` field, as WebSocket text frames over `$CODEX_HOME/app-server-control/app-server-control.sock`.
/// Everything here is pure; `AppServerClient` carries it and `CodexTerminals` decides with it.
public enum CodexAppServer {
    public static func socket(home: String) -> String {
        URL(fileURLWithPath: home).appendingPathComponent("app-server-control/app-server-control.sock").path
    }

    /// A JSON value that crosses actors.
    public indirect enum JSON: Sendable, Equatable, Codable {
        case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
            else if let number = try? value.decode(Double.self) { self = .number(number) }
            else if let string = try? value.decode(String.self) { self = .string(string) }
            else if let array = try? value.decode([JSON].self) { self = .array(array) }
            else { self = .object(try value.decode([String: JSON].self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .null: try value.encodeNil()
            case .bool(let bool): try value.encode(bool)
            case .number(let number):
                // Ids and counts go back as integers: the daemon reads request ids as numbers, never 0.0.
                if number.rounded() == number, abs(number) < 1e15 { try value.encode(Int(number)) } else { try value.encode(number) }
            case .string(let string): try value.encode(string)
            case .array(let array): try value.encode(array)
            case .object(let object): try value.encode(object)
            }
        }

        public subscript(key: String) -> JSON? { if case .object(let object) = self { object[key] } else { nil } }
        public var string: String? { if case .string(let string) = self { string } else { nil } }
        public var int: Int? { if case .number(let number) = self { Int(exactly: number.rounded()) } else { nil } }
        public var bool: Bool? { if case .bool(let bool) = self { bool } else { nil } }
        public var array: [JSON]? { if case .array(let array) = self { array } else { nil } }
    }

    public struct RPCError: Error, Sendable, Equatable {
        public let code: Int
        public let message: String
        public init(code: Int, message: String) { self.code = code; self.message = message }

        /// An older daemon, or one built without the experimental API. 0.163 answers a method it doesn't know with
        /// -32600 "unknown variant `…`" rather than the -32601 the spec names, so both count.
        public var unknownMethod: Bool { code == -32601 || code == -32600 && message.contains("unknown variant") }
    }

    public enum Message: Sendable, Equatable {
        case response(id: Int, result: Result<JSON, RPCError>)
        /// A request from the daemon, such as an approval; answered by echoing `id`, whatever its type.
        case request(id: JSON, method: String, params: JSON)
        case notification(method: String, params: JSON)
    }

    public static func parse(_ data: Data) -> Message? {
        guard let json = try? JSONDecoder().decode(JSON.self, from: data), case .object(let object) = json else { return nil }
        let params = object["params"] ?? .null
        if let method = object["method"]?.string {
            if let id = object["id"] { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        guard let id = object["id"]?.int else { return nil }
        if let error = object["error"] {
            return .response(id: id, result: .failure(RPCError(code: error["code"]?.int ?? 0, message: error["message"]?.string ?? "")))
        }
        return .response(id: id, result: .success(object["result"] ?? .null))
    }

    public static func request(id: Int, method: String, params: JSON?) -> Data {
        var object: [String: JSON] = ["id": .number(Double(id)), "method": .string(method)]
        if let params { object["params"] = params }
        return encode(.object(object))
    }

    public static func notification(method: String) -> Data { encode(.object(["method": .string(method)])) }

    public static func response(id: JSON, result: JSON) -> Data { encode(.object(["id": id, "result": result])) }

    static func encode(_ json: JSON) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(json)) ?? Data("{}".utf8)
    }

    public static func initialize(version: String) -> JSON {
        .object(["clientInfo": .object(["name": .string("side-a"), "title": .string("Side A"), "version": .string(version)]),
                 "capabilities": .object(["experimentalApi": .bool(true)])])
    }

    /// `UserInput` for `turn/start`, `turn/steer` and `thread/queue/add`: one text element.
    public static func input(_ text: String) -> JSON {
        .array([.object(["type": .string("text"), "text": .string(text), "text_elements": .array([])])])
    }

    /// One thread as the daemon describes it (`thread/read`, `thread/started`), with what Side A keeps of it.
    public struct Thread: Sendable, Equatable {
        public enum Status: Sendable, Equatable {
            case notLoaded, idle, systemError
            case active(waitingOnApproval: Bool, waitingOnUserInput: Bool)
        }
        public let id: String
        public var status: Status
        public let cwd: String?
        /// The rollout file, which is how Side A's own session list names a Codex session too.
        public let path: String?
        public let ephemeral: Bool
        /// Subagents and helper threads (the title generator) have a parent or a non-user source; only a user's own
        /// thread is the terminal session.
        public let parent: String?
        public let source: String?

        public init?(_ json: JSON) {
            guard let id = json["id"]?.string else { return nil }
            self.id = id
            status = Self.status(json["status"])
            cwd = json["cwd"]?.string
            path = json["path"]?.string
            ephemeral = json["ephemeral"]?.bool ?? false
            parent = json["parentThreadId"]?.string
            source = json["threadSource"]?.string
        }

        public var isUsers: Bool { !ephemeral && parent == nil && (source == nil || source == "user") }

        public static func status(_ json: JSON?) -> Status {
            switch json?["type"]?.string {
            case "idle": return .idle
            case "systemError": return .systemError
            case "active":
                let flags = json?["activeFlags"]?.array?.compactMap(\.string) ?? []
                return .active(waitingOnApproval: flags.contains("waitingOnApproval"), waitingOnUserInput: flags.contains("waitingOnUserInput"))
            default: return .notLoaded
            }
        }
    }

    /// An approval the daemon asks every client for. Side A answers the ones its island can show; the rest stay with
    /// the terminal.
    public struct Approval: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case command, fileChange }
        public let id: JSON
        public let kind: Kind
        public let threadID: String
        public let turnID: String?
        public let itemID: String?
        public let command: String?
        public let cwd: String?
        public let reason: String?

        public init?(id: JSON, method: String, params: JSON) {
            switch method {
            case "item/commandExecution/requestApproval": kind = .command
            case "item/fileChange/requestApproval": kind = .fileChange
            default: return nil
            }
            guard let thread = params["threadId"]?.string else { return nil }
            self.id = id
            threadID = thread
            turnID = params["turnId"]?.string
            itemID = params["itemId"]?.string
            // The command as the model wrote it, not the shell wrapper the daemon shows (`/bin/zsh -lc '…'`).
            command = params["commandActions"]?.array?.compactMap { $0["command"]?.string }.first ?? params["command"]?.string
            cwd = params["cwd"]?.string
            reason = params["reason"]?.string
        }

        /// What the island shows. File changes name their files when the item that proposed them was seen.
        public func request(files: [String], diff: String) -> IslandRequest {
            let action: IslandAction = switch kind {
            case .command: .command(command ?? "")
            case .fileChange: .patch(files: files, text: diff)
            }
            return IslandRequest(agent: .codex, sessionID: threadID, cwd: cwd, tool: kind == .command ? "exec_command" : "apply_patch",
                                 action: action, reason: reason)
        }

        /// The decision for an island answer; nil hands it back to the terminal, which is still asking.
        public static func decision(_ answer: IslandAnswer) -> JSON? {
            switch answer {
            // Codex takes no mode from Side A, so an allow that names one is a plain allow here; none is offered for Codex.
            case .allow, .allowMode, .approvePlan, .answers: .object(["decision": .string("accept")])
            case .always: .object(["decision": .string("acceptForSession")])
            case .deny: .object(["decision": .string("decline")])
            case .terminal: nil
            }
        }
    }

    /// RFC 6455, client side, as the daemon's tungstenite wants it. Network.framework's WebSocket aborts on a Unix
    /// endpoint before sending a byte (ECONNABORTED, checked on macOS 27), so the upgrade and frames are done here.
    public enum Frames {
        public static func upgrade(key: String) -> Data {
            Data(("GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8)
        }

        /// The bytes after the daemon's 101, or nil while the head is incomplete; throws when it refused.
        public static func accepted(_ head: Data, key: String) throws -> Data? {
            guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
                if head.count > 16 << 10 { throw AppServerClient.Failure.refused }
                return nil
            }
            let lines = String(decoding: head[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let status = lines.first?.split(separator: " ").dropFirst().first
            let accept = lines.dropFirst().first { $0.lowercased().hasPrefix("sec-websocket-accept:") }
                .map { $0.dropFirst("sec-websocket-accept:".count).trimmingCharacters(in: .whitespaces) }
            guard status == "101", accept == WebSocketCodec.acceptKey(key) else { throw AppServerClient.Failure.refused }
            return head[end.upperBound...]
        }

        /// Client frames are masked; the daemon takes one unfragmented text frame per message.
        public static func frame(_ opcode: WebSocketCodec.Opcode, _ payload: Data, mask: [UInt8]) -> Data {
            var out = Data([0x80 | opcode.rawValue])
            switch payload.count {
            case ..<126: out.append(0x80 | UInt8(payload.count))
            case ..<65536: out.append(0x80 | 126); out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF))
            default:
                out.append(0x80 | 127)
                for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
            }
            out.append(contentsOf: mask)
            out.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset & 3] })
            return out
        }

        /// A push parser for the daemon's frames: unmasked, data frames reassembled from continuations.
        public struct Parser: Sendable {
            private var bytes = Data()
            private var partial: (opcode: WebSocketCodec.Opcode, data: Data)?
            private let maxMessage = 64 << 20
            public init() {}

            public mutating func feed(_ data: Data) throws -> [(WebSocketCodec.Opcode, Data)] {
                bytes.append(data)
                var out: [(WebSocketCodec.Opcode, Data)] = []
                while let frame = try next() { out.append(frame) }
                return out
            }

            private mutating func next() throws -> (WebSocketCodec.Opcode, Data)? {
                let view = [UInt8](bytes.prefix(14))
                guard view.count >= 2 else { return nil }
                let fin = view[0] & 0x80 != 0
                guard let opcode = WebSocketCodec.Opcode(rawValue: view[0] & 0x0F) else { throw AppServerClient.Failure.refused }
                let masked = view[1] & 0x80 != 0
                var length = Int(view[1] & 0x7F)
                var offset = 2
                if length == 126 {
                    guard view.count >= 4 else { return nil }
                    length = Int(view[2]) << 8 | Int(view[3]); offset = 4
                } else if length == 127 {
                    guard view.count >= 10 else { return nil }
                    length = view[2..<10].reduce(0) { $0 << 8 | Int($1) }; offset = 10
                }
                guard length <= maxMessage else { throw AppServerClient.Failure.refused }
                let maskAt = offset
                if masked { offset += 4 }
                guard bytes.count >= offset + length else { return nil }
                let start = bytes.startIndex
                var payload = Data(bytes[(start + offset)..<(start + offset + length)])
                if masked {
                    let mask = [UInt8](bytes[(start + maskAt)..<(start + maskAt + 4)])
                    for i in payload.indices { payload[i] ^= mask[(i - payload.startIndex) & 3] }
                }
                bytes = Data(bytes[(start + offset + length)...])
                switch opcode {
                case .ping, .pong, .close: return (opcode, payload)
                case .continuation:
                    guard var message = partial else { throw AppServerClient.Failure.refused }
                    message.data.append(payload)
                    guard message.data.count <= maxMessage else { throw AppServerClient.Failure.refused }
                    if fin { partial = nil; return (message.opcode, message.data) }
                    partial = message
                    return try next()
                case .text, .binary:
                    if fin { return (opcode, payload) }
                    partial = (opcode, payload)
                    return try next()
                }
            }
        }
    }

    /// A thread's model, reasoning effort and collaboration mode ("default" or "plan"), as `thread/resume` returns them
    /// and `thread/settings/updated` changes them. They apply to the thread's next turns.
    public struct Settings: Sendable, Equatable {
        public var model: String
        public var effort: String?
        /// The collaboration mode, "default" or "plan".
        public var mode: String
        /// `approvalPolicy` and `sandboxPolicy` as the daemon gave them.
        public var approval: JSON?
        public var sandbox: JSON?
        public init(model: String, effort: String?, mode: String, approval: JSON? = nil, sandbox: JSON? = nil) {
            self.model = model; self.effort = effort; self.mode = mode; self.approval = approval; self.sandbox = sandbox
        }

        /// From `thread/resume`'s result.
        public init?(resumed json: JSON) {
            guard let model = json["model"]?.string else { return nil }
            self.init(model: model, effort: json["reasoningEffort"]?.string, mode: json["collaborationMode"]?["mode"]?.string ?? "default",
                      approval: json["approvalPolicy"], sandbox: json["sandbox"])
        }

        /// From `thread/settings/updated`'s `threadSettings`.
        public init?(updated json: JSON) {
            guard let model = json["model"]?.string else { return nil }
            self.init(model: model, effort: json["effort"]?.string, mode: json["collaborationMode"]?["mode"]?.string ?? "default",
                      approval: json["approvalPolicy"], sandbox: json["sandboxPolicy"])
        }

        /// Full access (no sandbox) or no approvals: a raise from the phone, which needs Face ID.
        public var fullAccess: Bool { sandbox?["type"]?.string == "dangerFullAccess" }
        public var neverAsks: Bool { approval?.string == "never" }
        public var raised: Bool { fullAccess || neverAsks }

        /// One mode for the row: plan, then the raises, then default.
        public var shown: String { mode == "plan" ? "plan" : fullAccess ? Self.fullAccessMode : neverAsks ? Self.neverMode : mode }
        public static let neverMode = "never", fullAccessMode = "dangerFullAccess"

        /// `thread/settings/update` for a raise, or for lowering one back to `base`, what the session ran with before.
        public func raise(thread: String, to mode: String) -> JSON {
            var params: [String: JSON] = ["threadId": .string(thread)]
            if mode == Self.neverMode { params["approvalPolicy"] = .string("never") }
            if mode == Self.fullAccessMode { params["sandboxPolicy"] = .object(["type": .string("dangerFullAccess")]) }
            return .object(params)
        }

        public static func lower(thread: String, to base: Settings) -> JSON {
            var params: [String: JSON] = ["threadId": .string(thread)]
            if let approval = base.approval { params["approvalPolicy"] = approval }
            if let sandbox = base.sandbox { params["sandboxPolicy"] = sandbox }
            return .object(params)
        }

        /// `thread/settings/update` for what changes. A mode carries the model and effort it runs with, and the daemon
        /// takes the effort from it (null would clear it), so it goes with the effort the thread keeps. Null
        /// instructions give the mode Codex's own.
        public func update(thread: String, model: String?, effort: String?, mode: String?) -> JSON {
            var params: [String: JSON] = ["threadId": .string(thread)]
            if let model { params["model"] = .string(model) }
            if let effort { params["effort"] = .string(effort) }
            if let mode {
                let effort = effort ?? self.effort
                params["collaborationMode"] = .object(["mode": .string(mode), "settings": .object([
                    "model": .string(model ?? self.model), "reasoning_effort": effort.map(JSON.string) ?? .null, "developer_instructions": .null])])
            }
            return .object(params)
        }
    }

    public static let modes = ["default", "plan"]

    /// One of the daemon's models (`model/list`), for its account.
    public struct Model: Sendable, Equatable {
        public let id: String
        public let name: String
        public let efforts: [String]
        public let defaultEffort: String?
        public let isDefault: Bool

        public init?(_ json: JSON) {
            guard let id = json["id"]?.string, json["hidden"]?.bool != true else { return nil }
            self.id = id
            name = json["displayName"]?.string ?? id
            efforts = json["supportedReasoningEfforts"]?.array?.compactMap { $0["reasoningEffort"]?.string } ?? []
            defaultEffort = json["defaultReasoningEffort"]?.string
            isDefault = json["isDefault"]?.bool ?? false
        }
    }

    /// How full the context window is, 0 to 100, as the TUI's footer counts it: the last request's tokens past the
    /// 12,000 every request carries, over the window past them.
    public static func contextPercent(_ tokenUsage: JSON) -> Int? {
        guard let window = tokenUsage["modelContextWindow"]?.int, let used = tokenUsage["last"]?["totalTokens"]?.int else { return nil }
        let baseline = 12_000
        guard window > baseline else { return 100 }
        let effective = Double(window - baseline)
        let remaining = max(effective - Double(max(used - baseline, 0)), 0)
        return 100 - Int((remaining / effective * 100).rounded())
    }

    /// The account's 5-hour and weekly windows from a `RateLimitSnapshot`, named as the bridge's usage reading names
    /// them. Only the main "codex" limit; an update is sparse, so a window it leaves out isn't there.
    public static func windows(_ snapshot: JSON) -> [UsageWindow] {
        if let id = snapshot["limitId"]?.string, id != "codex" { return [] }
        return ["primary", "secondary"].compactMap { key in
            guard let window = snapshot[key], let used = window["usedPercent"], case .number(let percent) = used else { return nil }
            let minutes = window["windowDurationMins"]?.int ?? 0
            let id = minutes == 300 ? "five_hour" : minutes == 10_080 ? "seven_day" : key
            let label = minutes == 300 ? "5-hour" : minutes == 10_080 ? "Weekly" : "\(minutes / 60)-hour"
            let resets: Double? = if case .number(let at)? = window["resetsAt"] { at > 1e11 ? at / 1000 : at } else { nil }
            return UsageWindow(id: id, label: label, percent: percent, resetsAt: resets)
        }
    }

    /// The thread's estimated cost in US dollars (`account/usage/read {threadId}`), when its billing route has one.
    public static func cost(_ usage: JSON) -> Double? {
        guard case .number(let micros)? = usage["threadUsage"]?["estimatedUsageUsdMicros"] else { return nil }
        return micros / 1_000_000
    }

    /// The files of a turn's diff (`turn/diff/updated`), which is git's: `diff --git a/… b/…`, mode and rename lines,
    /// `---`/`+++`, then hunks. Each file keeps its first 2,000 lines, counted before the cut as the bridge does.
    public static func fileDiffs(_ text: String) -> [FileDiff] {
        let cap = 2_000
        struct File { var path = "", oldPath: String?, change = FileDiff.Change.modified, hunks: [DiffHunk] = [], lines: [String] = [],
                      head: (Int, Int, Int, Int)?, added = 0, removed = 0, kept = 0, truncated = false }
        var files: [File] = []
        func close() {
            guard var file = files.popLast() else { return }
            if let head = file.head { file.hunks.append(DiffHunk(oldStart: head.0, oldCount: head.1, newStart: head.2, newCount: head.3, lines: file.lines)) }
            file.head = nil; file.lines = []
            files.append(file)
        }
        func path(_ text: Substring) -> String { text.hasPrefix("a/") || text.hasPrefix("b/") ? String(text.dropFirst(2)) : String(text) }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                close()
                var file = File()
                // "a/x b/x": the halves are the same length unless renamed, which the rename lines then say.
                let names = line.dropFirst("diff --git ".count)
                if let split = names.range(of: " b/") { file.path = path(names[split.upperBound...]); file.oldPath = nil }
                files.append(file)
                continue
            }
            guard var file = files.popLast() else { continue }
            defer { files.append(file) }
            if file.head == nil {
                if line.hasPrefix("new file mode") { file.change = .added }
                else if line.hasPrefix("deleted file mode") { file.change = .deleted }
                else if line.hasPrefix("rename from ") { file.change = .renamed; file.oldPath = String(line.dropFirst("rename from ".count)) }
                else if line.hasPrefix("rename to ") { file.path = String(line.dropFirst("rename to ".count)) }
                else if line.hasPrefix("+++ "), line != "+++ /dev/null" { file.path = path(line.dropFirst(4)) }
                else if line.hasPrefix("--- "), line != "--- /dev/null", file.change == .deleted { file.path = path(line.dropFirst(4)) }
            }
            if line.hasPrefix("@@ "), let head = hunk(line) {
                if let open = file.head {
                    file.hunks.append(DiffHunk(oldStart: open.0, oldCount: open.1, newStart: open.2, newCount: open.3, lines: file.lines))
                    file.lines = []
                }
                file.head = head
                continue
            }
            guard file.head != nil, let first = line.first, "+- \\".contains(first) else { continue }
            if first == "+" { file.added += 1 } else if first == "-" { file.removed += 1 }
            if file.kept < cap { file.lines.append(String(line)); file.kept += 1 } else { file.truncated = true }
        }
        close()
        return files.map { file in
            // Hunks past the cap are left out whole.
            FileDiff(path: file.path, oldPath: file.oldPath, change: file.change, additions: file.added, deletions: file.removed,
                     hunks: file.hunks.filter { !$0.lines.isEmpty || $0.oldCount + $0.newCount == 0 }, truncated: file.truncated)
        }
    }

    private static func hunk(_ line: Substring) -> (Int, Int, Int, Int)? {
        // @@ -a[,b] +c[,d] @@
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ part: Substring) -> (Int, Int)? {
            let numbers = part.dropFirst().split(separator: ",").map { Int($0) }
            guard let start = numbers.first ?? nil else { return nil }
            return (start, numbers.count > 1 ? numbers[1] ?? 1 : 1)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    /// A turn's plan (`turn/plan/updated`).
    public static func plan(_ params: JSON) -> TurnPlan? {
        guard let steps = params["plan"]?.array else { return nil }
        return TurnPlan(explanation: params["explanation"]?.string, steps: steps.compactMap { step in
            step["step"]?.string.map { TranscriptTodo(text: $0, status: .init(rawValue: step["status"]?.string ?? "pending")) }
        })
    }

    /// Paths and a unified-diff-ish text of a `fileChange` item, kept so its approval can show them.
    public static func changes(_ item: JSON) -> (files: [String], diff: String)? {
        guard item["type"]?.string == "fileChange", let changes = item["changes"]?.array else { return nil }
        let files = changes.compactMap { $0["path"]?.string }
        let diff = changes.compactMap { $0["diff"]?.string }.joined(separator: "\n")
        return (files, diff)
    }
}
