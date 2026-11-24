import Foundation
import SideAProtocol

public extension ReplyProgress.Event {
    static func takeBack(answered outcome: OutboxOutcome) -> Self {
        switch outcome {
        case .delivered: .takenBack
        // Nothing left to take: the session read it first.
        case .failed(let error) where error.code == .notFound: .tooLate
        case .answeredElsewhere, .failed, .unknown, .notDelivered: .keptBack
        }
    }
}

/// The Mac's answer to a stop from this phone; Interrupt and Send sends its reply only on `stopped`.
public enum InterruptAnswer: Sendable, Equatable {
    case stopped
    case refused(String)
    case unreachable

    public init(_ outcome: OutboxOutcome) {
        switch outcome {
        case .delivered, .answeredElsewhere: self = .stopped
        case .failed(let error): self = .refused(error.message)
        case .unknown, .notDelivered: self = .unreachable
        }
    }

    public var notice: String? {
        switch self {
        case .stopped: nil
        case .refused(let message): "Couldn't stop it. \(message)"
        case .unreachable: "Couldn't reach the Mac to stop it."
        }
    }
}

/// A note this phone left, watched in its session's mail: mail that goes away once seen means the session read it.
public enum NoteMail: Sendable, Equatable, CaseIterable {
    case unwatched
    case unseen
    case seen

    public enum Event: Sendable, Equatable {
        case delivered
        case noteGone
        case mailShown
        /// `age`: since the note was sent.
        case mailAbsent(age: TimeInterval)
    }

    /// Not the transcript's "about then" window, though the same length: how long a note's mail may never show at all.
    public static let unseenRead: TimeInterval = 30

    public func next(_ event: Event) -> (state: Self, read: Bool) {
        switch (self, event) {
        case (.unwatched, .delivered): (.unseen, false)
        case (_, .delivered): (self, false)
        case (_, .noteGone): (.unwatched, false)
        case (.unwatched, _): (.unwatched, false)
        case (_, .mailShown): (.seen, false)
        case (.seen, .mailAbsent): (.unwatched, true)
        case (.unseen, .mailAbsent(let age)): age > Self.unseenRead ? (.unwatched, true) : (.unseen, false)
        }
    }
}

/// Replies held for the Mac go only once the link has caught up, so where each session stands can be judged; a timer says
/// so under the field when that takes long.
public enum HeldDelivery: Sendable, Equatable, CaseIterable {
    case idle
    case catchingUp
    case delivering

    public enum Event: Sendable, Equatable {
        /// Held replies could go now: the link is live and has a snapshot.
        case asked(caughtUp: Bool)
        case done
    }

    public enum Effect: Sendable, Equatable {
        case restartTimer
        case cancelTimer
        case deliver
    }

    public func next(_ event: Event) -> (state: Self, effects: [Effect]) {
        switch (self, event) {
        // One run at a time: a second would send the same replies again.
        case (.delivering, .asked): (self, [])
        case (_, .asked(caughtUp: false)): (.catchingUp, [.restartTimer])
        case (_, .asked(caughtUp: true)): (.delivering, [.cancelTimer, .deliver])
        case (.delivering, .done): (.idle, [])
        case (_, .done): (self, [])
        }
    }
}
