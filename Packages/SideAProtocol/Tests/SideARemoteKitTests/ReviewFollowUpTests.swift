import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SQLite3
import Testing

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.withLock { defer { used = true }; return !used } }
}

private func live(_ sync: SyncEngine, _ socket: FakeSocket) async throws {
    socket.push(nil, welcome("e", seq: 0, replay: false))
    try await until("live") { await sync.state.connection.isLive }
}

@Test func aMissedPongAfterASleepGoodbyeStillSaysAsleep() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    try await live(sync, socket)
    mac.hello(.init(status: 0))
    socket.push(nil, .bye(reason: ServerEvent.byeSleep))
    try await Task.sleep(for: .milliseconds(30))
    socket.failPings(URLError(.networkConnectionLost))
    await sync.setForeground(true)
    try await until("closed") { socket.closedByClient == 4008 }
    #expect(await sync.state.connection.cause == .macAsleep)
    // swiftlint:disable:next sleep_literal_in_tests -- proving the cause survives the attempts that follow
    try await Task.sleep(for: .milliseconds(100))
    #expect(await sync.state.connection.cause == .macAsleep, "and through the attempts after it")
    await sync.stop()
}

@Test func aNormalCloseAfterASleepGoodbyeStillSaysAsleep() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    try await live(sync, socket)
    socket.push(nil, .bye(reason: ServerEvent.byeSleep))
    try await Task.sleep(for: .milliseconds(30))
    socket.serverClose(1000)
    try await until("down") { await !sync.state.connection.isLive }
    #expect(await sync.state.connection.cause == .macAsleep)
    await sync.stop()
}

@Test func aRestartAfterStopDoesNotReportAsleep() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    try await live(sync, first)
    mac.hello(.init(status: 0))
    first.push(nil, .bye(reason: ServerEvent.byeSleep))
    first.serverClose(1001, ServerEvent.byeSleep)
    try await until("asleep") { await sync.state.connection.cause == .macAsleep }
    await sync.stop()
    #expect(await sync.state.connection == .idle)
    let asked = mac.requests.count
    await sync.start()
    try await until("a failed round") { mac.requests.count > asked + 1 }
    try await until("offline") { if case .offline = await sync.state.connection { true } else { false } }
    #expect(await sync.state.connection.cause == .unknown)
    await sync.stop()
}

@Test func anItemQueuedWhileTheQueueIsReadAfterAnEmptyClaimStillGoes() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    mac.respond { _ in .init(body: Data("{}".utf8)) }
    let sync = try engine(mac, outbox: outbox)
    await sync.start()
    let socket = try await mac.socket(0)
    try socket.push(fixture: "ServerEvent.welcome")
    try await until("live") { await sync.state.connection.isLive }
    let once = Once()
    await sync.setAfterQueueRead { [weak sync] in
        guard once.take() else { return }
        try? await outbox.enqueue(Outbox.Item(id: "late", macID: "mac1", path: "/v1/sessions/s/interrupt", createdAt: 1, expiresAt: 9_999_999_999))
        await sync?.drain()
    }
    await sync.setAfterEmptyClaim(nil)
    await sync.drain()
    try await until("the late item went") { if case .delivered = await sync.state.outcomes["late"] { true } else { false } }
    await sync.stop()
}

@Test func aFailedReadOfTheQueueKeepsThePendingList() async throws {
    let mac = FakeMac()
    let (outbox, file) = try temporaryOutbox()
    let now = Date().timeIntervalSince1970
    try await outbox.enqueue(Outbox.Item(id: "held", macID: "mac1", path: "/v1/sessions/a/reply", createdAt: now - 1, expiresAt: now + 600))
    #expect(await outbox.claim(for: "mac1", by: "extension", now: now)?.id == "held")
    let sync = try engine(mac, outbox: outbox)
    await sync.start()
    let socket = try await mac.socket(0)
    try socket.push(fixture: "ServerEvent.welcome")
    try await until("live") { await sync.state.connection.isLive }
    #expect(await sync.state.pending.map(\.id) == ["held"])

    var db: OpaquePointer?
    #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "ALTER TABLE outbox RENAME TO outbox_away", nil, nil, nil) == SQLITE_OK)
    #expect(await outbox.read(for: "mac1") == nil)
    // swiftlint:disable:next sleep_literal_in_tests -- proving several rechecks of an unreadable table leave the item pending
    try await Task.sleep(for: .milliseconds(200))
    #expect(await sync.state.pending.map(\.id) == ["held"])
    sqlite3_exec(db, "ALTER TABLE outbox_away RENAME TO outbox", nil, nil, nil)
    sqlite3_close(db)
    await sync.stop()
}
