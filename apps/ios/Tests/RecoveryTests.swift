import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import UserNotifications
import XCTest
@testable import SideARemote

@MainActor
final class RecoveryTests: XCTestCase {
    private func down(_ apply: (inout RemoteState) -> Void = { _ in }) -> RemoteState {
        var state = RemoteState()
        state.connection = .offline(retryAt: 0, reason: "closed")
        apply(&state)
        return state
    }

    private func stale() -> MacConnection { MacConnection(name: "Studio", state: .connecting, lastSeen: .now) }

    // MARK: What the offline screen says

    func testTailscaleOffOnlyWithNoRelayToReachTheMacAnyway() {
        let mac = stale()
        mac.vpnUp = false
        mac.state = .offline(.macUnreachable)
        mac.apply(down(), name: "Studio", onTailnet: true, hasRelay: false)
        XCTAssertEqual(mac.state, .offline(.tailscaleOff))
        mac.apply(down(), name: "Studio", onTailnet: true, hasRelay: true)
        XCTAssertEqual(mac.state, .offline(.macUnreachable))
    }

    func testAGoodbyeForSleepSaysAsleepAtOnceAndGoesWhenLive() {
        let mac = stale()
        mac.state = .live
        mac.apply(down { $0.macAsleep = true }, name: "Studio")
        XCTAssertEqual(mac.state, .offline(.macAsleep))
        XCTAssertEqual(MacConnection.Offline.macAsleep.message(mac: "Studio"), "Studio is asleep")
        XCTAssertFalse(MacConnection.Offline.macAsleep.offersPairAgain)
        var live = RemoteState()
        live.connection = .live(since: 1)
        mac.apply(live, name: "Studio")
        XCTAssertEqual(mac.state, .live)
    }

    func testRepeatedRelayRefusalsOfferPairAgainWithoutEndingThePairing() {
        let mac = stale()
        mac.apply(down { $0.relayRefused = true }, name: "Studio")
        XCTAssertEqual(mac.state, .offline(.relayRefused))
        XCTAssertTrue(MacConnection.Offline.relayRefused.offersPairAgain)
        XCTAssertFalse(MacConnection.Offline.relayRefused.needsPairing)
        XCTAssertTrue(MacConnection.Offline.relayRefused.message(mac: "Studio").contains("pair it again"))
    }

    func testPairAgainIsOfferedWhereItCouldHelp() {
        XCTAssertTrue(MacConnection.Offline.macUnreachable.offersPairAgain)
        XCTAssertTrue(MacConnection.Offline.tailscaleOff.offersPairAgain)
        XCTAssertFalse(MacConnection.Offline.appOutdated.offersPairAgain)
        XCTAssertFalse(MacConnection.Offline.incompatible(installed: "0.5.43").offersPairAgain)
    }

    func testAnOldMacIsToldWhatsInstalledNotAMadeUpVersion() throws {
        let mac = stale()
        var state = RemoteState()
        state.connection = .needsUpdate(mac: true)
        mac.apply(state, name: "Studio")
        XCTAssertEqual(mac.state, .offline(.incompatible(installed: nil)))
        XCTAssertEqual(MacConnection.Offline.incompatible(installed: nil).message(mac: "Studio"), "Update Side A on Studio to use it with this iPhone")

        state.hello = Hello(app: "0.5.43", build: 1, mac: MacInfo(id: "m", name: "Studio"), capabilities: [], epoch: "e", serverTime: 0,
                            endpoints: Endpoints(tailnet: "x"), keyID: "k")
        mac.apply(state, name: "Studio")
        XCTAssertEqual(mac.state, .offline(.incompatible(installed: "0.5.43")))
        let message = MacConnection.Offline.incompatible(installed: "0.5.43").message(mac: "Studio")
        XCTAssertTrue(message.contains("0.5.43"))
        XCTAssertFalse(message.contains("0.6"))
    }

    // MARK: Reply retry

    private final class Silent: Transport, @unchecked Sendable {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
        func socket(_ request: URLRequest) -> any SocketConnection { fatalError("no socket") }
    }

    private func outbox() throws -> Outbox {
        try Outbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString).sqlite"))
    }

    private let endpoint = Endpoint(macID: "recovery", baseURL: URL(string: "https://100.64.0.9:47800")!, serverKeyHash: "k", name: "Studio")

    private func replies(_ outbox: Outbox) async -> [RemoteReply] {
        await outbox.items(for: "recovery").compactMap { try? JSONDecoder().decode(RemoteReply.self, from: $0.body) }
    }

    private func wait(_ outbox: Outbox, for count: Int) async throws {
        for _ in 0..<200 {
            if await outbox.items(for: "recovery").count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the outbox never had \(count)")
    }

    /// An item the engine no longer holds goes fresh, which used to send plain text as `auto`.
    func testARetrySentFreshKeepsWhatTheReplyCarried() async throws {
        let outbox = try outbox()
        let link = LiveLink(mac: PairedMac(endpoint: endpoint, deviceID: "d", deviceName: "iPhone"), outbox: outbox, transport: Silent())
        link.reply("hello", turn: "t1", to: "s1", mode: .note, submit: .steer, resending: ["up1", "up2"])
        try await wait(outbox, for: 1)
        let items = await outbox.items(for: "recovery")
        let item = try XCTUnwrap(items.first).id

        link.retry(item: item, text: "hello", turn: "t2", session: "s1")
        try await wait(outbox, for: 2)
        let sent = await replies(outbox)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.mode, .note)
        XCTAssertEqual(sent.last?.submit, .steer)
        XCTAssertEqual(sent.last?.attachments, ["up1", "up2"])
        XCTAssertEqual(sent.last?.text, "hello")
    }

    func testARetryOfAnItemItKnowsNothingAboutSendsPlainAuto() async throws {
        let outbox = try outbox()
        let link = LiveLink(mac: PairedMac(endpoint: endpoint, deviceID: "d", deviceName: "iPhone"), outbox: outbox, transport: Silent())
        link.retry(item: "gone", text: "hello", turn: "t1", session: "s1")
        try await wait(outbox, for: 1)
        let sent = await replies(outbox)
        XCTAssertEqual(sent.first?.mode, .auto)
        XCTAssertEqual(sent.first?.attachments, [])
    }

    // MARK: Push

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { list.append(request) } }
        var all: [URLRequest] { lock.withLock { list } }
    }

    private func paired(_ id: String, relay: Bool) -> PairedMac {
        PairedMac(endpoint: Endpoint(macID: id, baseURL: URL(string: "https://100.64.0.1:47800")!, serverKeyHash: "k", name: id), deviceID: "d-\(id)",
                  deviceName: "iPhone", relayInstallID: relay ? "i-\(id)" : nil, relayURL: relay ? "https://relay.example" : nil)
    }

    func testANewTokenGoesToEachRelayWithItsRoute() async throws {
        let keychain = SharedKeychain.shared
        defer { for id in ["r1", "r2"] { keychain.set(nil, for: "secret.\(id)") } }
        keychain.set(Data([1, 2, 3]), for: "secret.r1")
        keychain.set(Data([4, 5, 6]), for: "secret.r2")
        let seen = Requests()
        let reached = await RelayDevice.report(token: "aabb", bundleID: "com.arnenoori.sidea.remote.dev", environment: .sandbox,
                                               macs: [paired("r1", relay: true), paired("none", relay: false), paired("r2", relay: true)]) { request in
            seen.add(request)
            return 200
        }
        XCTAssertTrue(reached)
        XCTAssertEqual(seen.all.count, 2)
        let request = try XCTUnwrap(seen.all.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/v1/device/tokens")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer d1.i-r1.d-r1.AQID")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["apnsToken": "aabb", "bundleID": "com.arnenoori.sidea.remote.dev", "apnsEnvironment": "sandbox"])
    }

    func testARelayOutOfReachLeavesTheTokenOwedAndARefusalDoesnt() async {
        let keychain = SharedKeychain.shared
        defer { keychain.set(nil, for: "secret.r1") }
        keychain.set(Data([1]), for: "secret.r1")
        let mac = paired("r1", relay: true)
        let unreached = await RelayDevice.report(token: "aa", bundleID: "b", environment: .production, macs: [mac]) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertFalse(unreached)
        let refused = await RelayDevice.report(token: "aa", bundleID: "b", environment: .production, macs: [mac]) { _ in 401 }
        XCTAssertTrue(refused)
    }

    func testAMacWithoutACredentialIsSkipped() async {
        let seen = Requests()
        let reached = await RelayDevice.report(token: "aa", bundleID: "b", environment: .production, macs: [paired("nosecret", relay: true)]) { request in
            seen.add(request)
            return 200
        }
        XCTAssertTrue(reached)
        XCTAssertTrue(seen.all.isEmpty)
    }

    func testOnlyDeniedNotificationsOfferSettings() {
        XCTAssertTrue(NotificationsCard.offersSettings(.denied))
        for status: UNAuthorizationStatus in [.authorized, .notDetermined, .provisional, .ephemeral] {
            XCTAssertFalse(NotificationsCard.offersSettings(status))
        }
    }

    func testATestNotificationSaysWhatTheRelayDid() {
        XCTAssertEqual(ConnectionTest.testNotification(.ok, mac: "Studio"), .passed("Test notification sent"))
        for relay: DiagnosticPush.Relay in [.unverified, .gone, .retry, .unreachable, .rejected, DiagnosticPush.Relay(rawValue: "new")] {
            guard case .failed = ConnectionTest.testNotification(relay, mac: "Studio") else { return XCTFail("\(relay)") }
        }
    }
}
