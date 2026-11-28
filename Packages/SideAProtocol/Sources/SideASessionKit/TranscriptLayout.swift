import Foundation
import SideAProtocol

/// A message on its way out, as the layout needs to know it: where it falls in time, and whether it is a note that
/// already says it is waiting. Each app has its own type for the rest (delivery state, photos).
public protocol OutgoingTurn: Hashable, Identifiable where ID == String {
    var at: Date { get }
    var isPendingNote: Bool { get }
    /// Queued, held or left as a note: it waits for the running turn, where any other sent message starts the next one.
    var waits: Bool { get }
}

public extension OutgoingTurn {
    var waits: Bool { false }
}

/// One thing a transcript shows. `Answered` and `Outgoing` are the app's own records of a request it answered and a
/// message it sent: the phone's follow its outbox, the Mac's its own sends.
public enum TranscriptItem<Answered: Hashable & Identifiable, Outgoing: OutgoingTurn>: Identifiable, Hashable {
    case earlier(count: Int)
    case separator(Date)
    case user(TranscriptMessage)
    case assistant(TranscriptMessage)
    case tool(TranscriptTool)
    case subagent(TranscriptTool)
    case thinking(TranscriptTool)
    case group(StepGroup)
    case diff(TranscriptTool, FileDiff)
    case file(TranscriptTool, path: String, bytes: Int)
    case images(TranscriptTool)
    case notice(TranscriptMessage)
    case turnEnd(TurnEnd)
    case answered(Answered)
    case request(RemoteRequest)
    case question(RemoteRequest)
    case outgoing(Outgoing)
    case mail(MailState)
    case turn(TurnFold<Answered, Outgoing>)

    public var id: String {
        switch self {
        case .earlier: "earlier"
        case .separator(let date): "sep-\(date.timeIntervalSince1970)"
        case .user(let m), .assistant(let m), .notice(let m): "m-\(m.seq)"
        case .tool(let t), .thinking(let t), .subagent(let t): "t-\(t.id)"
        case .images(let t): "i-\(t.id)"
        case .diff(let t, let d): "d-\(t.id)-\(d.path)"
        case .file(let t, _, _): "f-\(t.id)"
        case .group(let g): "g-\(g.id)"
        case .turnEnd(let end): "end-\(end.seq)"
        case .answered(let a): "a-\(a.id)"
        case .request(let r), .question(let r): "r-\(r.id)"
        case .outgoing(let turn): "o-\(turn.id)"
        case .mail: "mail"
        case .turn(let fold): fold.id
        }
    }
}

public struct StepGroup: Hashable, Identifiable, Sendable {
    public let id: String
    public let tools: [TranscriptTool]
    public let started: Date?
    public let ended: Date?

    public init(id: String, tools: [TranscriptTool], started: Date?, ended: Date?) {
        self.id = id; self.tools = tools; self.started = started; self.ended = ended
    }

    public var running: Bool { tools.contains { $0.status == .running } }

    public var title: String {
        let steps = "\(tools.count) steps"
        guard let started, let ended, let worked = SessionFormat.duration(ended.timeIntervalSince(started)) else { return steps }
        return running ? "Working · \(steps)" : "Worked for \(worked) · \(steps)"
    }
}

public struct TranscriptRow<Answered: Hashable & Identifiable, Outgoing: OutgoingTurn>: Identifiable, Hashable {
    public var items: [TranscriptItem<Answered, Outgoing>]

    public init(items: [TranscriptItem<Answered, Outgoing>]) { self.items = items }

    public var id: String { items[0].id }
}

extension TranscriptItem {
    public var startsRow: Bool {
        switch self {
        case .earlier, .user, .assistant, .notice, .outgoing: true
        default: false
        }
    }
}

public struct TurnEnd: Hashable, Sendable {
    public let seq: Int
    public let model: String?
    public let duration: TimeInterval?
    public let message: TranscriptMessage

    public init(seq: Int, model: String?, duration: TimeInterval?, message: TranscriptMessage) {
        self.seq = seq; self.model = model; self.duration = duration; self.message = message
    }
}

/// Something that may be the end of a turn, so a list of items can say which turns have ended whatever records it
/// was built with.
public protocol TurnEnding {
    var endedTurn: Int? { get }
}

extension TranscriptItem: TurnEnding {
    public var endedTurn: Int? { if case .turnEnd(let end) = self { end.seq } else { nil } }
}

extension Sequence where Element: TurnEnding {
    /// The reply each ended turn finished with, by seq.
    public var endedTurns: Set<Int> { Set(compactMap(\.endedTurn)) }
}

/// The layout's fixed numbers. Apart from `TranscriptLayout`, which is generic and so can't hold them.
public enum TranscriptRules {
    /// A run of more steps than this folds into one group.
    public static let flatRun = 3
    public static let separatorGap: TimeInterval = 30 * 60
    /// Written files of these kinds show as a document to open, not as a diff.
    public static let documentExtensions: Set<String> = ["md", "markdown", "pdf", "csv", "tsv", "txt", "rtf", "png", "jpg", "jpeg", "gif", "heic", "webp",
                                                         "svg", "json", "html", "htm", "docx", "doc", "xlsx", "xls", "pptx", "ppt", "key", "pages",
                                                         "numbers", "ipynb", "log"]
    public static let thinkingTool = "Thinking"
}

/// Turns a conversation's messages into what a transcript shows: runs of steps grouped, diffs and files standing
/// alone, a turn's end marked, and the app's own answered requests and outgoing messages placed among them. One
/// implementation for the phone and the Mac.
public enum TranscriptLayout<Answered: Hashable & Identifiable, Outgoing: OutgoingTurn> {
    public typealias Item = TranscriptItem<Answered, Outgoing>
    static var flatRun: Int { TranscriptRules.flatRun }
    static var separatorGap: TimeInterval { TranscriptRules.separatorGap }
    static var documentExtensions: Set<String> { TranscriptRules.documentExtensions }
    public static var thinkingTool: String { TranscriptRules.thinkingTool }

    public static func items(messages: [TranscriptMessage], earlier: Int, answered: [Answered] = [],
                             open: [RemoteRequest] = [], working: Bool = false, outgoing: [Outgoing] = [],
                             mail: MailState? = nil) -> [Item] {
        var items: [Item] = []
        if earlier > 0 { items.append(.earlier(count: earlier)) }

        var run: [TranscriptTool] = []
        var lastAt: Date?
        var turnStart: Date?
        var lastAssistant: TranscriptMessage?

        func flushRun() {
            guard !run.isEmpty else { return }
            defer { run = [] }
            if run.count <= flatRun {
                items += run.map(item(for:))
                return
            }
            let starts = run.compactMap(\.startedAt).map(Date.init(timeIntervalSince1970:))
            let ends = run.compactMap { $0.endedAt ?? $0.startedAt }.map(Date.init(timeIntervalSince1970:))
            items.append(.group(StepGroup(id: run[0].id, tools: run, started: starts.min(), ended: ends.max())))
        }

        func endTurn(_ end: Date?) {
            guard let message = lastAssistant else { return }
            let duration = zip(turnStart, end ?? lastAt).map { $1.timeIntervalSince($0) }
            items.append(.turnEnd(TurnEnd(seq: message.seq, model: message.model, duration: duration, message: message)))
            lastAssistant = nil
        }

        var sent = outgoing.sorted { $0.at < $1.at }[...]

        for (index, message) in messages.enumerated() {
            let at = message.at.map(Date.init(timeIntervalSince1970:))
            while let turn = sent.first, let at, at > turn.at {
                flushRun()
                items.append(.outgoing(turn))
                sent.removeFirst()
            }
            switch message.role {
            case .thinking:
                let next = messages.dropFirst(index + 1).lazy.compactMap { $0.at ?? $0.tools.first?.startedAt }.first
                let step = thought(message, endedAt: next, working: working)
                if let last = run.last, last.name == thinkingTool { run[run.count - 1] = merged(last, step) } else { run.append(step) }
            case .tools:
                for tool in message.tools {
                    if let standalone = standalone(tool) {
                        flushRun()
                        items += standalone
                    } else {
                        run.append(tool)
                    }
                }
            case .user:
                flushRun()
                endTurn(nil)
                if let at, let lastAt, at.timeIntervalSince(lastAt) > separatorGap { items.append(.separator(at)) }
                items.append(.user(message))
                turnStart = at
            case .assistant:
                flushRun()
                items.append(.assistant(message))
                lastAssistant = message
            default:
                flushRun()
                items.append(.notice(message))
            }
            if let at { lastAt = at }
        }
        flushRun()
        // A message sent after the last reply starts the next turn before the session's own copy of it arrives: the turn
        // before it is over, and keeps its closing line while this one starts.
        if !working || sent.contains(where: { !$0.waits }) { endTurn(nil) }

        items += answered.map(Item.answered)
        for request in open {
            if case .question = request.action { items.append(.question(request)) } else { items.append(.request(request)) }
        }
        items += sent.map(Item.outgoing)
        // A note this phone left already says it waits, on its own bubble.
        if let mail, !(mail.kind == .note && outgoing.contains(where: \.isPendingNote)) { items.append(.mail(mail)) }
        return items
    }

    /// The lazy stack's rows: each message with the steps, cards and requests that follow it, up to the next message.
    /// With a lazy row per 44 pt step, the stack's guess at the rows it hadn't built swung with which steps it had just
    /// prefetched, and each new content height ran the prefetch again: a layout loop at 100% CPU, a page up the transcript.
    public static func rows(_ items: [Item]) -> [TranscriptRow<Answered, Outgoing>] {
        var rows: [TranscriptRow<Answered, Outgoing>] = []
        for item in items {
            if !item.startsRow, let last = rows.last, last.id != "earlier" {
                rows[rows.count - 1].items.append(item)
            } else {
                rows.append(TranscriptRow(items: [item]))
            }
        }
        return rows
    }

    public static func item(for tool: TranscriptTool) -> Item {
        tool.name == thinkingTool ? .thinking(tool) : .tool(tool)
    }

    public static func merged(_ a: TranscriptTool, _ b: TranscriptTool) -> TranscriptTool {
        let text = [a.output, b.output].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let total = (a.duration ?? 0) + (b.duration ?? 0)
        return TranscriptTool(id: a.id, name: thinkingTool, summary: "", status: b.status, startedAt: a.startedAt,
                              endedAt: b.status == .running ? nil : a.startedAt.map { $0 + total }, output: text)
    }

    public static func thought(_ message: TranscriptMessage, endedAt next: Timestamp?, working: Bool) -> TranscriptTool {
        let live = message.durationMS == nil && next == nil && working
        let ended = message.durationMS.flatMap { ms in message.at.map { $0 + Double(ms) / 1000 } } ?? next ?? message.at.map { $0 + 1 }
        return TranscriptTool(id: "thinking-\(message.seq)", name: thinkingTool, summary: "", status: live ? .running : .ok,
                              startedAt: message.at, endedAt: live ? nil : ended, output: message.text)
    }

    private static func standalone(_ tool: TranscriptTool) -> [Item]? {
        if tool.subagent != nil { return [.subagent(tool)] }
        if case .write(let path, let content) = tool.action, tool.diffs.isEmpty || documentExtensions.contains((path as NSString).pathExtension.lowercased()) {
            return [.file(tool, path: path, bytes: content.utf8.count)]
        }
        if !tool.diffs.isEmpty { return tool.diffs.map { .diff(tool, $0) } }
        if !tool.images.isEmpty { return [.tool(tool), .images(tool)] }
        return nil
    }

    public static func startsExpanded(_ group: StepGroup) -> Bool { group.running }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
