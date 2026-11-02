import Foundation
@testable import SideA
import SideACore
import SideARemoteKit
import Testing

/// The phone's own client code (URLSession through PinnedTrust) against the real listener on an IP literal: ATS has
/// to accept a self-signed key on an address with no name, as long as the delegate pins it. Only loopback: from the
/// Mac itself, Network.framework never finishes a handshake to its own Tailscale address (the accepted connection
/// stays preparing on utun), so the tailnet address takes a real phone.
@Test func urlSessionPinnedToTheKeyReachesRESTAndWebSocketOnAnIPAddress() async throws {
    let keychain = try TestKeychain()
    let token = DeviceToken.make()
    let identity = try #require(try keychain.store.identity())
    let server = RemoteServer(identity: identity, epoch: "e1") { request, caller in
        HTTPResponse.json(200, Data(#"{"path":"\#(request.path.joined(separator: "/"))","device":"\#(caller.device ?? "-")"}"#.utf8))
    }
    server.opened = { peer in peer.message = { if case .text(let text) = $0 { peer.send(.text("echo " + text)) } } }
    server.setDevices([(id: "d1", hash: DeviceToken.hash(token))])
    let port = freePort()
    server.serve(addresses: ["127.0.0.1"], port: port)
    defer { server.stop() }
    for _ in 0..<250 where server.listenerStates.values.first != .ready { try await Task.sleep(for: .milliseconds(20)) }
    let pin = identity.spkiHash.base64URL

    let trust = PinnedTrust(.pinned(pin))
    let transport = URLSessionTransport(trust: trust)
    var hello = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/v1/hello")!)
    let (body, response) = try await transport.send(hello)
    #expect(response.statusCode == 200 && response.value(forHTTPHeaderField: "X-SideA-Epoch") == "e1")
    #expect(String(decoding: body, as: UTF8.self).contains(#""device":"-""#))
    // The phone's hash of the key it saw is the one the Mac puts in the QR code.
    #expect(trust.observed == pin)

    var request = URLRequest(url: URL(string: "wss://127.0.0.1:\(port)/v1/ws/events")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let socket = transport.socket(request)
    try await socket.send(.text("hi"))
    #expect(try await socket.receive() == .text("echo hi"))
    socket.close(code: 1000, reason: nil)

    // Pinned to another key, the handshake is cancelled before the token goes out.
    let wrong = URLSessionTransport(trust: PinnedTrust(.pinned(Data(count: 32).base64URL)))
    hello.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    await #expect(throws: (any Error).self) { try await wrong.send(hello) }
    let refused = wrong.socket(request)
    await #expect(throws: (any Error).self) { try await refused.receive() }
}
