import Foundation
import SideAProtocol

/// The follow-ups waiting for a session's turn to end, as a phone lists, edits and removes them.
extension Island {
    /// A phone's session rows carry the queue.
    func queuedChanged() { (watcher as? RemoteEvents)?.liveChanged() }

    /// Its id is its text's hash and which of the replies with that text it is, so it survives other replies going
    /// ahead of it. Of two alike, the later takes the earlier's id once that one goes: either way the id names those words.
    func waiting(_ session: String) -> [QueuedReply] {
        var seen: [String: Int] = [:]
        return (queued[session] ?? []).compactMap { item in
            guard case .waiting(let text, _) = item else { return nil }
            let hash = IDs.hashed(text)
            seen[hash, default: 0] += 1
            return QueuedReply(id: "\(hash)-\(seen[hash] ?? 1)", text: text)
        }
    }

    /// False when no waiting reply has that id any more.
    @discardableResult
    func removeQueued(_ session: String, id: String) -> Bool {
        guard let index = waiting(session).firstIndex(where: { $0.id == id }), var items = queued[session] else { return false }
        items.remove(at: index)
        queued[session] = items.isEmpty ? nil : items
        saveQueued()
        return true
    }

    /// Out of the queue to go now; what it answers puts it back where it was, for a delivery that then fails.
    func takeQueued(_ session: String, id: String) -> (() -> Void)? {
        guard let index = waiting(session).firstIndex(where: { $0.id == id }), var items = queued[session] else { return nil }
        let item = items.remove(at: index)
        queued[session] = items.isEmpty ? nil : items
        saveQueued()
        return { [weak self] in
            guard let self else { return }
            var items = self.queued[session] ?? []
            items.insert(item, at: min(index, items.count))
            self.queued[session] = items
            self.saveQueued()
        }
    }

    /// Puts new text in a waiting reply's place, with whoever sent the new text as its sender.
    func replaceQueued(_ session: String, id: String, with text: String, from origin: QueuedFollowUp.Origin?) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = waiting(session).firstIndex(where: { $0.id == id }) else { return false }
        queued[session]?[index] = .waiting(text, from: origin)
        saveQueued()
        return true
    }
}
