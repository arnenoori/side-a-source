import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

// The transitions of `SyncEngine` and its outbox, one test per row of docs/remote/sync-state-machine.md. Tests that
// already pinned a row elsewhere are named in the table instead of repeated here.

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

// MARK: Start, hello, welcome

/// Row C1: idle -> connecting while the Mac hasn't answered hello; the hello and the address that answered are kept
/// before the socket opens; the welcome makes it live.
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

/// Row C2: a welcome that continues the epoch (`replay`) takes events at once; one that doesn't waits for a snapshot,
/// and so does one for another epoch even when it says replay.
@Test func aWelcomeThatCannotReplayHoldsEventsUntilTheSnapshot() async throws {
    let mac = FakeMac()
    let (sync, first) = try await snapshotLive(mac)
    first.serverClose(1001)

    // Same epoch, no replay: the events before the snapshot belong to a state the phone doesn't hold.
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

    // Another epoch that claims a replay is still a new world.
    let third = try await mac.socket(2)
    third.push(nil, welcome("other", seq: 52, replay: true))
    third.push(51, .hostedRemove(name: "x"))
    try await until("live again") { await sync.state.connection.isLive }
    try await Task.sleep(for: .milliseconds(30))
    state = await sync.state
    #expect(state.seq == 50 && state.epoch == "e5b0c7d2a1f3")
    await sync.stop()
}

/// Row C3: the first event after a snapshot must be the next seq; one behind is ignored, one ahead reconnects.
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

// MARK: Snapshots over REST

/// Row S1: `refresh()` takes a snapshot of its own epoch only when the stream isn't further along, and one of another
/// epoch always, since seq starts again there.
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

/// Row S2: each slice refreshes only when its list is newer than both `seq` and that slice's last refresh; a snapshot
/// forgets what the slices knew. Only requests and accounts are refreshed over REST.
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

    // Events a slice already reflects move seq and change nothing.
    socket.push(42, .requestAdd(try fixture("RemoteRequest.bash", as: RemoteRequest.self)))
    try await until("42") { await sync.state.seq == 42 }
    #expect(await sync.state.requests.isEmpty)

    // A slice no one refreshes over REST has no sliceSeq: its events apply.
    socket.push(43, .sessionRemove(id: sid, replacedBy: nil))
    try await until("43") { await sync.state.seq == 43 }
    #expect(await sync.state.sessions.count == 1)

    // A snapshot starts the slices over.
    socket.push(nil, .snapshot(StateSnapshot(seq: 47, epoch: "e5b0c7d2a1f3")))
    try await until("snapshot") { await sync.state.seq == 47 }
    #expect(await sync.state.sliceSeq.isEmpty)
    await sync.stop()
}

// MARK: Revoked, key, updates

/// Row C4: a socket close for a revoked token ends the run but keeps the last state on screen; only a foreground
/// (or a reconnect request) asks the Mac again.
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

/// Row C5: a 401 on hello (a Mac that checks the token there) isn't a removal: it is one more failed attempt.
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

/// Row C6: the Mac too old for this phone keeps being asked, every `updateCheck`, and keeps saying so in between;
/// the phone too old for the Mac asks nothing until it is told to.
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

/// Row C7: a Mac that refuses through its socket says the same, for either side.
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
    // The Mac's side is asked again by itself, and this time it answers.
    _ = try await mac.socket(2)
    await sync.stop()
}

// MARK: Waits

/// Row C8: too many connections waits ten seconds with its own reason, and a foreground or network change skips the wait.
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

/// Row C9: a goodbye that isn't sleep, and a plain close, wait with the Mac's words or a code.
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

/// Row C10: three reconnects in a row that ask for no wait, then the backoff, with the reason saying why.
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

/// Row C11: a frame with a seq that isn't next, or that arrives while a snapshot is awaited, and doesn't decode,
/// changes nothing and asks for nothing.
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

// MARK: Stop, foreground

/// Row C12: stop() closes the socket normally, leaves the last state on screen, and nothing starts again by itself.
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
    // A later start() begins a new run from the held seq.
    await sync.start()
    let again = try await mac.socket(1)
    #expect(again.sent.first == .hello(epoch: "e5b0c7d2a1f3", lastSeq: 41, capabilities: [.events, .transcriptStream]))
    await sync.stop()
}

/// Row C13: going to the background sends presence and nothing else; the socket stays, and no ping goes out.
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

/// Row C14: coming forward while the loop waits out a backoff skips the wait.
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

// MARK: The flags that sit beside the connection

/// Row F1: what is known about why the Mac can't be reached is one value of the down connection. A sleep goodbye then a
/// relay's refusals leave it asleep, and it stays shown through the attempts in between instead of reading connecting.
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
    // Rounds of refusals: enough of them for the relay's own offer, which doesn't replace the sleep.
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

/// Row F2: a hello that answers takes the cause off the down connection at once, before the welcome.
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

/// Row F3: a terminal state doesn't take the sleep flag away, and doesn't get an offline wait over it.
@Test func aTerminalStateIsNotReplacedByTheWaitsThatFollow() async throws {
    let mac = FakeMac()
    mac.rekeyed(["100.101.12.4", "192.168.1.20"])
    let sync = try engine(mac)
    await sync.start()
    try await until("key changed") { await sync.state.connection == .keyChanged }
    #expect(mac.sockets.isEmpty)
    await sync.stop()
}

// MARK: Outbox through the engine

/// Row O1: an item another process holds blocks its own target, not the others; it is sent by nobody here meanwhile.
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

/// Row O2: a retryable failure records the attempt and the error on the stored item and gives it back; the next
/// attempt is the same item under the same key.
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

/// Row O3: a network error is retried like a retryable refusal; both end at `expiresAt` as Not delivered, and the
/// tapped Retry then sends a new key.
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

/// Row O4: a 401 that isn't about a signature gives the item back, ends the run and says unpaired.
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

// MARK: The outbox itself

/// Row O5: claims. Answers before everything, then oldest first per target; an owner may claim again what it holds; a
/// fresh claim by another blocks that target; a lapsed one doesn't; a release frees it at once.
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
    // a1 is held, so a2 waits behind it; another process takes the oldest of the other targets.
    #expect(await outbox.claim(for: "mac1", by: "other", now: 10)?.id == "s1")
    #expect(await outbox.claim(for: "mac1", by: "third", now: 10)?.id == "t1")
    #expect(await outbox.claim(for: "mac1", by: "fourth", now: 10) == nil, "s2 and a2 wait behind claimed items")
    // The owner claims what it holds again; a claim that lapsed, or was released, is anyone's.
    #expect(await outbox.claim(for: "mac1", by: "app", now: 10)?.id == "a1")
    #expect(await outbox.claim(for: "mac1", by: "fourth", now: 41)?.id == "a1")
    await outbox.release("a1")
    #expect(await outbox.claim(for: "mac1", by: "fifth", now: 42)?.id == "a1")
    // A target in `held` is skipped, with the items behind it.
    #expect(await outbox.claim(for: "mac1", by: "sixth", now: 100, skipping: ["request:r", "session:s"])?.id == "t1")
    #expect(await outbox.claim(for: "mac1", by: "sixth", now: 100, skipping: ["request:r", "session:s", "session:t"]) == nil)
}

/// Row O6: an expired item is claimable for settling only when nobody holds it, and settling claims it.
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

/// Row O7: the stored form of an item is its JSON, and its target and answer column come from its path: rows written
/// by an older build read back the same.
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
