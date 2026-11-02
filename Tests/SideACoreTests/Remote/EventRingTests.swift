import Foundation
@testable import SideACore
import Testing

@Test func replaysAfterAKnownSequenceOrAsksForASnapshot() {
    var ring = EventRing<Int>(epoch: "e1", capacity: 3, maxAge: 600)
    for _ in 0..<5 { ring.append(at: 0) { $0 * 10 } }
    #expect(ring.seq == 5)
    #expect(ring.replay(epoch: "e1", after: 3, now: 0) == [40, 50])
    #expect(ring.replay(epoch: "e1", after: 2, now: 0) == [30, 40, 50])
    #expect(ring.replay(epoch: "e1", after: 5, now: 0) == [])
    // Older than the ring, from the future, another launch, or a first connect: a snapshot.
    #expect(ring.replay(epoch: "e1", after: 1, now: 0) == nil)
    #expect(ring.replay(epoch: "e1", after: 6, now: 0) == nil)
    #expect(ring.replay(epoch: "e0", after: 4, now: 0) == nil)
    #expect(ring.replay(epoch: nil, after: nil, now: 0) == nil)
    // Events past ten minutes are gone even when the ring has room.
    #expect(ring.replay(epoch: "e1", after: 3, now: 601) == nil)
}
