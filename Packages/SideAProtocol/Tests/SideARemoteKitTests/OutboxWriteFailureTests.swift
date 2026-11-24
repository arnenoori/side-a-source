import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import SQLite3
import Testing

/// Another process (the notification extension) in the middle of a write: a second connection inside `BEGIN IMMEDIATE`.
private final class HeldWriteLock: @unchecked Sendable {
    private var db: OpaquePointer?
    init(_ file: URL) {
        precondition(sqlite3_open(file.path, &db) == SQLITE_OK)
        precondition(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
    }
    func release() {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        sqlite3_close(db)
        db = nil
    }
}

private func shortTimeoutOutbox() throws -> (Outbox, URL) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).sqlite")
    return (try Outbox(file: file, busyTimeout: 50), file)
}

@Test func anEnqueueTheDatabaseRefusesThrowsAndLeavesNothingQueued() async throws {
    let (outbox, file) = try shortTimeoutOutbox()
    let lock = HeldWriteLock(file)
    let item = Outbox.Item(id: "a", macID: "mac1", path: "/v1/sessions/s/reply", createdAt: 1, expiresAt: 99)
    await #expect(throws: Outbox.Failure.self) { try await outbox.enqueue(item) }
    lock.release()
    #expect(await outbox.items(for: "mac1").isEmpty)
    // Once the lock is gone the same item goes in.
    try await outbox.enqueue(item)
    #expect(await outbox.items(for: "mac1") == [item])
}

@Test func aReplyThatNeverReachedTheQueueSettlesAsNotSentAndRetries() async throws {
    let mac = FakeMac()
    let (outbox, file) = try shortTimeoutOutbox()
    mac.respond { _ in .init(body: Data("{}".utf8)) }
    let sync = try engine(mac, outbox: outbox)
    await sync.start()
    let socket = try await mac.socket(0)
    try socket.push(fixture: "ServerEvent.welcome")
    try socket.push(fixture: "ServerEvent.snapshot")
    try await until("snapshot") { await sync.state.seq == 41 }

    let lock = HeldWriteLock(file)
    let item = await sync.reply("s", RemoteReply(text: "go on"))
    // The caller hears it at once, through the outcome the screens already turn into "Not sent" and Retry.
    let state = await sync.state
    #expect(state.outcomes[item.id] == .notDelivered)
    #expect(state.pending.isEmpty)
    #expect(mac.calls.isEmpty)
    lock.release()

    let again = try #require(await sync.retry(itemID: item.id))
    try await until("delivered") { if case .delivered = await sync.state.outcomes[again.id] { true } else { false } }
    // A reply settled `notDelivered` goes again under its first key, which the Mac runs as new when it never had it.
    #expect(again.id != item.id && mac.calls.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") } == [item.id])
    await sync.stop()
}
