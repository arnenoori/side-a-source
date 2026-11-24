import Foundation
import SideAProtocol

/// One reply from the tap until it settles, stored beside its outbox item so a kill loses neither its fate nor its words.
public struct ReplyFlight: Codable, Sendable, Equatable {
    public enum Phase: Codable, Sendable, Equatable {
        /// Asking for the signature; nothing has gone.
        case signing
        /// In the outbox. `resigned`: already sent again with the signature the Mac asked for, so a second refusal stands.
        case queued(resigned: Bool)
        /// Refused for its signature, and being signed as the Mac asked.
        case resigning
        /// Not taken: its text and attachments wait for Retry.
        case unsent(reason: String)
        /// Typed while the Mac was out of reach: nothing signed or queued until the link is back and the app in front,
        /// so the signature is fresh and Face ID never asks from the background.
        case waiting
    }

    /// What the Mac's answer means for the flight.
    public enum Next: Sendable, Equatable {
        case delivered(Data?)
        case resign(ConfirmLevel)
        case unsent(reason: String)
    }

    public let session: SessionKey
    public var turn: String
    public let body: RemoteReply
    public let at: Timestamp
    public var phase: Phase
    /// The level the Mac asked for, so a Retry signs that from the start.
    public var needs: ConfirmLevel?
    /// Where the session stood when Send was pressed (its turn), so a reply that waits or goes unanswered is never sent
    /// later into a turn the person didn't see. Nil: not known, so it can't go later at all.
    public var since: String?
    /// Tells a `notDelivered` that sat out its lifetime unanswered from one that never got into the queue.
    public var queuedAt: Timestamp?
    /// The Idempotency-Key it went under once it was in the queue, so it may have reached the Mac without an answer
    /// coming back. Sent again, it goes under this key with `body` as it was, and the Mac's record answers it from the
    /// first attempt rather than typing it twice. Nil: it never left the phone under any key.
    public var key: String?

    /// An unsent reply is kept this long for its Retry.
    public static let unsentLifetime: Double = 86_400
    /// A reply held on the phone for the Mac goes unsent past this. The same 12 h as `Outbox.Item.legacyReplyLifetime`
    /// by history only: that one recognises rows older builds queued, and must not follow if this changes.
    public static let waitingLifetime: Double = 43_200

    public init(session: SessionKey, turn: String, body: RemoteReply, at: Timestamp, phase: Phase = .signing, needs: ConfirmLevel? = nil,
                since: String? = nil, queuedAt: Timestamp? = nil, key: String? = nil) {
        self.session = session; self.turn = turn; self.body = body; self.at = at; self.phase = phase; self.needs = needs; self.since = since
        self.queuedAt = queuedAt; self.key = key
    }

    public func unanswered(_ outcome: OutboxOutcome, now: Timestamp) -> Bool {
        guard case .queued = phase, outcome == .notDelivered, let queuedAt else { return false }
        return now - queuedAt >= Outbox.Item.replyLifetime - 1
    }

    /// `marks`: every name for where the session stands now, since a turn has one id running and another once finished.
    public func movedOn(_ marks: Set<String>) -> Bool {
        guard let since else { return true }
        return !marks.contains(since)
    }

    public func next(after outcome: OutboxOutcome) -> Next {
        switch outcome {
        case .failed(let error) where [.confirmRequired, .confirmInvalid].contains(error.code) && !error.pairAgain && phase != .queued(resigned: true):
            .resign(error.confirmLevel ?? .unlock)
        case .delivered(let body): .delivered(body)
        case .answeredElsewhere: .delivered(nil)
        case .unknown: .unsent(reason: "The Mac may not have it.")
        case .notDelivered: .unsent(reason: "The Mac couldn't be reached.")
        case .failed(let error): .unsent(reason: error.message)
        }
    }

    /// Where a flight read back after a launch stands. `inQueue`: its item is still in the outbox, or the engine has an
    /// outcome for it, so the engine settles it; otherwise it may never have gone.
    public func restored(inQueue: Bool) -> Phase { phase.next(.restored(inQueue: inQueue)) ?? phase }

    @discardableResult public mutating func move(_ event: Event) -> Bool {
        guard let next = phase.next(event) else { return false }
        phase = next
        return true
    }

    public func expired(now: Timestamp) -> Bool {
        if case .unsent = phase { return now - at > Self.unsentLifetime }
        return false
    }

    public enum Event: Sendable, Hashable {
        case signed
        case deferred
        case unsent(reason: String)
        case resign
        case unanswered
        case send
        case restored(inQueue: Bool)
    }
}

extension ReplyFlight.Phase {
    /// The whole lifecycle of a reply on the phone. Nil: the event doesn't move a flight in this phase.
    public func next(_ event: ReplyFlight.Event) -> Self? {
        switch (self, event) {
        case (_, .unsent(let reason)): .unsent(reason: reason)
        case (.signing, .signed): .queued(resigned: false)
        case (.resigning, .signed): .queued(resigned: true)
        // From `waiting` only: Face ID declined, or not asked, while the app is in the background.
        case (.signing, .deferred): .waiting
        // A refusal that asks for Face ID while away: held unsigned (as a new item) until the app is in front.
        case (.queued(resigned: false), .deferred): .waiting
        case (.queued(resigned: false), .resign): .resigning
        // A second refusal stands: `ReplyFlight.next(after:)` reads it as unsent, never as `resign`.
        case (.queued(resigned: true), .resign), (.queued(resigned: true), .deferred): nil
        case (.queued, .unanswered): .waiting
        case (.unsent, .send), (.waiting, .send): .signing
        // Retry goes by the Mac's outcome, not the phase, and a queued reply's bubble offers none; kept as the code allows it.
        case (.queued, .send): .signing
        case (.unsent, .restored), (.waiting, .restored): self
        case (.queued, .restored(inQueue: true)): self
        case (.signing, .restored(inQueue: true)): .queued(resigned: false)
        case (.resigning, .restored(inQueue: true)): .queued(resigned: true)
        case (.queued, .restored(inQueue: false)): .unsent(reason: "The Mac may not have it.")
        case (.signing, .restored(inQueue: false)), (.resigning, .restored(inQueue: false)): .unsent(reason: "Not confirmed.")
        case (.signing, .resign), (.signing, .unanswered), (.signing, .send), (.resigning, .deferred), (.resigning, .resign),
             (.resigning, .unanswered), (.resigning, .send), (.queued, .signed), (.unsent, .signed), (.unsent, .deferred),
             (.unsent, .resign), (.unsent, .unanswered), (.waiting, .signed), (.waiting, .deferred), (.waiting, .resign),
             (.waiting, .unanswered):
            nil
        }
    }
}
