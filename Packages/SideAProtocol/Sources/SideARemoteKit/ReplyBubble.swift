import Foundation

/// A reply's bubble on the phone: its stage moves only along `ReplyProgress`'s table, and `watch` is what can still settle
/// it once the Mac's receipts can't.
public struct ReplyBubble: Hashable, Sendable {
    public enum Watch: Hashable, Sendable {
        case receipts
        /// Sent or held when Side A restarted on the Mac, whose receipts went with it: only the transcript settles it now.
        case unchecked
        /// Interrupt and Send's stop took it off the agent's prompt to type it again ahead of the reply `with`. Until that
        /// one has gone only Side A's memory holds it, so a restart there loses it. `unchecked`: it was before.
        case carried(with: String, unchecked: Bool)
        /// Off screen since the transcript showed it, and kept a while for a receipt that says it wasn't read after all.
        case shownAway
    }

    public enum Event: Hashable, Sendable {
        case progress(ReplyProgress.Event)
        /// To a stage one event of `ReplyProgress` reaches from here (`ReplyProgress.moves`): the Mac's answer, or what a
        /// Take Back came to, as the caller read it.
        case reached(ReplyProgress.Stage)
        /// Its flight ended unsent, or a Stop gave it back: its words go to the field.
        case gaveBack
        /// Taken back, taken out of the queue, or replaced by what has to happen first: it goes, and its words with it.
        case withdrawn
        case receiptsLost
        case carry(with: String)
        case uncarry
        /// Side A restarted on the Mac. `withSending`: the reply it was carried ahead of hadn't gone yet. `received`: a
        /// receipt from the restarted Mac names it, so the agent still has it.
        case restarted(withSending: Bool, received: Bool)
        /// A user turn in the Mac's transcript is it. `bound`: it went under an outbox item, which receipts name.
        case shown(bound: Bool)
        case forgotten
    }

    public enum Next: Hashable, Sendable {
        case stays(ReplyBubble)
        case returns
        case leaves
    }

    public private(set) var stage: ReplyProgress.Stage
    public private(set) var watch: Watch

    public init(_ stage: ReplyProgress.Stage = .sending, watch: Watch = .receipts) {
        self.stage = stage; self.watch = watch
    }

    public static let showable: Set<ReplyProgress.Stage> = [.sent, .queued, .held, .read]
    /// Stages that wait on a receipt only the agent's own record gives.
    public static let awaitingReceipt: Set<ReplyProgress.Stage> = [.sent, .held]

    public var unchecked: Bool {
        guard Self.awaitingReceipt.contains(stage) else { return false }
        switch watch {
        case .unchecked, .carried(_, unchecked: true): return true
        default: return false
        }
    }

    public func next(_ event: Event) -> Next? {
        if watch == .shownAway {
            switch event {
            case .progress(let event): return ReplyProgress(stage).next(event)?.stage == .unsent ? .returns : nil
            case .forgotten: return .leaves
            default: return nil
            }
        }
        let waiting = Self.awaitingReceipt.contains(stage)
        let uncarried: Watch = if case .carried(_, let unchecked) = watch { unchecked ? .unchecked : .receipts } else { watch }
        switch event {
        case .progress(let event):
            guard let next = ReplyProgress(stage).next(event)?.stage, next != stage else { return nil }
            return moved(to: next)
        // The field and leaving are `gaveBack`'s and `withdrawn`'s, which carry what happens to the words.
        case .reached(let to):
            guard to != stage, ![.unsent, .withdrawn].contains(to), ReplyProgress.moves(stage, to: to) else { return nil }
            return moved(to: to)
        // From any stage on screen: the caller has already read it against `ReplyProgress` (a receipt's `dropped`) or it is
        // its flight's own end, which can come after a receipt moved the bubble on (a held one whose answer was refused).
        case .gaveBack: return .returns
        case .withdrawn: return .leaves
        case .receiptsLost:
            guard waiting else { return nil }
            switch watch {
            case .receipts: return .stays(ReplyBubble(stage, watch: .unchecked))
            case .carried(let with, unchecked: false): return .stays(ReplyBubble(stage, watch: .carried(with: with, unchecked: true)))
            default: return nil
            }
        case .carry(let with):
            guard waiting else { return watch == uncarried ? nil : .stays(ReplyBubble(stage, watch: uncarried)) }
            let next = Watch.carried(with: with, unchecked: uncarried == .unchecked)
            return next == watch ? nil : .stays(ReplyBubble(stage, watch: next))
        case .uncarry:
            return watch == uncarried ? nil : .stays(ReplyBubble(stage, watch: uncarried))
        case .restarted(let withSending, let received):
            guard case .carried = watch else { return nil }
            return withSending && waiting && !received ? .returns : .stays(ReplyBubble(stage, watch: uncarried))
        case .shown(let bound):
            guard Self.showable.contains(stage) else { return nil }
            return bound && stage != .read ? .stays(ReplyBubble(stage, watch: .shownAway)) : .leaves
        case .forgotten: return nil
        }
    }

    /// The watch outlives the stage it was set in: only `unchecked` and a restart read it, and both look at the stage.
    private func moved(to stage: ReplyProgress.Stage) -> Next {
        switch stage {
        case .unsent: .returns
        case .withdrawn: .leaves
        default: .stays(ReplyBubble(stage, watch: watch))
        }
    }
}
