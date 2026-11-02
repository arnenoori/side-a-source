import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

private let sid = "8c1d2f3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f"
private let rid = "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b"

@Test func aSnapshotThenEventsBuildTheState() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    #expect(socket.sent.first == .hello(epoch: nil, lastSeq: nil, capabilities: [.events, .transcriptStream]))
    #expect(socket.request.url?.absoluteString == "wss://100.101.12.4:47800/v1/ws/events")
    #expect(socket.request.value(forHTTPHeaderField: "Authorization") == "Bearer sa1_token")

    try socket.push(fixture: "ServerEvent.welcome")
    try socket.push(fixture: "ServerEvent.snapshot")
    try await until("snapshot") { await sync.state.seq == 41 }
    var state = await sync.state
    #expect(state.connection.isLive && state.epoch == "e5b0c7d2a1f3")
    #expect(state.sessions.count == 2 && state.requests[rid] != nil && state.accounts.count == 1 && state.hosted.count == 1)

    socket.push(42, try fixture("ServerEvent.request-resolve", as: ServerEvent.self))
    socket.push(43, .finishedResolve(sessionID: sid, reason: "replied"))
    socket.push(44, .sessionRemove(id: sid, replacedBy: "new"))
    try await until("events") { await sync.state.seq == 44 }
    state = await sync.state
    #expect(state.requests.isEmpty && state.resolved[rid]?.by == .device && state.finished.isEmpty && state.sessions[sid] == nil)
    // A duplicate is ignored.
    socket.push(44, .hostedRemove(name: "sa-app-3f9c"))
    socket.push(45, .hostedRemove(name: "nothing"))
    try await until("seq 45") { await sync.state.seq == 45 }
    #expect(await sync.state.hosted.count == 1)
    await sync.stop()
}

/// An account removed on the Mac leaves the phone's list at once. A phone from before `account.remove` reads it as
/// an unknown event: it keeps its seq moving and its row, with no reconnect.
@Test func aRemovedAccountLeavesTheList() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    try socket.push(fixture: "ServerEvent.welcome")
    try socket.push(fixture: "ServerEvent.snapshot")
    try await until("snapshot") { await sync.state.seq == 41 }
    let id = try #require(await sync.state.accounts.keys.first)
    // What an older phone makes of account.remove: a type it doesn't know.
    socket.push(42, .unknown(type: "account.archive"))
    try await until("unknown") { await sync.state.seq == 42 }
    #expect(await sync.state.accounts[id] != nil && mac.sockets.count == 1)
    try socket.push(fixture: "ServerEvent.account-remove", seq: 43)
    try await until("removed") { await sync.state.seq == 43 }
    #expect(await sync.state.accounts.isEmpty)
    await sync.stop()
}

@Test func aSkippedEventReconnectsWithLastSeq() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    try first.push(fixture: "ServerEvent.welcome")
    try first.push(fixture: "ServerEvent.snapshot")
    try await until("snapshot") { await sync.state.seq == 41 }
    first.push(43, .hostedRemove(name: "sa-app-3f9c"))
    let second = try await mac.socket(1)
    #expect(first.closedByClient == 1000)
    #expect(second.sent.first == .hello(epoch: "e5b0c7d2a1f3", lastSeq: 41, capabilities: [.events, .transcriptStream]))
    #expect(await sync.state.hosted.count == 1)

    // The server replays from its ring.
    second.push(nil, welcome("e5b0c7d2a1f3", seq: 43, replay: true))
    second.push(42, .finishedResolve(sessionID: sid, reason: "expired"))
    second.push(43, .hostedRemove(name: "sa-app-3f9c"))
    try await until("replay") { await sync.state.seq == 43 }
    let replayed = await sync.state
    #expect(replayed.hosted.isEmpty && replayed.finished.isEmpty)
    await sync.stop()
}

@Test func aNewEpochTakesTheSnapshotWholesale() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    try first.push(fixture: "ServerEvent.welcome")
    try first.push(fixture: "ServerEvent.snapshot")
    try await until("snapshot") { await sync.state.seq == 41 }
    first.serverClose(1001)

    let second = try await mac.socket(1)
    #expect(second.sent.first == .hello(epoch: "e5b0c7d2a1f3", lastSeq: 41, capabilities: [.events, .transcriptStream]))
    // The Mac relaunched: new epoch, seq from 0. Events before the snapshot don't apply.
    second.push(nil, welcome("f00d", seq: 2, replay: false))
    second.push(1, .hostedRemove(name: "sa-app-3f9c"))
    try await until("welcome") { await sync.state.connection.isLive }
    #expect(await sync.state.epoch == "e5b0c7d2a1f3")
    second.push(nil, .snapshot(StateSnapshot(seq: 2, epoch: "f00d")))
    try await until("new epoch") { await sync.state.epoch == "f00d" }
    #expect(await sync.state.seq == 2)
    let state = await sync.state
    #expect(state.seq == 2 && state.sessions.isEmpty && state.requests.isEmpty && state.hosted.isEmpty)
    second.push(3, .hostedRemove(name: "x"))
    try await until("seq 3") { await sync.state.seq == 3 }
    await sync.stop()
}

@Test func closeCodesSetTheConnection() async throws {
    #expect(SyncEngine.next(after: SocketClosed(code: 4401), bye: nil) == .stop(.unpaired))
    #expect(SyncEngine.next(after: SocketClosed(code: 4426, reason: "upgrade_mac"), bye: nil) == .stop(.needsUpdate(mac: true)))
    #expect(SyncEngine.next(after: SocketClosed(code: 4426), bye: nil) == .stop(.needsUpdate(mac: false)))
    #expect(SyncEngine.next(after: SocketClosed(code: 4008), bye: nil) == .now)
    #expect(SyncEngine.next(after: SocketClosed(code: 4429), bye: nil) == .after(10, "Too many connections to the Mac"))
    #expect(SyncEngine.next(after: SocketClosed(code: 1000), bye: nil) == .stop(.idle))
    if case .backoff = SyncEngine.next(after: SocketClosed(code: 4500), bye: nil) {} else { Issue.record("4500 should back off") }

    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    socket.serverClose(4401)
    try await until("unpaired") { await sync.state.connection == .unpaired }
    #expect(mac.sockets.count == 1)

    let none = try engine(FakeMac(), token: nil)
    await none.start()
    try await until("no token") { await none.state.connection == .unpaired }
}

@Test func backoffDoublesToItsCapWithJitter() {
    let timing = SyncTiming()
    #expect((0.4...0.6).contains(timing.backoff(0)) && (0.8...1.2).contains(timing.backoff(1)))
    #expect((24...36).contains(timing.backoff(12)))
}

@Test func presenceAndSubscriptionsFollowEveryWelcome() async throws {
    let mac = FakeMac()
    mac.respond { request in
        guard request.url!.path.hasSuffix("/transcript") else { return .init(status: 404) }
        return .init(body: try! Fixtures.data("TranscriptPage.latest"))
    }
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    try socket.push(fixture: "ServerEvent.welcome")
    try await until("live") { await sync.state.connection.isLive }
    await sync.setViewing(sid)
    let feed = await sync.transcript(sid)
    try await feed.loadLatest()
    try await until("subscribe") { socket.sent.contains(.subscribe(sessions: [sid: Cursor("a41f09c2e7b3.812.1907")])) }
    #expect(socket.sent.contains(.presence(foreground: true, viewing: sid)))

    socket.serverClose(4008)
    let second = try await mac.socket(1)
    second.push(nil, welcome("e5b0c7d2a1f3", seq: 0, replay: true))
    try await until("resubscribe") { second.sent.contains(.subscribe(sessions: [sid: Cursor("a41f09c2e7b3.812.1907")])) && second.sent.contains(.presence(foreground: true, viewing: sid)) }
    await feed.close()
    try await until("unsubscribe") { second.sent.contains(.unsubscribe(sessions: [sid])) }
    await sync.stop()
}

@Test func theMacsOwnStateAndIncidentsFollowEvents() async throws {
    let mac = FakeMac()
    mac.respond { _ in .init(status: 0) }
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    socket.push(nil, welcome("e", seq: 0, replay: false))
    socket.push(nil, try fixture("ServerEvent.snapshot", as: ServerEvent.self))
    try await until("snapshot") { await sync.state.seq == 41 }
    let before = await sync.state
    #expect(before.mac == nil && before.incidents.isEmpty)
    try socket.push(fixture: "ServerEvent.mac-update", seq: 42)
    try socket.push(fixture: "ServerEvent.incident-update", seq: 43)
    try await until("events") { await sync.state.seq == 43 }
    let state = await sync.state
    #expect(state.mac?.battery == 65 && state.mac?.memoryPressure == .warning && state.incidents.first?.status == .resolved)

    let stop = await sync.interrupt(sid, when: .nextStep)
    #expect(String(decoding: stop.body, as: UTF8.self) == #"{"when":"nextStep"}"#)
    #expect(await sync.interrupt(sid).body.isEmpty)
    await sync.stop()
}

@Test func helloDecidesWhetherToConnect() async throws {
    let unpaired = FakeMac()
    var hello = try JSONSerialization.jsonObject(with: Fixtures.data("Hello.paired")) as! [String: Any]
    hello["paired"] = false
    unpaired.hello(.init(body: try JSONSerialization.data(withJSONObject: hello)))
    let a = try engine(unpaired)
    await a.start()
    try await until("unpaired") { await a.state.connection == .unpaired }
    let refused = await a.state
    #expect(unpaired.sockets.isEmpty && refused.hello?.paired == false)

    let old = FakeMac()
    hello["paired"] = true
    hello["minClientBuild"] = 99
    old.hello(.init(body: try JSONSerialization.data(withJSONObject: hello)))
    let b = try engine(old)
    await b.start()
    try await until("needs update") { await b.state.connection == .needsUpdate(mac: false) }

    let newer = FakeMac()
    hello["minClientBuild"] = 1
    hello["maxProtocol"] = 0
    newer.hello(.init(body: try JSONSerialization.data(withJSONObject: hello)))
    let c = try engine(newer)
    await c.start()
    try await until("mac needs update") { await c.state.connection == .needsUpdate(mac: true) }
}

@Test func anUnreachableAddressFallsBackToTheNext() async throws {
    let mac = FakeMac()
    mac.hello(.init(status: 0))
    let sync = try engine(mac)
    await sync.start()
    try await until("both tried") { Set(mac.requests.compactMap { $0.url?.host }) == ["100.101.12.4", "192.168.1.20"] }
    mac.hello(.init(body: try Fixtures.data("Hello.paired")))
    let socket = try await mac.socket(0)
    #expect(socket.request.url?.scheme == "wss" && socket.request.url?.port == 47800)
    await sync.stop()
}

@Test func aNewKeyOnEveryAddressMeansPairAgain() async throws {
    let mac = FakeMac()
    mac.rekeyed(["100.101.12.4", "192.168.1.20"])
    let sync = try engine(mac)
    await sync.start()
    try await until("key changed") { await sync.state.connection == .keyChanged }
    try await Task.sleep(for: .milliseconds(50))
    #expect(mac.requests.isEmpty && mac.sockets.isEmpty)
    #expect(await sync.state.connection == .keyChanged)
}

@Test func aNewKeyOnOneAddressFallsBackToTheNext() async throws {
    let mac = FakeMac()
    mac.rekeyed(["100.101.12.4"])
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    #expect(socket.request.url?.host == "192.168.1.20")
    await sync.stop()
}

@Test func anAddressLearnedFromHelloJoinsTheRotation() async throws {
    let mac = FakeMac()
    var reported = try #require(JSONSerialization.jsonObject(with: Fixtures.data("Hello.paired")) as? [String: Any])
    var endpoints = try #require(reported["endpoints"] as? [String: Any])
    endpoints["lan"] = "10.0.0.9:47800"
    endpoints["lans"] = ["10.0.0.9:47800"]
    reported["endpoints"] = endpoints
    mac.hello(.init(body: try JSONSerialization.data(withJSONObject: reported)))
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    #expect(await sync.endpoint.addresses.contains(URL(string: "https://10.0.0.9:47800")!))
    #expect(await sync.state.endpoint == sync.endpoint)

    // The paired addresses stop answering: the learned one is tried without a relaunch.
    mac.unreachable(["100.101.12.4", "192.168.1.20", "macbook-pro.tail1234.ts.net"])
    first.serverClose(1001)
    let second = try await mac.socket(1)
    #expect(second.request.url?.host == "10.0.0.9")
    await sync.stop()
}

@Test func aLargeSnapshotComesOverREST() async throws {
    let mac = FakeMac()
    let state = try Fixtures.data("StateSnapshot.small")
    mac.respond { request in request.url!.path == "/v1/state" ? .init(body: state) : .init(status: 404) }
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    socket.push(nil, welcome("e5b0c7d2a1f3", seq: 41, replay: false, overREST: true))
    socket.push(42, .hostedRemove(name: "sa-app-3f9c"))
    try await until("events after the REST snapshot") { await sync.state.seq == 42 }
    let after = await sync.state
    #expect(after.sessions.count == 2 && after.hosted.isEmpty && after.hello == hello)
    await sync.stop()
}

@Test func aSliceRefreshNeverMovesSeq() async throws {
    let mac = FakeMac()
    let accounts = json(AccountList(accounts: [], seq: 44))
    mac.respond { request in request.url!.path == "/v1/accounts" ? .init(body: accounts) : .init(status: 404) }
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    try first.push(fixture: "ServerEvent.welcome")
    try first.push(fixture: "ServerEvent.snapshot")
    try await until("snapshot") { await sync.state.seq == 41 }
    first.serverClose(1001)

    // Offline, accounts refresh to seq 44: seq stays at 41.
    try await sync.refreshAccounts()
    var state = await sync.state
    #expect(state.seq == 41 && state.accounts.isEmpty && state.sliceSeq[.accounts] == 44)

    // The replay still applies 42 (another slice) and skips the account events the list already reflects.
    let second = try await mac.socket(1)
    #expect(second.sent.first == .hello(epoch: "e5b0c7d2a1f3", lastSeq: 41, capabilities: [.events, .transcriptStream]))
    second.push(nil, welcome("e5b0c7d2a1f3", seq: 45, replay: true))
    second.push(42, .hostedRemove(name: "sa-app-3f9c"))
    second.push(43, try fixture("ServerEvent.usage-update", as: ServerEvent.self))
    second.push(44, .finishedResolve(sessionID: sid, reason: "expired"))
    second.push(45, try fixture("ServerEvent.usage-update", as: ServerEvent.self))
    try await until("replay") { await sync.state.seq == 45 }
    state = await sync.state
    #expect(state.hosted.isEmpty && state.finished.isEmpty && state.accounts.count == 1)
    await sync.stop()
}
