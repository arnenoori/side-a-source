import Foundation
import SideAProtocol

/// A message sent from the phone, from the tap until the agent has read it or it is back in the field.
public struct ReplyProgress: Hashable, Sendable {
    public enum Stage: Hashable, Sendable, CaseIterable {
        case sending
        /// Typed into the agent's terminal with Enter pressed; the agent hasn't recorded it yet.
        case sent
        /// The agent queued it and reads it once its current step ends.
        case held
        case note
        case queued
        case takingBack
        case read
        case unsent
        case withdrawn
    }

    public enum Event: Hashable, Sendable, CaseIterable {
        /// The Mac's answers: `typed`, `note`, `queued`, and `followUp` or `inbox`.
        case typed, left, waits, taken
        /// Refused, unreachable, or not signed.
        case refused
        /// Receipts, or the transcript or mail showing it read.
        case held, read
        /// It never went in, the agent let go of it, or the Mac dropped it from its queue.
        case dropped
        /// A second note joined it, so it goes again.
        case amended
        case takeBack, takenBack, tooLate, keptBack
        case overdue
        case retry
    }

    public enum Action: Hashable, Sendable, CaseIterable {
        case edit, delete, copy, retry, sendNow, interruptAndSend
    }

    public private(set) var stage: Stage
    public private(set) var overdue: Bool
    /// Where a Take Back goes back to when it fails.
    public private(set) var before: Stage?

    public init(_ stage: Stage = .sending, overdue: Bool = false, before: Stage? = nil) {
        self.stage = stage; self.overdue = overdue; self.before = before
    }

    /// Nil when the event means nothing here, so a late or repeated one changes nothing.
    public func next(_ event: Event) -> ReplyProgress? {
        switch (stage, event) {
        case (.sending, .typed): ReplyProgress(.sent)
        case (.sending, .left): ReplyProgress(.note)
        case (.sending, .waits): ReplyProgress(.queued)
        case (.sending, .taken): ReplyProgress(.read)
        case (.sending, .refused), (.sending, .dropped): ReplyProgress(.unsent)
        // A receipt can come over the socket before the answer does.
        case (.sending, .held), (.sent, .held): ReplyProgress(.held)
        case (.sending, .read), (.sent, .read), (.held, .read), (.note, .read), (.queued, .read): ReplyProgress(.read)
        case (.sent, .dropped), (.held, .dropped), (.note, .dropped), (.queued, .dropped): ReplyProgress(.unsent)
        case (.note, .amended): ReplyProgress(.sending)
        case (.note, .takeBack), (.queued, .takeBack): ReplyProgress(.takingBack, before: stage)
        case (.takingBack, .takenBack): ReplyProgress(.withdrawn)
        case (.takingBack, .tooLate): ReplyProgress(.read)
        case (.takingBack, .keptBack), (.takingBack, .overdue): ReplyProgress(before ?? .note)
        case (.unsent, .retry): ReplyProgress(.sending)
        case (let stage, .overdue) where !overdue && Self.patience(stage) != nil: ReplyProgress(stage, overdue: true, before: before)
        default: nil
        }
    }

    /// Seconds in a stage before it is overdue. Nil: it waits for something its label names and the user can change.
    public static func patience(_ stage: Stage) -> Double? {
        switch stage {
        case .sending: 30
        // Claude records a queued message within a second of Enter.
        case .sent: 20
        // Half of Claude's held messages are read within 10 s; one in ten waits more than 3 min behind a long step.
        case .held: 45
        case .note: 60
        case .takingBack: 15
        case .queued, .read, .unsent, .withdrawn: nil
        }
    }

    /// `interrupts`: the session takes Esc or its app server's interrupt.
    public func actions(interrupts: Bool) -> [Action] {
        switch stage {
        // Esc frees only what the agent has queued; typed text it never took is the Mac's check to report.
        case .sending, .sent, .takingBack, .read: [.copy]
        case .held: overdue && interrupts ? [.interruptAndSend, .copy] : [.copy]
        case .note: [.edit, .copy, .delete]
        case .queued: interrupts ? [.sendNow, .edit, .copy, .delete] : [.edit, .copy, .delete]
        case .unsent: [.retry, .copy]
        case .withdrawn: []
        }
    }

    public var settled: Bool { [.read, .unsent, .withdrawn].contains(stage) }
    /// The agent has it, or will be handed it without the phone doing more.
    public var delivered: Bool { [.sent, .held, .note, .queued, .read].contains(stage) }
    public var textInField: Bool { stage == .unsent }

    /// Some event of the table moves `stage` to `to`.
    public static func moves(_ stage: Stage, to: Stage) -> Bool {
        if stage == to { return true }
        let starts = stage == .takingBack ? [Stage.note, .queued].map { ReplyProgress(.takingBack, before: $0) } : [ReplyProgress(stage)]
        return starts.contains { start in Event.allCases.contains { start.next($0)?.stage == to } }
    }
}

public extension ReplyResult.Delivery {
    /// A follow-up goes to Claude's waiting Stop hook and an inbox reply to the hook that takes it within a second: both are
    /// the agent's input when the Mac answers. One this build doesn't know claims no more than typed.
    var event: ReplyProgress.Event {
        switch self {
        case .note: .left
        case .queued: .waits
        case .followUp, .inbox: .taken
        default: .typed
        }
    }

    /// Where a sent reply stands once the Mac answered with this.
    var stage: ReplyProgress.Stage? { ReplyProgress(.sending).next(event)?.stage }
}

public extension ReplyReceipt {
    var event: ReplyProgress.Event? {
        switch stage {
        case .typed: .typed
        case .held: .held
        case .read: .read
        case .unsent: .dropped
        default: nil
        }
    }
}
