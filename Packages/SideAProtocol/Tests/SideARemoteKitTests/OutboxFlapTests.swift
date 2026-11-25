import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

// A phone that reaches the Mac only through the relay: the events socket drops without a close every few seconds, and
// what was typed meanwhile must still go, once, and a refused item must not hold the rest.

private let sid = "8c1d2f3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f"
private let other = "9d2e3a4f-5b6c-4d7e-8f90-a1b2c3d4e5f6"

private func live(_ mac: FakeMac, _ sync: SyncEngine, socket index: Int) async throws -> FakeSocket {
    let socket = try await mac.socket(index)
    try socket.push(fixture: "ServerEvent.welcome")
    try await until("live \(index)") { await sync.state.connection.isLive }
    return socket
}

private func refusal(_ status: Int, _ code: String) -> FakeMac.Reply {
    .init(status: status, body: Data(#"{"error":{"code":"\#(code)","message":"No.","retryable":false}}"#.utf8))
}

private func delivered(_ sync: SyncEngine, _ id: String) async -> Bool {
    if case .delivered? = await sync.state.outcomes[id] { true } else { false }
}

@Test func aReplyPostedWhenTheSocketDiedGoesOnTheNextReconnectExactlyOnce() async throws {
    let mac = FakeMac()
    mac.respond { _ in .init(body: Data("{}".utf8)) }
    let gate = mac.hold("/v1/sessions/\(sid)/reply")
    let sync = try engine(mac)
    await sync.start()
    let first = try await live(mac, sync, socket: 0)
    let item = await sync.reply(sid, RemoteReply(text: "and the tests"))
    try await until("posting") { gate.arrived == 1 }
    first.serverClose(1006)
    _ = try await live(mac, sync, socket: 1)
    gate.open()
    try await until("delivered") { await delivered(sync, item.id) }
    try await until("cleared") { await sync.state.pending.isEmpty }
    #expect(mac.calls.count == 1)
    await sync.stop()
}

@Test func aReplyWhoseAnswerWasLostIsSentAgainUnderItsKeyAndTheReplayCounts() async throws {
    let mac = FakeMac()
    let attempts = Attempts()
    mac.respond { _ in
        // The Mac took it and answered, and the relay lost the answer; the second try is the Mac's replay.
        attempts.next() == 1 ? .init(status: 0) : .init(body: Data("{}".utf8), headers: ["Idempotent-Replay": "true"])
    }
    let sync = try engine(mac)
    await sync.start()
    var socket = try await live(mac, sync, socket: 0)
    let item = await sync.reply(sid, RemoteReply(text: "once"))
    try await until("first try") { mac.calls.count >= 1 }
    // The link flaps while the item waits for its retry.
    socket.serverClose(1006)
    socket = try await live(mac, sync, socket: 1)
    try await until("delivered") { await delivered(sync, item.id) }
    let keys = Set(mac.calls.map { $0.value(forHTTPHeaderField: "Idempotency-Key") })
    #expect(keys == [item.id], "every attempt carries the first one's key")
    #expect(await sync.state.pending.isEmpty)
    await sync.stop()
}

@Test func aSocketThatLivesOnlyAMomentStillDrainsWhatWaits() async throws {
    let mac = FakeMac()
    mac.respond { _ in .init(body: Data("{}".utf8)) }
    let sync = try engine(mac)
    await sync.start()
    var item: Outbox.Item?
    for index in 0..<4 {
        let socket = try await mac.socket(index)
        if index == 0 { item = await sync.reply(sid, RemoteReply(text: "held")) }
        // Dropped before the welcome: nothing may be sent into a link that never came up, and nothing may be lost.
        if index < 3 { socket.serverClose(1006); continue }
        try socket.push(fixture: "ServerEvent.welcome")
    }
    let id = try #require(item).id
    try await until("delivered") { await delivered(sync, id) }
    #expect(mac.calls.count == 1)
    await sync.stop()
}

@Test func aRefusedReplyDoesNotHoldTheOnesBehindIt() async throws {
    let mac = FakeMac()
    mac.respond { request in
        let path = request.url?.path ?? ""
        if path.contains(sid) { return refusal(401, "confirm_invalid") }
        return .init(body: Data("{}".utf8))
    }
    let sync = try engine(mac)
    await sync.start()
    _ = try await live(mac, sync, socket: 0)
    let refused = await sync.reply(sid, RemoteReply(text: "refused"))
    let behind = await sync.reply(sid, RemoteReply(text: "behind it"))
    let elsewhere = await sync.reply(other, RemoteReply(text: "elsewhere"))
    try await until("settled") {
        let outcomes = await sync.state.outcomes
        return outcomes[refused.id] != nil && outcomes[behind.id] != nil && outcomes[elsewhere.id] != nil
    }
    let outcomes = await sync.state.outcomes
    if case .failed(let error)? = outcomes[refused.id] { #expect(error.code == .confirmInvalid) } else { Issue.record("not failed: \(String(describing: outcomes[refused.id]))") }
    #expect(await delivered(sync, elsewhere.id))
    #expect(await sync.state.pending.isEmpty)
    await sync.stop()
}

@Test func aConflictOnOneReplyLetsTheNextOfItsSessionGo() async throws {
    let mac = FakeMac()
    let attempts = Attempts()
    mac.respond { _ in
        attempts.next() == 1
            ? refusal(409, "cannot_deliver")
            : .init(body: Data("{}".utf8))
    }
    let sync = try engine(mac)
    await sync.start()
    _ = try await live(mac, sync, socket: 0)
    let first = await sync.reply(sid, RemoteReply(text: "one"))
    let second = await sync.reply(sid, RemoteReply(text: "two"))
    try await until("both settled") {
        let outcomes = await sync.state.outcomes
        return outcomes[first.id] != nil && outcomes[second.id] != nil
    }
    #expect(await delivered(sync, second.id))
    await sync.stop()
}

private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
