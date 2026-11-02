import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

private func helloData(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    var hello = try #require(JSONSerialization.jsonObject(with: Fixtures.data("Hello.paired")) as? [String: Any])
    change(&hello)
    return try JSONSerialization.data(withJSONObject: hello)
}

/// What the Mac tells a caller whose token it doesn't know.
private func stranger() throws -> FakeMac.Reply {
    .init(body: try helloData {
        $0["paired"] = false
        $0["mac"] = ["id": "", "name": ""]
        $0["endpoints"] = ["tailnet": ""]
        $0["keyID"] = ""
        $0["capabilities"] = [String]()
    })
}

private func live(_ sync: SyncEngine, _ socket: FakeSocket) async throws {
    socket.push(nil, welcome("e", seq: 0, replay: false))
    try await until("live") { await sync.state.connection.isLive }
}

// MARK: Half-open sockets

@Test func aFailedPongClosesTheSocketAndReconnects() async throws {
    var timing = fastTiming
    timing.ping = 0.01
    let mac = FakeMac()
    let sync = try engine(mac, timing: timing)
    await sync.start()
    let first = try await mac.socket(0)
    try await live(sync, first)
    try await until("pongs") { first.pings > 2 }
    #expect(mac.sockets.count == 1 && first.closedByClient == nil)

    first.failPings(URLError(.timedOut))
    let second = try await mac.socket(1)
    #expect(first.closedByClient == 4008)
    #expect(await !sync.state.connection.isLive)
    try await live(sync, second)
    await sync.stop()
}

@Test func theForegroundAsksALiveSocketToProveIt() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    try await live(sync, first)

    await sync.setForeground(true)
    try await until("a ping") { first.pings == 1 }
    try await Task.sleep(for: .milliseconds(30))
    #expect(mac.sockets.count == 1 && first.closedByClient == nil)

    first.failPings(URLError(.networkConnectionLost))
    await sync.setForeground(true)
    _ = try await mac.socket(1)
    #expect(first.closedByClient == 4008)
    await sync.stop()
}

@Test func aPongFailureFromAnEarlierSocketLeavesTheNewOneAlone() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    try await live(sync, first)
    first.failPings(URLError(.timedOut))
    first.serverClose(1001)
    let second = try await mac.socket(1)
    try await live(sync, second)
    await sync.setForeground(true)
    try await until("a ping") { second.pings == 1 }
    try await Task.sleep(for: .milliseconds(30))
    #expect(await sync.state.connection.isLive && second.closedByClient == nil)
    await sync.stop()
}

// MARK: States that used to be final

@Test func removedComesBackWithTheForeground() async throws {
    let mac = FakeMac()
    mac.hello(try stranger())
    let sync = try engine(mac)
    await sync.start()
    try await until("unpaired") { await sync.state.connection == .unpaired }
    #expect(mac.sockets.isEmpty)

    // Still refused: one more ask, and the same answer.
    let asked = mac.requests.count
    await sync.setForeground(true)
    try await until("asked again") { mac.requests.count > asked }
    try await until("unpaired again") { await sync.state.connection == .unpaired }
    #expect(mac.sockets.isEmpty)

    mac.hello(.init(body: try Fixtures.data("Hello.paired")))
    try await until("loop done") { await sync.state.connection == .unpaired }
    try await Task.sleep(for: .milliseconds(20))
    await sync.setForeground(true)
    try await live(sync, try await mac.socket(0))
    await sync.stop()
}

@Test func aNewKeyComesBackWithTheForeground() async throws {
    let mac = FakeMac()
    mac.rekeyed(["100.101.12.4", "192.168.1.20"])
    let sync = try engine(mac)
    await sync.start()
    try await until("key changed") { await sync.state.connection == .keyChanged }
    mac.rekeyed([])
    await sync.setForeground(true)
    try await live(sync, try await mac.socket(0))
    await sync.stop()
}

@Test func needsUpdateComesBackWithTheForeground() async throws {
    let mac = FakeMac()
    mac.hello(.init(body: try helloData { $0["minClientBuild"] = 99 }))
    let sync = try engine(mac)
    await sync.start()
    try await until("needs update") { await sync.state.connection == .needsUpdate(mac: false) }
    mac.hello(.init(body: try Fixtures.data("Hello.paired")))
    await sync.setForeground(true)
    try await live(sync, try await mac.socket(0))
    await sync.stop()
}

/// A retry with the Mac out of reach proves nothing, so the screen keeps saying what it said until the Mac answers.
@Test func aRetryThatCantReachTheMacDoesntChangeWhatsShown() async throws {
    let mac = FakeMac()
    mac.hello(try stranger())
    let sync = try engine(mac)
    await sync.start()
    try await until("unpaired") { await sync.state.connection == .unpaired }
    try await Task.sleep(for: .milliseconds(20))

    mac.hello(.init(status: 0))
    let seen = Task {
        var shown: [Connection] = []
        for await state in sync.updates {
            shown.append(state.connection)
            if state.connection.isLive { break }
        }
        return shown
    }
    let asked = mac.requests.count
    await sync.setForeground(true)
    try await until("several tries") { mac.requests.count > asked + 3 }
    #expect(await sync.state.connection == .unpaired)

    mac.hello(.init(body: try Fixtures.data("Hello.paired")))
    try await live(sync, try await mac.socket(0))
    let shown = await seen.value
    #expect(shown.allSatisfy { $0 == .unpaired || $0.isLive }, "\(shown)")
    await sync.stop()
}

@Test func aStoppedEngineStaysStopped() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    try await live(sync, try await mac.socket(0))
    await sync.stop()
    let asked = mac.requests.count
    await sync.setForeground(true)
    try await Task.sleep(for: .milliseconds(50))
    #expect(mac.requests.count == asked && mac.sockets.count == 1)
    #expect(await sync.state.connection == .idle)
}

/// A token on a device list the Mac can't read gets 503: an answer, not a removal. Build 11's engine backs off on it too.
@Test func aMacThatCantReadItsDevicesIsntARemoval() async throws {
    let mac = FakeMac()
    let body = Data(#"{"error":{"code":"not_ready","message":"Side A can't read its paired devices right now.","retryable":true}}"#.utf8)
    mac.hello(.init(status: 503, body: body, headers: ["Retry-After": "5"]))
    let sync = try engine(mac)
    await sync.start()
    try await until("several tries") { mac.requests.count > 3 }
    #expect(await sync.state.connection != .unpaired)
    #expect(mac.sockets.isEmpty)

    mac.hello(.init(body: try Fixtures.data("Hello.paired")))
    try await live(sync, try await mac.socket(0))
    await sync.stop()
}

// MARK: Hello

@Test func aHelloThatDoesntKnowThePhoneKeepsItsAddresses() async throws {
    let mac = FakeMac()
    mac.hello(try stranger())
    let sync = try engine(mac)
    await sync.start()
    try await until("unpaired") { await sync.state.connection == .unpaired }
    let state = await sync.state
    #expect(await sync.endpoint == endpoint && state.endpoint == nil && mac.learned.isEmpty)
    #expect(endpoint.updated(with: Endpoints(tailnet: "")) == endpoint)
}

/// 0.5.43 never says `paired: false`: it leaves `paired` out, and the socket is what refuses.
@Test func anOlderMacStillRefusesThroughItsSocket() async throws {
    let mac = FakeMac()
    mac.hello(.init(body: try helloData {
        $0.removeValue(forKey: "paired")
        $0["endpoints"] = ["tailnet": ""]
    }))
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    socket.serverClose(4401)
    try await until("unpaired") { await sync.state.connection == .unpaired }
    #expect(await sync.endpoint == endpoint)
}

@Test func addressesFromATrustedHelloReachTheTransport() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    _ = try await mac.socket(0)
    #expect(mac.learned == [hello.endpoints])
    await sync.stop()
}

// MARK: The relay's refusal

@Test func repeatedRefusalsOfferPairAgainAndAnAnswerTakesItBack() async throws {
    let mac = FakeMac()
    mac.relayRefuses(true)
    let sync = try engine(mac)
    await sync.start()
    try await until("offered") { await sync.state.relayRefused }
    // It's an offer: the phone stays paired and keeps asking.
    #expect(await sync.state.connection != .unpaired)

    mac.relayRefuses(false)
    try await live(sync, try await mac.socket(0))
    #expect(await !sync.state.relayRefused)
    await sync.stop()
}

@Test func anUnreachableMacOffersNothing() async throws {
    #expect(SyncEngine.refusalsToOfferPairing > 1)
    let mac = FakeMac()
    mac.hello(.init(status: 0))
    let sync = try engine(mac)
    await sync.start()
    try await until("several rounds") { mac.requests.count > 8 }
    #expect(await !sync.state.relayRefused)
    await sync.stop()
}

// MARK: Sleep

@Test func aGoodbyeForSleepSaysSoUntilTheMacAnswers() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    try await live(sync, first)

    mac.hello(.init(status: 0))
    first.push(nil, .bye(reason: ServerEvent.byeSleep))
    first.serverClose(1001, ServerEvent.byeSleep)
    try await until("asleep") { await sync.state.macAsleep }
    try await until("down") { await !sync.state.connection.isLive }

    mac.hello(.init(body: try Fixtures.data("Hello.paired")))
    try await live(sync, try await mac.socket(1))
    #expect(await !sync.state.macAsleep)
    await sync.stop()
}

@Test func anyOtherGoodbyeIsntSleep() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    try await live(sync, first)
    mac.hello(.init(status: 0))
    first.push(nil, .bye(reason: "update"))
    first.serverClose(1001, "update")
    try await until("down") { await !sync.state.connection.isLive }
    #expect(await !sync.state.macAsleep)
    await sync.stop()
}

/// The goodbye is a `bye` already on the wire: installed phones read `sleep` as any other reason.
@Test func theSleepGoodbyeIsTheShapeInstalledPhonesRead() throws {
    let event = try JSONDecoder().decode(ServerEvent.self, from: Data(#"{"type":"bye","data":{"reason":"sleep"}}"#.utf8))
    #expect(event == .bye(reason: ServerEvent.byeSleep))
}

// MARK: Test notification

@Test func testPushPostsToTheExistingRouteAndReportsTheRelay() async throws {
    let mac = FakeMac()
    mac.respond { request in
        guard request.httpMethod == "POST", request.url?.path == "/v1/diagnostics/push",
              request.value(forHTTPHeaderField: "Idempotency-Key") != nil else { return .init(status: 404) }
        return .init(body: Data(#"{"id":"diag-1","relay":"unverified"}"#.utf8))
    }
    let client = RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac)
    #expect(try await client.testPush() == DiagnosticPush(id: "diag-1", relay: .unverified))

    mac.respond { _ in .init(status: 503, body: Data(#"{"error":{"code":"relay_unavailable","message":"No relay.","retryable":true}}"#.utf8)) }
    await #expect(throws: RemoteFailure.self) { _ = try await client.testPush() }
}
