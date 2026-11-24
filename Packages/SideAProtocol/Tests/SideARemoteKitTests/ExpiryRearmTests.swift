import Foundation
@testable import SideARemoteKit
import SideAProtocol
import Testing

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Timestamp
    init(_ time: Timestamp) { self.time = time }
    var now: Timestamp {
        get { lock.withLock { time } }
        set { lock.withLock { time = newValue } }
    }
}

/// The notification extension claims an item just before it expires and is suspended. The engine's expiry check finds the
/// claim fresh and settles nothing; with the connection loop ended (never paired here), nothing else touches the queue.
@Test func anExpiredItemAnotherProcessHeldSettlesOnceItsClaimLapses() async throws {
    let (outbox, _) = try temporaryOutbox()
    try await outbox.enqueue(Outbox.Item(id: "old", macID: "mac1", path: "/v1/sessions/s/reply", createdAt: 0, expiresAt: 100))
    #expect(await outbox.claim(for: "mac1", by: "extension", now: 99)?.id == "old")

    let clock = Clock(100.5)
    let sync = try engine(FakeMac(), token: nil, outbox: outbox, now: { clock.now })
    await sync.start()
    try await until("loop ended") { await sync.state.connection == .unpaired }

    // Several checks go by while the claim is fresh: the item is still the extension's.
    // swiftlint:disable:next sleep_literal_in_tests -- proving the item stays the extension's across several checks
    try await Task.sleep(for: .milliseconds(300))
    let waiting = await sync.state
    #expect(waiting.outcomes["old"] == nil)
    #expect(waiting.pending.map(\.id) == ["old"])

    // Its claim is 31 s old: free again. No drain, no enqueue, nothing else asks.
    clock.now = 130
    try await until("settled") {
        let state = await sync.state
        return state.outcomes["old"] == .notDelivered && state.pending.isEmpty
    }
    #expect(await outbox.items(for: "mac1").isEmpty)
    await sync.stop()
}

/// The other process finished it instead: "Sending…" ends when the queue no longer holds it.
@Test func anExpiredItemAnotherProcessFinishedLeavesPending() async throws {
    let (outbox, _) = try temporaryOutbox()
    try await outbox.enqueue(Outbox.Item(id: "old", macID: "mac1", path: "/v1/sessions/s/reply", createdAt: 0, expiresAt: 100))
    #expect(await outbox.claim(for: "mac1", by: "extension", now: 99)?.id == "old")
    let clock = Clock(100.5)
    let sync = try engine(FakeMac(), token: nil, outbox: outbox, now: { clock.now })
    await sync.start()
    try await until("loop ended") { await sync.state.connection == .unpaired }
    // swiftlint:disable:next sleep_literal_in_tests -- the other process finishes the item only after the engine has looked at it once
    try await Task.sleep(for: .milliseconds(100))
    await outbox.remove("old")
    try await until("gone") { await sync.state.pending.isEmpty }
    await sync.stop()
}
