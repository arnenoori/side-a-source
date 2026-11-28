import Foundation
import SideAProtocol

/// A turn's work folded behind one line ("Worked for 4m"): the steps and the interim replies, with the turn's answer
/// left outside it.
public struct TurnFold<Answered: Hashable & Identifiable, Outgoing: OutgoingTurn>: Hashable, Identifiable {
    public let id: String
    public let items: [TranscriptItem<Answered, Outgoing>]
    public let started: Date?
    public let duration: TimeInterval?
    public let live: Bool

    public init(id: String, items: [TranscriptItem<Answered, Outgoing>], started: Date?, duration: TimeInterval?, live: Bool) {
        self.id = id; self.items = items; self.started = started; self.duration = duration; self.live = live
    }

    public func holds(message seq: Int) -> Bool {
        items.contains { if case .assistant(let message) = $0 { message.seq == seq } else { false } }
    }
}

extension TranscriptLayout {
    public static func folded(_ items: [Item], working: Bool, since: Date?) -> [Item] {
        var result: [Item] = []
        var segment: [Item] = []
        var opener: Item?

        func flush(last: Bool) {
            defer { segment = [] }
            let ended = segment.contains { if case .turnEnd = $0 { true } else { false } }
            let live = last && working && !ended
            guard opener != nil || live || segment.contains(where: \.isStep) else { result += segment; return }
            var answer = segment.lastIndex { if case .assistant = $0 { true } else { false } }
            if live, let index = answer, segment[(index + 1)...].contains(where: \.isStep) { answer = nil }
            let work = segment.enumerated().filter { $0.offset != answer && $0.element.folds }.map(\.element)
            guard live || !work.isEmpty else { result += segment; return }
            var worked: TimeInterval?
            for case .turnEnd(let end) in segment { worked = end.duration }
            let start = opener?.sentAt ?? (live ? since : nil)
            result.append(.turn(TurnFold(id: "fold-\(opener?.id ?? work.first?.id ?? "live")", items: work, started: start,
                                         duration: live ? nil : worked, live: live)))
            if let answer { result.append(segment[answer]) }
            for item in segment where !item.folds {
                if case .turnEnd(let end) = item, worked != nil {
                    result.append(.turnEnd(TurnEnd(seq: end.seq, model: end.model, duration: nil, message: end.message)))
                } else {
                    result.append(item)
                }
            }
        }

        for item in items {
            switch item {
            case .user, .outgoing:
                flush(last: false)
                result.append(item)
                opener = item
            case .earlier, .separator:
                flush(last: false)
                result.append(item)
            default:
                segment.append(item)
            }
        }
        flush(last: true)
        return result
    }
}

extension TranscriptItem {
    /// Work the agent did, as against something it or the user said.
    public var isStep: Bool {
        switch self {
        case .tool, .subagent, .thinking, .group, .diff, .file, .images: true
        default: false
        }
    }
}

private extension TranscriptItem {

    var folds: Bool { if case .assistant = self { true } else { isStep } }

    var sentAt: Date? {
        switch self {
        case .user(let message): message.at.map(Date.init(timeIntervalSince1970:))
        case .outgoing(let turn): turn.at
        default: nil
        }
    }
}
