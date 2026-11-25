import Foundation
import SideACore
import SideAProtocol

/// The replies phones sent, kept so the user row each one became in a transcript can say which it was (`TranscriptMessage.replyID`).
/// The Mac pairs them, once and for good: the words and the time are only how it finds the row, and the phone then settles by id,
/// whichever way the words reached the agent. Memory only: a row paired before a relaunch is simply unpaired after it, and the
/// phone falls back to matching words as it always has.
final class SentReplies: @unchecked Sendable {
    struct Entry { let id: String; let text: String; let at: Double }

    /// One for the process, as the Mac has one Remote.
    static let shared = SentReplies()
    static let kept = 100
    static let window: Double = 24 * 3_600
    /// The phone's clock and the transcript's differ by a little.
    static let skew: Double = 30

    private let lock = NSLock()
    private var entries: [String: [Entry]] = [:]
    private var claimed: [String: [String: String]] = [:]

    func record(conversation: String, key: String?, text: String, at: Double = Date().timeIntervalSince1970) {
        guard let key, !key.isEmpty, !text.isEmpty else { return }
        lock.withLock {
            var list = entries[conversation, default: []]
            let id = ReplyReceipt.family(key)
            guard !list.contains(where: { $0.id == id }) else { return }
            list.append(Entry(id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines), at: at))
            list.removeAll { at - $0.at > Self.window }
            if list.count > Self.kept { list.removeFirst(list.count - Self.kept) }
            entries[conversation] = list
            if entries.count > 64, let oldest = entries.min(by: { ($0.value.last?.at ?? 0) < ($1.value.last?.at ?? 0) })?.key {
                entries[oldest] = nil
                claimed[oldest] = nil
            }
        }
    }

    /// `messages` (ascending) with `replyID` on each user row a recorded reply became. Oldest reply to oldest row, one row for each.
    func annotate(_ messages: [TranscriptMessage], conversation: String) -> [TranscriptMessage] {
        lock.withLock {
            guard let list = entries[conversation], !list.isEmpty else { return messages }
            var taken = claimed[conversation, default: [:]]
            var used = Set(taken.values)
            let out = messages.map { message -> TranscriptMessage in
                guard message.role == .user else { return message }
                var row = message
                if let id = taken[message.uuid] {
                    row.replyID = id
                    return row
                }
                let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty, let entry = list.first(where: { entry in
                    !used.contains(entry.id) && (message.at ?? .infinity) >= entry.at - Self.skew
                        && (entry.text == text || (message.textTruncated && entry.text.hasPrefix(text)))
                }) else { return message }
                used.insert(entry.id)
                taken[message.uuid] = entry.id
                row.replyID = entry.id
                return row
            }
            claimed[conversation] = taken
            return out
        }
    }

    func annotate(_ page: TranscriptPage, conversation: String) -> TranscriptPage {
        TranscriptPage(sessionID: page.sessionID, generation: page.generation, messages: annotate(page.messages, conversation: conversation),
                              replaced: annotate(page.replaced, conversation: conversation), before: page.before, after: page.after,
                              hasMoreAfter: page.hasMoreAfter, count: page.count, inheritedBefore: page.inheritedBefore, reset: page.reset,
                              agentID: page.agentID)
    }
}
