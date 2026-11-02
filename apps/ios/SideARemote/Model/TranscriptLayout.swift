import Foundation
import SideAProtocol
import SideARemoteShared

/// One thing the transcript draws, in order. Built by `TranscriptLayout` from the Mac's messages,
/// so the views never decide grouping or folding themselves.
enum TranscriptItem: Identifiable, Hashable {
    case earlier(count: Int)
    case separator(Date)
    case user(TranscriptMessage)
    case assistant(TranscriptMessage)
    case tool(TranscriptTool)
    case thinking(TranscriptTool)
    case group(StepGroup)
    case diff(TranscriptTool, FileDiff)
    case file(TranscriptTool, path: String, bytes: Int)
    case images(TranscriptTool)
    case notice(TranscriptMessage)
    case turnEnd(TurnEnd)
    case answered(TranscriptStore.AnsweredRequest)
    case request(RemoteRequest)
    case question(RemoteRequest)
    /// A turn this phone sent that the Mac's transcript doesn't show yet.
    case outgoing(TranscriptStore.Outgoing)
    /// Mail on the Mac this phone didn't leave: someone else's note, or a stop.
    case mail(MailState)

    var id: String {
        switch self {
        case .earlier: "earlier"
        case .separator(let date): "sep-\(date.timeIntervalSince1970)"
        case .user(let m), .assistant(let m), .notice(let m): "m-\(m.seq)"
        case .tool(let t), .thinking(let t): "t-\(t.id)"
        case .images(let t): "i-\(t.id)"
        case .diff(let t, let d): "d-\(t.id)-\(d.path)"
        case .file(let t, _, _): "f-\(t.id)"
        case .group(let g): "g-\(g.id)"
        case .turnEnd(let end): "end-\(end.seq)"
        case .answered(let a): "a-\(a.id)"
        case .request(let r), .question(let r): "r-\(r.id)"
        case .outgoing(let turn): "o-\(turn.id)"
        case .mail: "mail"
        }
    }
}

/// Consecutive steps between two pieces of assistant text.
struct StepGroup: Hashable, Identifiable {
    let id: String
    let tools: [TranscriptTool]
    let started: Date?
    let ended: Date?
    var running: Bool { tools.contains { $0.status == .running } }

    /// "Worked for 1m 12s · 14 steps".
    var title: String {
        let steps = "\(tools.count) steps"
        guard let started, let ended, let worked = Formatting.duration(ended.timeIntervalSince(started)) else { return steps }
        return running ? "Working · \(steps)" : "Worked for \(worked) · \(steps)"
    }
}

struct TurnEnd: Hashable {
    let seq: Int
    let model: String?
    let duration: TimeInterval?
    let markdown: String
}

enum TranscriptLayout {
    /// A run longer than this folds into a step group; v0 shows short runs flat.
    static let flatRun = 3
    /// Turns further apart than this get a date separator.
    static let separatorGap: TimeInterval = 30 * 60
    /// Files the transcript shows as a chip rather than a diff.
    static let documentExtensions: Set<String> = ["md", "pdf", "csv", "txt", "png", "jpg", "json", "html"]

    static func items(messages: [TranscriptMessage], earlier: Int, answered: [TranscriptStore.AnsweredRequest] = [],
                      open: [RemoteRequest] = [], working: Bool = false, outgoing: [TranscriptStore.Outgoing] = [],
                      mail: MailState? = nil) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
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
            items.append(.turnEnd(TurnEnd(seq: message.seq, model: message.model, duration: duration, markdown: message.text ?? "")))
            lastAssistant = nil
        }

        // The phone's own turns sit where they were sent: a note the session read stays by the step it came in.
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
                // Most thinking is redacted; back-to-back thoughts read as one row with their time summed.
                if let last = run.last, last.name == thinkingTool { run[run.count - 1] = merged(last, step) } else { run.append(step) }
            case .tools:
                for tool in message.tools {
                    // Diffs, documents and images are objects: they stand alone and split the run.
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
        if !working { endTurn(nil) }

        items += answered.map(TranscriptItem.answered)
        for request in open {
            if case .question = request.action { items.append(.question(request)) } else { items.append(.request(request)) }
        }
        // Sent since the last message: after the requests that were already waiting, where the user sees it land.
        items += sent.map(TranscriptItem.outgoing)
        // A note this phone left already says it waits, on its own bubble.
        if let mail, !(mail.kind == .note && outgoing.contains(where: \.isPendingNote)) { items.append(.mail(mail)) }
        return items
    }

    static func item(for tool: TranscriptTool) -> TranscriptItem {
        tool.name == thinkingTool ? .thinking(tool) : .tool(tool)
    }

    /// Thinking arrives as its own message; the phone draws it as a step in the run it sits in.
    static let thinkingTool = "Thinking"

    static func merged(_ a: TranscriptTool, _ b: TranscriptTool) -> TranscriptTool {
        let text = [a.output, b.output].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let total = (a.duration ?? 0) + (b.duration ?? 0)
        return TranscriptTool(id: a.id, name: thinkingTool, summary: "", status: b.status, startedAt: a.startedAt,
                              endedAt: b.status == .running ? nil : a.startedAt.map { $0 + total }, output: text)
    }

    /// A thinking message as a step: done once it has a duration or anything follows it, live while
    /// it's the last thing in a working turn.
    static func thought(_ message: TranscriptMessage, endedAt next: Timestamp?, working: Bool) -> TranscriptTool {
        let live = message.durationMS == nil && next == nil && working
        let ended = message.durationMS.flatMap { ms in message.at.map { $0 + Double(ms) / 1000 } } ?? next ?? message.at.map { $0 + 1 }
        return TranscriptTool(id: "thinking-\(message.seq)", name: thinkingTool, summary: "", status: live ? .running : .ok,
                              startedAt: message.at, endedAt: live ? nil : ended, output: message.text)
    }

    private static func standalone(_ tool: TranscriptTool) -> [TranscriptItem]? {
        if case .write(let path, let content) = tool.action, documentExtensions.contains((path as NSString).pathExtension.lowercased()) {
            return [.file(tool, path: path, bytes: content.utf8.count)]
        }
        if !tool.diffs.isEmpty { return tool.diffs.map { .diff(tool, $0) } }
        if !tool.images.isEmpty { return [.tool(tool), .images(tool)] }
        return nil
    }

    /// Whether a step group starts unfolded: only while its turn runs.
    static func startsExpanded(_ group: StepGroup) -> Bool { group.running }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
