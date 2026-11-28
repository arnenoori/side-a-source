import CryptoKit
import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import SideARemoteKit
import Testing

private let conversation = "a06442e2-3f6b-4a35-931a-a4599bfa8acd"
private let hasTmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }

private struct NoCredentials: CredentialStore {
    func token(for macID: String) async throws -> String? { nil }
    func setToken(_ token: String?, for macID: String) async throws {}
}

/// A move between two computers when no address of the other one answers: the one receiving is on the relay as it is
/// for its phones, and the one sending reaches it in a phone's place, with the device and secret the link gave it.
@MainActor @Test(.enabled(if: hasTmux))
func aWholeMoveGoesThroughTheRelayWhenNoAddressOfTheOtherComputerAnswers() async throws {
    let (laptop, mini, _) = try await pair()
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moves-\(UUID().uuidString)")
    let keychain = try TestKeychain()
    let store = AccountStore(demo: true, root: folder)
    store.remote.moves = mini.moves
    // The laptop as the mini keeps it once they're linked: a device with a token and a relay secret of its own.
    let token = DeviceToken.make(), secret = Data(Secret.bytes(32))
    let device = RemoteDevice(id: "laptop", name: "MacBook", model: "Mac", system: "", app: "", build: 1, hash: DeviceToken.hash(token),
                              secretHash: Secret.base64url(Data(SHA256.hash(data: secret))), created: 0, computer: laptop.name)
    try store.remote.devices.add(device, replacing: nil)
    let identity = try #require(try keychain.store.identity())
    let server = RemoteServer(identity: identity, epoch: "e1", handler: RemoteRoutes.handler(store.remote))
    server.setDevices([(id: device.id, hash: device.hash)])
    server.serve(addresses: ["127.0.0.1"], port: freePort(), names: [RemoteController.relayHost])
    server.setTunnel(true)

    // The mini's end of the tunnel, as its Remote settings start it, listing the laptop as a device that may come in.
    let relay = try LocalRelay()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    let tunnel = TunnelClient(base: try await relay.url(), key: Curve25519.Signing.PrivateKey(), session: URLSession(configuration: configuration),
                              register: {}) { [weak server] done in
        guard let server else { return done(nil) }
        server.tunnelPort(done)
    }
    tunnel.setDevices([TunnelControl.Device(id: device.id, secretHash: device.secretHash)])
    tunnel.start()
    do {
        #expect(await eventually { relay.ready })
        // Nothing listens at the one address the laptop has for the mini.
        let endpoint = Endpoint(macID: "mini-\(UUID().uuidString.prefix(8))", baseURL: try #require(URL(string: "https://127.0.0.1:\(freePort())")),
                                serverKeyHash: identity.spkiHash.base64URL, name: "Mac mini",
                                relay: RelayRoute(url: try await relay.url(), installID: "install", deviceID: device.id))
        let computer = LinkedComputer(id: "mini", name: "Mac mini", endpoint: endpoint, token: token, linked: 0, secret: secret)
        let peer = RemotePeer(computer, info: LinkedComputers.client(MacInfo(id: "laptop", name: "MacBook")))

        let session = try await laptop.startSession()
        // Bigger than one piece even packed, so the workspace crosses in several requests, each in many tunnel frames.
        try Data(Secret.bytes(Moves.chunk * 2 + 4321)).write(to: laptop.fixture.project.appendingPathComponent("large.bin"))
        let state = try await laptop.moves.send(session, to: peer)
        #expect(state.status == .live)
        #expect(await eventually { mini.agentAlive })
        #expect(!laptop.agentAlive)
        let landed = try #require(mini.cwd)
        #expect(try Data(contentsOf: URL(fileURLWithPath: landed + "/large.bin")) == Data(contentsOf: laptop.fixture.project.appendingPathComponent("large.bin")))
        #expect(laptop.moves.ownership(of: conversation) == .away(peer: "mini"))
        #expect(mini.moves.ownership(of: conversation) == .here)
        // It went the relay's way, and all of it did.
        #expect(await Paths.shared(for: endpoint, credentials: NoCredentials()).current == .relay)
        #expect(relay.carried > Moves.chunk * 2)
        #expect(try await peer.state(state.id).status == .live)

        // A secret the mini never listed doesn't get through the relay at all.
        let stranger = RemotePeer(LinkedComputer(id: "mini", name: "Mac mini", endpoint: Endpoint(
            macID: "mini-\(UUID().uuidString.prefix(8))", baseURL: endpoint.baseURL, serverKeyHash: endpoint.serverKeyHash, name: "Mac mini", relay: endpoint.relay),
            token: token, linked: 0, secret: Data(Secret.bytes(32))), info: LinkedComputers.client(MacInfo(id: "laptop", name: "MacBook")))
        await #expect(throws: (any Error).self) { _ = try await stranger.state(state.id) }
        #expect(relay.refused > 0)
    } catch { Issue.record(error) }
    tunnel.stop()
    relay.stop()
    server.stop()
    try? FileManager.default.removeItem(at: folder)
    await laptop.cleanUp()
    await mini.cleanUp()
}
