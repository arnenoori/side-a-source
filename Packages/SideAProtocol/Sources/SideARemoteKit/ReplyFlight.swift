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

    /// An unsent reply is kept this long for its Retry.
    public static let unsentLifetime: Double = 86_400

    public init(session: SessionKey, turn: String, body: RemoteReply, at: Timestamp, phase: Phase = .signing, needs: ConfirmLevel? = nil) {
        self.session = session; self.turn = turn; self.body = body; self.at = at; self.phase = phase; self.needs = needs
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
    public func restored(inQueue: Bool) -> Phase {
        if case .unsent = phase { return phase }
        if inQueue {
            if case .queued = phase { return phase }
            return .queued(resigned: phase == .resigning)
        }
        if case .queued = phase { return .unsent(reason: "The Mac may not have it.") }
        return .unsent(reason: "Not confirmed.")
    }

    public func expired(now: Timestamp) -> Bool {
        if case .unsent = phase { return now - at > Self.unsentLifetime }
        return false
    }
}
