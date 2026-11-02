import Foundation

/// The last state events, so a phone that reconnects gets what it missed instead of a whole snapshot.
public struct EventRing<Event: Sendable>: Sendable {
    public let epoch: String
    public private(set) var seq = 0
    public let capacity: Int
    public let maxAge: TimeInterval
    private var events: [(seq: Int, at: TimeInterval, event: Event)] = []

    public init(epoch: String, capacity: Int = 500, maxAge: TimeInterval = 600) {
        self.epoch = epoch; self.capacity = capacity; self.maxAge = maxAge
    }

    /// `make` receives the event's sequence number, so it can be encoded once with it.
    @discardableResult
    public mutating func append(at now: TimeInterval, _ make: (Int) -> Event) -> Event {
        seq += 1
        let event = make(seq)
        events.append((seq, now, event))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        return event
    }

    /// Events after `lastSeq`, or nil when the client needs a snapshot: another epoch, a future seq, or one older than the ring.
    public func replay(epoch: String?, after lastSeq: Int?, now: TimeInterval) -> [Event]? {
        guard epoch == self.epoch, let lastSeq, lastSeq >= 0, lastSeq <= seq else { return nil }
        if lastSeq == seq { return [] }
        let kept = events.filter { now - $0.at <= maxAge }
        guard let first = kept.first, first.seq <= lastSeq + 1 else { return nil }
        return kept.filter { $0.seq > lastSeq }.map(\.event)
    }
}
