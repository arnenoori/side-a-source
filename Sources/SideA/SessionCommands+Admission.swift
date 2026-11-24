import Foundation
import SideACore
import SideAProtocol

/// Whether a reply still answers where its session stands, and Send Now's queued reply until it is delivered or back.
extension SessionCommands {
    /// A reply admitted with a `seen`, for `ReplyAdmission.chain`.
    struct Delivered {
        let seen: String
        let device: String?
        let at: Date
        let key: String?
        let text: String
        /// The turn it started or joined, once the session's record showed it.
        var turn: String?
    }

    @MainActor static var delivered: [SessionKey: [Delivered]] = [:]
    /// Promotions in `waiting`, by queue id, with what puts each back.
    @MainActor static var promoting: [String: (putBack: () -> Void, at: Date)] = [:]
    /// `send` follows `plan` at once; one that never came (Side A quitting between the two) mustn't lose the reply.
    nonisolated static let promotionPatience: TimeInterval = 30

    /// Send Now's queued reply, from `plan` taking it out of the queue until it is delivered or back in the queue.
    enum Promotion: Equatable {
        case takenOut
        /// Typing still to do: `send` takes it from here, or `promotionPatience` puts it back.
        case waiting
        case sending
        case delivered
        case putBack
        case refused

        enum Event: CaseIterable { case planRefused, planDelivered, planTypes, sendBegins, sendFailed, sendSucceeded, patienceRanOut }

        /// The next state, and whether the reply goes back into the queue on the way. Nil: the event doesn't apply.
        func next(_ event: Event) -> (state: Promotion, putBack: Bool)? {
            switch (self, event) {
            case (.takenOut, .planRefused): (.putBack, true)
            case (.takenOut, .planDelivered): (.delivered, false)
            case (.takenOut, .planTypes): (.waiting, false)
            case (.waiting, .sendBegins): (.sending, false)
            case (.waiting, .patienceRanOut): (.putBack, true)
            case (.sending, .sendFailed): (.putBack, true)
            case (.sending, .sendSucceeded): (.delivered, false)
            // Later than `promotionPatience`: it is back in the queue, and delivered now as well it would go twice.
            case (.putBack, .sendBegins): (.refused, false)
            default: nil
            }
        }
    }

    /// One synchronous step on the main actor, as the Stop hook's is, so a turn can't end between the look and the delivery.
    func plan(_ message: Message, text: String, target: Target) -> Plan {
        let marks = Set(marks(target))
        let now = Date()
        Self.delivered = Self.delivered.compactMapValues { list in
            let kept = list.filter { ReplyAdmission.keeps(age: now.timeIntervalSince($0.at), turnKnown: $0.turn != nil) }
            return kept.isEmpty ? nil : kept
        }
        let device = message.origin?.device
        if message.mode != .keys, let seen = message.seen,
           !sees(seen, marks: marks, target: target, device: device), !store.remote.receipts.follows(message.idempotencyKey) {
            return .failed(.movedOn)
        }
        var putBack: (() -> Void)?
        if let promotes = message.promotes {
            guard let conversation = target.conversation, let taken = store.island.takeQueued(conversation, id: promotes) else { return .failed(.promotedGone) }
            putBack = taken
        }
        let plan = decide(message, text: text, target: target, current: message.seen != nil || message.promotes != nil)
        let promotion: (state: Promotion, putBack: Bool)? = switch plan {
        case _ where putBack == nil: nil
        case .failed: Promotion.takenOut.next(.planRefused)
        case .done: Promotion.takenOut.next(.planDelivered)
        default: Promotion.takenOut.next(.planTypes)
        }
        if promotion?.putBack == true { putBack?() }
        if case .failed = plan { return plan }
        if let promotes = message.promotes, let putBack, promotion?.state == .waiting { Self.promote(promotes, putBack: putBack, at: now) }
        if let seen = message.seen {
            Self.delivered[target.key, default: []].append(Delivered(seen: seen, device: device, at: now, key: message.idempotencyKey,
                                                                     text: message.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return plan
    }

    private static func promote(_ id: String, putBack: @escaping () -> Void, at: Date) {
        promoting[id] = (putBack, at)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(promotionPatience))
            guard let left = promoting[id], left.at == at else { return }
            promoting[id] = nil
            if Promotion.waiting.next(.patienceRanOut)?.putBack == true { left.putBack() }
        }
    }

    private func marks(_ target: Target) -> [String] {
        ReplyMark.marks(store.remote.events?.session(target.key), target.row.flatMap { WireBuilders.finished($0, island: store.island) })
    }

    private func sees(_ seen: String, marks: Set<String>, target: Target, device: String?) -> Bool {
        ReplyAdmission.admits(seen: seen, marks: marks, working: target.state(store.island) == .working,
                              chained: chained(seen, target: target, device: device))
    }

    /// Records the turn a reply turns out to have started, so it chains for `ReplyAdmission.chainKept`.
    private func chained(_ seen: String, target: Target, device: String?) -> Bool {
        let earlier = Self.delivered[target.key, default: []].enumerated().filter { $0.element.seen == seen && $0.element.device == device }
        guard !earlier.isEmpty, let live = target.live, let now = store.remote.receipts.turn(live) else { return false }
        let evidence = earlier.map { ReplyAdmission.Earlier(at: $0.element.at.timeIntervalSince1970,
                                                            words: store.remote.receipts.typed($0.element.key) ?? $0.element.text, turn: $0.element.turn) }
        switch ReplyAdmission.chain(evidence, newest: (now.id, now.at, now.text), sameWords: { ClaudeQueueEvidence.match($0, $1) != nil }) {
        case .none: return false
        case .known: return true
        case .claims(let index):
            Self.delivered[target.key]?[earlier[index].offset].turn = now.id
            return true
        }
    }
}
