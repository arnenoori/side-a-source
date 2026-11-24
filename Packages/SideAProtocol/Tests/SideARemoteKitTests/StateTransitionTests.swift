import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

private let sid = "8c1d2f3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f"
private let rid = "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b"

private func helloData(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    var hello = try #require(JSONSerialization.jsonObject(with: Fixtures.data("Hello.paired")) as? [String: Any])
    change(&hello)
    return try JSONSerialization.data(withJSONObject: hello)
}

private func snapshotLive(_ mac: FakeMac, outbox: Outbox? = nil, timing: SyncTiming = fastTiming,
                          now: @escaping @Sendable () -> Timestamp = { Date().timeIntervalSince1970 }) async throws -> (SyncEngine, FakeSocket) {
    let sync = try engine(mac, outbox: outbox, timing: timing, now: now)
    await sync.start()
    let socket = try await mac.socket(0)
    try socket.push(fixture: "ServerEvent.welcome")
    try socket.push(fixture: "ServerEvent.snapshot")
    try await until("snapshot") { await sync.state.seq == 41 }
    return (sync, socket)
}

private func live(_ sync: SyncEngine, _ socket: FakeSocket, epoch: String = "e", seq: Int = 0, replay: Bool = false) async throws {
    socket.push(nil, welcome(epoch, seq: seq, replay: replay))
    try await until("live") { await sync.state.connection.isLive }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Timestamp
    init(_ time: Timestamp) { self.time = time }
    var now: Timestamp {
        get { lock.withLock { time } }
        set { lock.withLock { time = newValue } }
    }
}

@Test func startShowsConnectingUntilHelloAnswersThenLiveOnWelcome() async throws {
    let mac = FakeMac()
    let gate = mac.hold("/v1/hello")
    let sync = try engine(mac)
    #expect(await sync.state.connection == .idle)
    await sync.start()
    try await until("connecting") { await sync.state.connection == .connecting }
    #expect(await sync.state.hello == nil && mac.sockets.isEmpty)

    gate.open()
    let socket = try await mac.socket(0)
    var state = await sync.state
    #expect(state.connection == .connecting, "hello is answered but the welcome hasn't come")
    #expect(state.hello == hello && state.address == URL(string: "https://100.101.12.4:47800"))
    try await live(sync, socket)
    state = await sync.state
    if case .live = state.connection {} else { Issue.record("not live") }
    await sync.stop()
}

@Test func aWelcomeThatCannotReplayHoldsEventsUntilTheSnapshot() async throws {
    let mac = FakeMac()
    let (sync, first) = try await snapshotLive(mac)
    first.serverClose(1001)

    let second = try await mac.socket(1)
    second.push(nil, welcome("e5b0c7d2a1f3", seq: 50, replay: false))
    second.push(42, .hostedRemove(name: "sa-app-3f9c"))
    try await until("welcome") { await sync.state.connection.isLive }
    try await Task.sleep(for: .milliseconds(30))
    var state = await sync.state
    #expect(state.seq == 41 && state.hosted.count == 1)
    second.push(nil, .snapshot(StateSnapshot(seq: 50, epoch: "e5b0c7d2a1f3")))
    try await until("snapshot") { await sync.state.seq == 50 }
    #expect(await sync.state.hosted.isEmpty)
    second.serverClose(1001)

    let third = try await mac.socket(2)
    third.push(nil, welcome("other", seq: 52, replay: true))
    third.push(51, .hostedRemove(name: "x"))
    try await until("live again") { await sync.state.connection.isLive }
    try await Task.sleep(for: .milliseconds(30))
    state = await sync.state
    #expect(state.seq == 50 && state.epoch == "e5b0c7d2a1f3")
    await sync.stop()
}

@Test func eventsBehindAreIgnoredAndEventsAheadReconnect() async throws {
    let mac = FakeMac()
    let (sync, socket) = try await snapshotLive(mac)
    socket.push(41, .hostedRemove(name: "sa-app-3f9c"))
    socket.push(7, .hostedRemove(name: "sa-app-3f9c"))
    socket.push(42, .sessionRemove(id: sid, replacedBy: nil))
    try await until("42") { await sync.state.seq == 42 }
    let state = await sync.state
    #expect(state.hosted.count == 1 && state.sessions[sid] == nil)
    #expect(mac.sockets.count == 1)
    await sync.stop()
}

@Test func refreshTakesAnOlderEpochsNewerStateOnlyWhenItIsAhead() async throws {
    let mac = FakeMac()
    let (sync, _) = try await snapshotLive(mac)
    mac.respond { _ in .init(body: json(StateSnapshot(seq: 40, epoch: "e5b0c7d2a1f3"))) }
    try await sync.refresh()
    let held = await sync.state
    #expect(held.seq == 41 && held.sessions.count == 2)

    mac.respond { _ in .init(body: json(StateSnapshot(seq: 41, epoch: "e5b0c7d2a1f3"))) }
    try await sync.refresh()
    #expect(await sync.state.sessions.isEmpty, "equal seq is taken")

    mac.respond { _ in .init(body: json(StateSnapshot(seq: 3, epoch: "another"))) }
    try await sync.refresh()
    let state = await sync.state
    #expect(state.seq == 3 && state.epoch == "another" && state.sliceSeq.isEmpty)
    await sync.stop()
}

@Test func eachSliceTakesOnlyAListNewerThanSeqAndItsOwnLastRefresh() async throws {
    let mac = FakeMac()
    let (sync, socket) = try await snapshotLive(mac)
    func list(_ seq: Int) -> Data { json(RequestList(requests: [], seq: seq)) }
    let at41 = list(41), at44 = list(44), at43 = list(43)
    let before = await sync.state.requests

    mac.respond { _ in .init(body: at41) }
    try await sync.refreshRequests()
    var state = await sync.state
    #expect(state.requests == before && state.sliceSeq[.requests] == nil, "not newer than seq")

    mac.respond { _ in .init(body: at44) }
    try await sync.refreshRequests()
    state = await sync.state
    #expect(state.requests.isEmpty && state.sliceSeq[.requests] == 44 && state.seq == 41)

    mac.respond { _ in .init(body: at43) }
    try await sync.refreshRequests()
    #expect(await sync.state.sliceSeq[.requests] == 44, "older than the slice's last refresh")

    let accounts = json(AccountList(accounts: [], seq: 45))
    mac.respond { _ in .init(body: accounts) }
    try await sync.refreshAccounts()
    state = await sync.state
    #expect(state.accounts.isEmpty && state.sliceSeq[.accounts] == 45 && state.sliceSeq[.requests] == 44 && state.seq == 41)

    socket.push(42, .requestAdd(try fixture("RemoteRequest.bash", as: RemoteRequest.self)))
    try await until("42") { await sync.state.seq == 42 }
    #expect(await sync.state.requests.isEmpty)

    socket.push(43, .sessionRemove(id: sid, replacedBy: nil))
    try await until("43") { await sync.state.seq == 43 }
    #expect(await sync.state.sessions.count == 1)

    socket.push(nil, .snapshot(StateSnapshot(seq: 47, epoch: "e5b0c7d2a1f3")))
    try await until("snapshot") { await sync.state.seq == 47 }
    #expect(await sync.state.sliceSeq.isEmpty)
    await sync.stop()
}

@Test func revokedAfterGoingLiveKeepsTheStateAndStopsAsking() async throws {
    let mac = FakeMac()
    let (sync, socket) = try await snapshotLive(mac)
    socket.serverClose(4401)
    try await until("unpaired") { await sync.state.connection == .unpaired }
    let state = await sync.state
    #expect(state.sessions.count == 2 && state.hello != nil)
    let asked = mac.requests.count
    try await Task.sleep(for: .milliseconds(60))
    #expect(mac.requests.count == asked && mac.sockets.count == 1)

    mac.hello(.init(body: try Fixtures.data("Hello.paired")))
    await sync.reconnectNow()
    try await live(sync, try await mac.socket(1), epoch: "e5b0c7d2a1f3", seq: 41, replay: true)
    await sync.stop()
}

@Test func aHelloRefusedWith401IsABackoffNotARevocation() async throws {
    let mac = FakeMac()
    mac.hello(.init(status: 401, body: json(ErrorBody(error: APIError(code: .unauthorized, message: "Nope.")))))
    let sync = try engine(mac)
    await sync.start()
    try await until("several tries") { mac.requests.count > 4 }
    let state = await sync.state
    #expect(state.connection != .unpaired)
    if case .offline(_, let reason, _) = state.connection { #expect(reason == "Nope.") } else { Issue.record("not offline: \(state.connection)") }
    await sync.stop()
}

@Test func onlyAMacThatIsTooOldIsAskedAgainOnItsOwn() async throws {
    let old = FakeMac()
    old.hello(.init(body: try helloData { $0["maxProtocol"] = 0 }))
    let a = try engine(old)
    let shown = Task {
        var seen: [Connection] = []
        for await state in a.updates { seen.append(state.connection); if state.connection.isLive { break } }
        return seen
    }
    await a.start()
    try await until("asked three times") { old.requests.count >= 3 }
    #expect(await a.state.connection == .needsUpdate(mac: true))
    old.hello(.init(body: try Fixtures.data("Hello.paired")))
    try await live(a, try await old.socket(0))
    let seen = Array(await shown.value.drop { $0 != .needsUpdate(mac: true) })
    #expect(!seen.isEmpty && seen.allSatisfy { $0 == .needsUpdate(mac: true) || $0.isLive }, "\(seen)")
    await a.stop()

    let new = FakeMac()
    new.hello(.init(body: try helloData { $0["minClientBuild"] = 99 }))
    let b = try engine(new)
    await b.start()
    try await until("phone needs update") { await b.state.connection == .needsUpdate(mac: false) }
    let asked = new.requests.count
    // swiftlint:disable:next sleep_literal_in_tests -- proving a phone that needs an update asks no more
    try await Task.sleep(for: .milliseconds(100))
    #expect(new.requests.count == asked)
}

@Test func theSocketsOwnRefusalForAnUpdateEndsOrPollsLikeHelloDoes() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    first.serverClose(4426, "upgrade_client")
    try await until("phone") { await sync.state.connection == .needsUpdate(mac: false) }
    let asked = mac.requests.count
    try await Task.sleep(for: .milliseconds(60))
    #expect(mac.requests.count == asked)

    await sync.reconnectNow()
    let second = try await mac.socket(1)
    second.serverClose(4426, "upgrade_mac")
    try await until("mac") { await sync.state.connection == .needsUpdate(mac: true) }
    _ = try await mac.socket(2)
    await sync.stop()
}

@Test func tooManyConnectionsWaitsAndAForegroundSkipsIt() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    let before = Date().timeIntervalSince1970
    first.serverClose(4429)
    try await until("offline") { if case .offline = await sync.state.connection { true } else { false } }
    guard case .offline(let retryAt, let reason, _) = await sync.state.connection else { return }
    #expect(reason == "Too many connections to the Mac" && retryAt - before > 9 && retryAt - before < 11)
    try await Task.sleep(for: .milliseconds(60))
    #expect(mac.sockets.count == 1, "it waits")
    await sync.setForeground(true)
    _ = try await mac.socket(1)
    await sync.stop()
}

@Test func closeReasonsBecomeTheOfflineReason() async throws {
    let mac = FakeMac()
    var timing = fastTiming
    timing.backoffBase = 5
    timing.backoffCap = 5
    let sync = try engine(mac, timing: timing)
    await sync.start()
    let first = try await mac.socket(0)
    try await live(sync, first)
    first.push(nil, .bye(reason: "update"))
    first.serverClose(1001)
    try await until("offline") { if case .offline = await sync.state.connection { true } else { false } }
    if case .offline(_, let reason, _) = await sync.state.connection { #expect(reason == "Side A on the Mac closed (update)") }
    await sync.setForeground(true)
    let second = try await mac.socket(1)
    second.serverClose(4500)
    try await until("offline again") { if case .offline(_, let reason, _) = await sync.state.connection { reason == "Connection closed (4500)" } else { false } }
    await sync.stop()
}

@Test func immediateReconnectsGiveWayToABackoffWithItsReason() async throws {
    let mac = FakeMac()
    var timing = fastTiming
    timing.backoffBase = 5
    timing.backoffCap = 5
    let sync = try engine(mac, timing: timing)
    await sync.start()
    var socket = try await mac.socket(0)
    for index in 1...3 {
        socket.serverClose(4008)
        socket = try await mac.socket(index)
    }
    socket.serverClose(4008)
    try await until("backoff") { if case .offline(_, let reason, _) = await sync.state.connection { reason == "Connection kept dropping" } else { false } }
    #expect(mac.sockets.count == 4)
    await sync.stop()
}

@Test func anUndecodableFrameOutOfSequenceIsIgnored() async throws {
    let mac = FakeMac()
    let (sync, socket) = try await snapshotLive(mac)
    func broken(_ seq: Int) -> String {
        var frame = try! JSONSerialization.jsonObject(with: json(EventEnvelope(seq: seq, at: 1, event: .hostedRemove(name: "x")))) as! [String: Any]
        frame["data"] = ["name": 7]
        return String(decoding: try! JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }
    socket.push(raw: broken(44))
    socket.push(raw: broken(41))
    socket.push(raw: "not json")
    socket.push(42, .sessionRemove(id: sid, replacedBy: nil))
    try await until("42") { await sync.state.seq == 42 }
    #expect(mac.calls.isEmpty && mac.sockets.count == 1)
    await sync.stop()
}

@Test func stopClosesTheSocketKeepsTheStateAndEndsThePolling() async throws {
    let mac = FakeMac()
    let (sync, socket) = try await snapshotLive(mac)
    await sync.stop()
    #expect(socket.closedByClient == 1000)
    let state = await sync.state
    #expect(state.connection == .idle && state.sessions.count == 2)
    let asked = mac.requests.count
    await sync.reconnectNow()
    await sync.setForeground(true)
    try await Task.sleep(for: .milliseconds(60))
    #expect(mac.requests.count == asked && mac.sockets.count == 1)
    await sync.start()
    let again = try await mac.socket(1)
    #expect(again.sent.first == .hello(epoch: "e5b0c7d2a1f3", lastSeq: 41, capabilities: [.events, .transcriptStream]))
    await sync.stop()
}

@Test func backgroundingOnlyTellsTheMac() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    try await live(sync, socket)
    await sync.setForeground(false)
    try await until("presence") { socket.sent.contains(.presence(foreground: false, viewing: nil)) }
    #expect(socket.pings == 0 && socket.closedByClient == nil && mac.sockets.count == 1)
    await sync.setForeground(true)
    try await until("ping and presence") { socket.pings == 1 && socket.sent.contains(.presence(foreground: true, viewing: nil)) }
    await sync.stop()
}

@Test func aForegroundDuringABackoffSkipsIt() async throws {
    let mac = FakeMac()
    var timing = fastTiming
    timing.backoffBase = 30
    timing.backoffCap = 30
    mac.hello(.init(status: 0))
    let sync = try engine(mac, timing: timing)
    await sync.start()
    try await until("both addresses tried") { mac.requests.count >= 2 }
    try await until("offline") { if case .offline = await sync.state.connection { true } else { false } }
    let asked = mac.requests.count
    mac.hello(.init(body: try Fixtures.data("Hello.paired")))
    await sync.setForeground(true)
    try await live(sync, try await mac.socket(0))
    #expect(mac.requests.count > asked)
    await sync.stop()
}

@Test func theSleepGoodbyeIsNotReplacedByRelayRefusalsOrByAnAttempt() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    try await live(sync, first)
    let shown = Task {
        var seen: [Connection] = []
        for await state in sync.updates { seen.append(state.connection); if state.connection.isLive, seen.count > 3 { break } }
        return seen
    }
    mac.relayRefuses(true)
    first.push(nil, .bye(reason: ServerEvent.byeSleep))
    first.serverClose(1001, ServerEvent.byeSleep)
    try await until("asleep") { await sync.state.connection.cause == .macAsleep }
    // swiftlint:disable:next sleep_literal_in_tests -- proving rounds of refusals leave the sleep cause alone: the window must hold several of them
    try await Task.sleep(for: .milliseconds(400))
    #expect(await sync.state.connection.cause == .macAsleep)
    mac.relayRefuses(false)
    try await live(sync, try await mac.socket(1))
    #expect(await sync.state.connection.cause == .unknown)
    let seen = await shown.value
    let down = seen.drop { !$0.isLive }.drop { $0.isLive }
    #expect(down.contains { $0.cause == .macAsleep } && !down.contains { $0 == .connecting }, "\(seen)")
    await sync.stop()
}

@Test func aHelloThatAnswersClearsTheCauseBeforeTheWelcome() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    try await live(sync, first)
    mac.hello(.init(status: 0))
    first.push(nil, .bye(reason: ServerEvent.byeSleep))
    first.serverClose(1001, ServerEvent.byeSleep)
    try await until("asleep") { await sync.state.connection.cause == .macAsleep }
    mac.hello(.init(body: try Fixtures.data("Hello.paired")))
    _ = try await mac.socket(1)
    let state = await sync.state
    #expect(state.connection.cause == .unknown && !state.connection.isLive)
    await sync.stop()
}

@Test func aTerminalStateIsNotReplacedByTheWaitsThatFollow() async throws {
    let mac = FakeMac()
    mac.rekeyed(["100.101.12.4", "192.168.1.20"])
    let sync = try engine(mac)
    await sync.start()
    try await until("key changed") { await sync.state.connection == .keyChanged }
    #expect(mac.sockets.isEmpty)
    await sync.stop()
}

@Test func anItemAnotherProcessHoldsHoldsBackItsTargetOnly() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let now = Date().timeIntervalSince1970
    try await outbox.enqueue(Outbox.Item(id: "held", macID: "mac1", path: "/v1/sessions/a/reply", createdAt: now - 2, expiresAt: now + 600))
    #expect(await outbox.claim(for: "mac1", by: "extension", now: now)?.id == "held")
    mac.respond { _ in .init(body: Data("{}".utf8)) }
    let (sync, _) = try await snapshotLive(mac, outbox: outbox)
    let behind = await sync.interrupt("a")
    let other = await sync.interrupt("b")
    try await until("other target") { if case .delivered = await sync.state.outcomes[other.id] { true } else { false } }
    try await Task.sleep(for: .milliseconds(60))
    let outcomes = await sync.state.outcomes
    #expect(outcomes[behind.id] == nil && outcomes["held"] == nil)
    #expect(mac.calls.allSatisfy { $0.url?.path != "/v1/sessions/a/interrupt" && $0.url?.path != "/v1/sessions/a/reply" })
    await sync.stop()
}

@Test func aFailedAttemptIsRecordedAndTheItemGivenBack() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let busy = json(ErrorBody(error: APIError(code: .inProgress, message: "Still running.", retryable: true)))
    mac.respond { _ in .init(status: 409, body: busy) }
    let (sync, _) = try await snapshotLive(mac, outbox: outbox)
    let item = await sync.reply("s", RemoteReply(text: "go on"))
    try await until("two attempts") { mac.calls.count >= 2 }
    let stored = try #require(await outbox.items(for: "mac1").first)
    #expect(stored.id == item.id && stored.attempts >= 1 && stored.lastError?.code == .inProgress)
    #expect(Set(mac.calls.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }) == [item.id])
    await sync.stop()
}

@Test func anItemThatNeverReachedTheMacExpiresAndRetries() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    let clock = Clock(1000)
    mac.respond { _ in .init(status: 0) }
    let (sync, _) = try await snapshotLive(mac, outbox: outbox, now: { clock.now })
    let item = await sync.reply("s", RemoteReply(text: "go on"))
    try await until("tried") { mac.calls.count >= 2 }
    var sending = await sync.state
    #expect(sending.pending.map(\.id) == [item.id] && sending.outcomes[item.id] == nil)

    clock.now = item.expiresAt + 1
    try await until("not delivered") { await sync.state.outcomes[item.id] == .notDelivered }
    sending = await sync.state
    #expect(sending.pending.isEmpty)
    #expect(await outbox.items(for: "mac1").isEmpty)

    mac.respond { _ in .init(body: Data("{}".utf8)) }
    let again = try #require(await sync.retry(itemID: item.id))
    try await until("delivered") { if case .delivered = await sync.state.outcomes[again.id] { true } else { false } }
    let settled = await sync.state
    #expect(settled.latestOutcome(of: item.id) == settled.outcomes[again.id])
    await sync.stop()
}

@Test func aRevokedTokenGivesTheClaimedItemBack() async throws {
    let mac = FakeMac()
    let (outbox, _) = try temporaryOutbox()
    mac.respond { _ in .init(status: 401, body: json(ErrorBody(error: APIError(code: .unauthorized, message: "Pair again."))))}
    let (sync, socket) = try await snapshotLive(mac, outbox: outbox)
    let item = await sync.interrupt("s")
    try await until("unpaired") { await sync.state.connection == .unpaired }
    #expect(socket.closedByClient == 1000)
    #expect(await outbox.claim(for: "mac1", by: "someone else", now: Date().timeIntervalSince1970)?.id == item.id)
    let left = await sync.state
    #expect(left.outcomes[item.id] == nil && left.pending.map(\.id) == [item.id])
}

@Test func claimsFollowAnswersFirstThenTheOldestOfEachTarget() async throws {
    let (outbox, _) = try temporaryOutbox()
    func add(_ id: String, _ path: String, at: Double) async throws {
        try await outbox.enqueue(Outbox.Item(id: id, macID: "mac1", path: path, createdAt: at, expiresAt: 9_999))
    }
    try await add("s1", "/v1/sessions/s/reply", at: 1)
    try await add("s2", "/v1/sessions/s/interrupt", at: 2)
    try await add("t1", "/v1/sessions/t/reply", at: 3)
    try await add("a1", "/v1/requests/r/answer", at: 4)
    try await add("a2", "/v1/requests/r/answer", at: 5)

    #expect(await outbox.claim(for: "mac1", by: "app", now: 10)?.id == "a1")
    #expect(await outbox.claim(for: "mac1", by: "other", now: 10)?.id == "s1")
    #expect(await outbox.claim(for: "mac1", by: "third", now: 10)?.id == "t1")
    #expect(await outbox.claim(for: "mac1", by: "fourth", now: 10) == nil, "s2 and a2 wait behind claimed items")
    #expect(await outbox.claim(for: "mac1", by: "app", now: 10)?.id == "a1")
    #expect(await outbox.claim(for: "mac1", by: "fourth", now: 41)?.id == "a1")
    await outbox.release("a1")
    #expect(await outbox.claim(for: "mac1", by: "fifth", now: 42)?.id == "a1")
    #expect(await outbox.claim(for: "mac1", by: "sixth", now: 100, skipping: ["request:r", "session:s"])?.id == "t1")
    #expect(await outbox.claim(for: "mac1", by: "sixth", now: 100, skipping: ["request:r", "session:s", "session:t"]) == nil)
}

@Test func claimExpiredTakesOnlyWhatNobodyHolds() async throws {
    let (outbox, _) = try temporaryOutbox()
    for id in ["fresh", "held", "free"] {
        try await outbox.enqueue(Outbox.Item(id: id, macID: "mac1", path: "/v1/sessions/\(id)/reply", createdAt: 1, expiresAt: id == "fresh" ? 999 : 5))
    }
    #expect(await outbox.claim(for: "mac1", by: "extension", now: 4, skipping: ["session:fresh", "session:free"])?.id == "held")
    #expect(await outbox.claimExpired(for: "mac1", by: "app", now: 10).map(\.id) == ["free"])
    #expect(await outbox.claimExpired(for: "mac1", by: "app", now: 10).isEmpty, "the first call claimed it")
    #expect(Set(await outbox.claimExpired(for: "mac1", by: "app", now: 41).map(\.id)) == ["held", "free"])
    #expect(await outbox.items(for: "mac1").count == 3)
}

@Test func aStoredRowReadsBackAsItWasWritten() async throws {
    let (outbox, _) = try temporaryOutbox()
    let answer = Outbox.Item.answer(rid, .allow(confirmDestructive: false), macID: "mac1", now: 100)
    let reply = Outbox.Item.reply(sid, RemoteReply(text: "hi"), id: "r", macID: "mac1", now: 100)
    let back = Outbox.Item(id: "\(sid):takeback:1", macID: "mac1", method: "DELETE", path: "/v1/sessions/\(sid)/mail", createdAt: 100, expiresAt: 700)
    for item in [answer, reply, back] { try await outbox.enqueue(item) }
    let stored = await outbox.items(for: "mac1")
    #expect(stored.count == 3 && [answer, reply, back].allSatisfy { stored.contains($0) })
    #expect(answer.target == "request:\(rid)" && reply.target == "session:\(sid)" && back.target == "session:\(sid)")
    #expect(answer.answering == rid && reply.answering == nil && back.answering == nil)
    #expect(await outbox.claim(for: "mac1", by: "o", now: 101)?.id == answer.id)
}
