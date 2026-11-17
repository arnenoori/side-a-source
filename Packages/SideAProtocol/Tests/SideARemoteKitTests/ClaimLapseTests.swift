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

/// A connected engine whose queue holds `held`, claimed by another process (the notification extension) at 1000.
private func connected(holding id: String, path: String = "/v1/sessions/a/reply", clock: Clock) async throws -> (SyncEngine, Outbox, FakeMac) {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    try await outbox.enqueue(Outbox.Item(id: id, macID: "mac1", path: path, createdAt: 999, expiresAt: 1600))
    #expect(await outbox.claim(for: "mac1", by: "extension", now: 1000)?.id == id)
    mac.respond { _ in .init(body: Data("{}".utf8)) }
    let sync = try engine(mac, outbox: outbox, now: { clock.now })
    await sync.start()
    let socket = try await mac.socket(0)
    try socket.push(fixture: "ServerEvent.welcome")
    try await until("live") { await sync.state.connection.isLive }
    return (sync, outbox, mac)
}

/// Row O2 of docs/remote/sync-state-machine.md: the drain ended with nothing it may take, and nothing looked again when the
/// claim that kept it from the item lapsed, so the row said Sending… until a reconnect, a new item or the item's expiry.
@Test func anItemBehindALapsedClaimIsSentOnceItLapses() async throws {
    let clock = Clock(1000)
    let (sync, _, mac) = try await connected(holding: "held", clock: clock)
    try await Task.sleep(for: .milliseconds(100))
    let early = await sync.state.outcomes["held"]
    #expect(early == nil && mac.calls.isEmpty, "the other process still holds it")

    clock.now = 1031
    try await until("sent") { if case .delivered = await sync.state.outcomes["held"] { true } else { false } }
    #expect(await sync.state.pending.isEmpty)
    await sync.stop()
}

/// The other process gave it back before the claim lapsed (it couldn't reach the Mac in its ten seconds).
@Test func anItemAnotherProcessGivesBackIsSent() async throws {
    let clock = Clock(1000)
    let (sync, outbox, _) = try await connected(holding: "held", clock: clock)
    try await Task.sleep(for: .milliseconds(60))
    await outbox.release("held")
    try await until("sent") { if case .delivered = await sync.state.outcomes["held"] { true } else { false } }
    await sync.stop()
}

/// The other process delivered it: the row doesn't say Sending… until the item's own expiry.
@Test func anItemAnotherProcessDeliveredLeavesPending() async throws {
    let clock = Clock(1000)
    let (sync, outbox, mac) = try await connected(holding: "held", clock: clock)
    #expect(await sync.state.pending.map(\.id) == ["held"])
    await outbox.remove("held")
    try await until("no longer pending") { await sync.state.pending.isEmpty }
    let outcome = await sync.state.outcomes["held"]
    #expect(mac.calls.isEmpty && outcome == nil)
    await sync.stop()
}

/// What sits behind the held item waits for it, and goes after it, in order.
@Test func itemsBehindAHeldOneGoAfterIt() async throws {
    let clock = Clock(1000)
    let (sync, _, mac) = try await connected(holding: "held", clock: clock)
    let behind = await sync.interrupt("a")
    try await Task.sleep(for: .milliseconds(80))
    #expect(mac.calls.isEmpty)
    clock.now = 1031
    try await until("both") {
        let outcomes = await sync.state.outcomes
        return outcomes["held"] != nil && outcomes[behind.id] != nil
    }
    #expect(mac.calls.map { $0.value(forHTTPHeaderField: "Idempotency-Key") } == ["held", behind.id])
    await sync.stop()
}
