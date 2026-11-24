import Foundation
import Network
@testable import SideA
import SideACore
import SideAProtocol
@testable import SideARemoteKit
import Testing

@Suite(.serialized)
struct PathsTests {
    struct Phone: CredentialStore {
        func token(for macID: String) async throws -> String? { "sa1_x" }
        func setToken(_ token: String?, for macID: String) async throws {}
    }

    final class Mac: @unchecked Sendable {
        let keychain: TestKeychain
        let server: RemoteServer
        let pin: String
        let port: UInt16

        init(port: UInt16 = freePort()) throws {
            self.port = port
            keychain = try TestKeychain()
            let identity = try #require(try keychain.store.identity())
            pin = identity.spkiHash.base64URL
            server = RemoteServer(identity: identity, epoch: "e1") { _, _ in HTTPResponse.json(200, Data(#"{"ok":true}"#.utf8)) }
            server.serve(addresses: ["127.0.0.1"], port: port, names: [])
        }

        var url: URL { URL(string: "https://127.0.0.1:\(port)")! }

        func listening() async throws {
            let answered = await eventually {
                (try? await NWTransport(trust: PinnedTrust(.pinned(pin))).send(URLRequest(url: url.appendingPathComponent("v1/hello")), fresh: true)) != nil
            }
            if !answered { Issue.record("the test Mac never answered") }
        }
    }

    final class Silent: @unchecked Sendable {
        let listener: NWListener
        var held: [NWConnection] = []
        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                held.append(connection)
                connection.start(queue: .main)
            }
            listener.start(queue: .main)
        }
        deinit {
            listener.cancel()
            for connection in held { connection.cancel() }
        }

        func url() async throws -> URL {
            for _ in 0..<200 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(5)) }
            return URL(string: "https://127.0.0.1:\(listener.port!.rawValue)")!
        }
    }

    struct Ok: Decodable { let ok: Bool }

    func paths(_ addresses: [URL], pin: String, timing: Paths.Timing = Paths.Timing()) -> (Paths, RemoteClient) {
        let endpoint = Endpoint(macID: "mac", baseURL: addresses[0], alternates: Array(addresses.dropFirst()), serverKeyHash: pin, name: "Mac")
        let paths = Paths(endpoint: endpoint, timing: timing, monitorNetwork: false)
        return (paths, RemoteClient(endpoint: endpoint, credentials: Phone(), transport: RoutedTransport(paths: paths)))
    }

    @Test func aWinnerDoesntWaitForAnAddressThatHangs() async throws {
        let mac = try Mac()
        defer { mac.server.stop() }
        try await mac.listening()
        let silent = try Silent()
        var timing = Paths.Timing()
        timing.directTimeout = 30
        let (paths, _) = paths([try await silent.url(), mac.url], pin: mac.pin, timing: timing)
        let start = ContinuousClock.now
        #expect(await paths.path() == .direct(mac.url))
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func aNewConnectionLogsWhereItsTimeWent() async throws {
        let mac = try Mac()
        defer { mac.server.stop() }
        let lines = Lines()
        KitLog.sink = { _, line in lines.add(line) }
        defer { KitLog.sink = nil }
        try await mac.listening()
        let connected = try await lines.first { $0.hasPrefix("connected ") }
        print("KITLOG \(connected)")
        #expect(connected.contains("tcp ") && connected.contains("tls ") && connected.contains("ms in all"))

        var post = URLRequest(url: mac.url.appendingPathComponent("v1/answer"))
        post.httpMethod = "POST"
        post.httpBody = Data("{}".utf8)
        _ = try await NWTransport(trust: PinnedTrust(.pinned(mac.pin))).send(post, fresh: true)
        _ = try await lines.first { $0.hasPrefix("connected POST ") && $0.contains("/v1/answer") }
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ line: String) { lock.withLock { all.append(line) } }
        func count(_ matches: (String) -> Bool) -> Int { lock.withLock { all.count(where: matches) } }
        func first(_ matches: (String) -> Bool) async throws -> String {
            var found: String?
            await eventually { found = lock.withLock { all.first(where: matches) }; return found != nil }
            guard let found else { throw CancellationError() }
            return found
        }
    }

    @Test func aStaleAddressWithAnotherKeyIsntAKeyChange() async throws {
        let mac = try Mac()
        let stranger = try Mac()
        defer { mac.server.stop(); stranger.server.stop() }
        try await stranger.listening()
        let silent = try Silent()
        mac.server.stop()
        let (_, client) = paths([stranger.url, try await silent.url()], pin: mac.pin)
        await #expect(throws: URLError.self) { let _: Ok = try await client.get("/v1/hello") }

        var timing = Paths.Timing()
        timing.directTimeout = 30
        let (_, rekeyed) = paths([stranger.url], pin: mac.pin, timing: timing)
        await #expect(throws: ServerKeyChanged.self) { let _: Ok = try await rekeyed.get("/v1/hello") }
    }

    func refusing() -> URL { URL(string: "https://127.0.0.1:\(freePort())")! }

    func trying(_ ports: [UInt16]) -> Paths.Timing {
        var timing = Paths.Timing()
        timing.directTimeout = 30
        timing.siblingPorts = { _ in ports.map(Int.init) }
        return timing
    }

    @Test func theRelayIsCheckedWhicheverPathWon() async throws {
        let mac = try Mac()
        defer { mac.server.stop() }
        try await mac.listening()
        let (direct, _) = paths([mac.url], pin: mac.pin)
        #expect(await direct.checkRelay() == .notSetUp)

        let relay = RelayRoute(url: URL(string: "http://127.0.0.1:\(freePort())")!, installID: "i1", deviceID: "d1")
        let endpoint = Endpoint(macID: "mac", baseURL: mac.url, serverKeyHash: mac.pin, name: "Mac", relay: relay)
        let paths = Paths(endpoint: endpoint, monitorNetwork: false, authorization: { "Bearer d1.i1.d1.x" })
        #expect(await paths.path() == .direct(mac.url))
        guard case .failed = await paths.checkRelay() else { Issue.record("a relay that isn't there passed"); return }
        #expect(await paths.current == .direct(mac.url))
    }

    @Test func theForegroundRacesTheRelayAgain() async throws {
        let lines = Lines()
        KitLog.sink = { _, line in lines.add(line) }
        defer { KitLog.sink = nil }
        let relay = RelayRoute(url: URL(string: "http://127.0.0.1:\(freePort())")!, installID: "i1", deviceID: "d1")
        let endpoint = Endpoint(macID: "mac", baseURL: refusing(), serverKeyHash: "pin", name: "Mac", relay: relay)
        let paths = Paths(endpoint: endpoint, monitorNetwork: false, authorization: { "Bearer d1.i1.d1.x" })
        #expect(await paths.path() == nil)
        _ = try await lines.first { $0.hasPrefix("relay didn't answer; skipping it for 5 s") }
        let before = lines.count { $0.hasPrefix("race ") && $0.contains(", relay:") }
        await paths.foreground()
        #expect(lines.count { $0.hasPrefix("race ") && $0.contains(", relay:") } == before + 1)
        let unreachable = await paths.unreachable as NSError
        #expect(unreachable.localizedDescription == "Can't reach Mac right now. It may be asleep, or Side A may be closed.")
        let why = unreachable.localizedFailureReason ?? ""
        #expect(why.contains("Local network: nothing listening") && why.contains("Relay: "))
    }

    @Test func noPathSaysWhyForEachWayIn() {
        let tailnet = Paths.Path.direct(URL(string: "https://100.93.122.83:47800")!)
        let name = Paths.Path.direct(URL(string: "https://mac.tail07.ts.net:47800")!)
        let lan = Paths.Path.direct(URL(string: "https://192.168.1.20:47800")!)
        #expect(Paths.explain([tailnet: URLError(.timedOut), name: URLError(.timedOut), lan: URLError(.timedOut)],
                              relay: .open(mac: false), relayResting: false)
                == "Tailscale: no answer. Local network: no answer. Relay: the Mac isn't connected.")
        #expect(Paths.explain([tailnet: URLError(.timedOut)], relay: .failed("The relay didn't answer"), relayResting: true)
                == "Tailscale: no answer. Relay: the relay didn't answer.")
        #expect(Paths.explain([tailnet: URLError(.timedOut)], relay: .idle, relayResting: true) == "Tailscale: no answer. Relay: no answer.")
        #expect(Paths.explain([tailnet: URLError(.timedOut)], relay: nil, relayResting: false) == "Tailscale: no answer.")
        #expect(Paths.explain([:], relay: nil, relayResting: false).isEmpty)
    }

    /// iOS takes a suspended app's listening socket: the proxy listens again on a port the next dial finds.
    @Test func theRelayProxyListensAgain() async throws {
        let bridge = RelayBridge(route: RelayRoute(url: URL(string: "http://127.0.0.1:\(freePort())")!, installID: "i1"), authorization: { nil })
        let first = try await bridge.port()
        #expect(bridge.listeningPort == first)
        bridge.relisten()
        let second = try await bridge.port()
        #expect(second != 0 && bridge.listeningPort == second)
    }

    @Test func theMacsMovePortsAreItsOwnBuildsOnly() {
        #expect(Paths.siblingPorts(of: 47800) == Array(47801...47809))
        #expect(Paths.siblingPorts(of: 47905) == [47900, 47901, 47902, 47903, 47904, 47906, 47907, 47908, 47909])
        #expect(Paths.siblingPorts(of: 51000).isEmpty && Paths.siblingPorts(of: 47810).isEmpty)
    }

    @Test func aRelayThatFailsWhileTheNetworkSettlesDoesntRest() {
        #expect(Paths.relayRests(after: URLError(.timedOut), settling: true) == false)
        #expect(Paths.relayRests(after: URLError(.networkConnectionLost), settling: true) == false)
        #expect(Paths.relayRests(after: URLError(.timedOut), settling: false))
        #expect(Paths.relayRests(after: URLError(.secureConnectionFailed), settling: false))
        #expect(Paths.relayRests(after: URLError(.cancelled), settling: false) == false)
        #expect(Paths.relayRests(after: CancellationError(), settling: false) == false)
    }

    @Test func aHostThatRefusesIsTriedOnItsSiblingPorts() async throws {
        let mac = try Mac()
        defer { mac.server.stop() }
        try await mac.listening()
        let (paths, client) = paths([refusing()], pin: mac.pin, timing: trying([mac.port]))
        #expect(await paths.path() == .direct(mac.url))
        let ok: Ok = try await client.get("/v1/hello")
        #expect(ok.ok)
    }

    @Test func aSiblingPortWithAnotherKeyReadsAsANewKey() async throws {
        let mac = try Mac()
        let stranger = try Mac()
        defer { mac.server.stop(); stranger.server.stop() }
        try await stranger.listening()
        let (_, client) = paths([refusing()], pin: mac.pin, timing: trying([stranger.port]))
        await #expect(throws: ServerKeyChanged.self) { let _: Ok = try await client.get("/v1/hello") }
    }

    @Test func aHostWithNothingOnAnyPortStaysUnreachable() async throws {
        let mac = try Mac()
        defer { mac.server.stop() }
        let (paths, client) = paths([refusing()], pin: mac.pin, timing: trying([freePort(), freePort()]))
        #expect(await paths.path() == nil)
        await #expect(throws: URLError.self) { let _: Ok = try await client.get("/v1/hello") }
    }

    @Test func anAddressThatOnlyTimesOutIsntScanned() async throws {
        let mac = try Mac()
        defer { mac.server.stop() }
        let silent = try Silent()
        let scanned = Lines()
        var timing = Paths.Timing()
        timing.directTimeout = 0.2
        timing.siblingPorts = { _ in scanned.add("scanned"); return [] }
        let (paths, _) = paths([try await silent.url()], pin: mac.pin, timing: timing)
        #expect(await paths.path() == nil)
        await #expect(throws: CancellationError.self) { _ = try await scanned.first { _ in true } }
    }

    @Test func aRetestRacesThroughTheQuietWindow() async throws {
        let mac = try Mac()
        defer { mac.server.stop() }
        try await mac.listening()
        let (paths, client) = paths([refusing()], pin: mac.pin)
        #expect(await paths.path() == nil)
        await client.transport.learned(Endpoints(tailnet: "127.0.0.1:\(mac.port)"))
        #expect(await paths.path() == nil)
        #expect(await paths.retest() == .direct(mac.url))
    }

    @Test func addressesFromAHelloJoinTheNextRace() async throws {
        let mac = try Mac()
        defer { mac.server.stop() }
        try await mac.listening()
        let (paths, client) = paths([refusing()], pin: mac.pin)
        #expect(await paths.path() == nil)
        await client.transport.learned(Endpoints(tailnet: "127.0.0.1:\(mac.port)"))
        await paths.foreground()
        #expect(await paths.path() == .direct(mac.url))
    }
}
