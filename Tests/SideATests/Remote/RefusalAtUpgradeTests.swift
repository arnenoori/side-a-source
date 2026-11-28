import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

/// Screen off, no Screen Recording permission, a terminal that isn't there: the socket's owner refuses the moment it is
/// handed the socket. The 101 has to reach the phone first, or it reads a WebSocket frame where an HTTP reply should be
/// and reports a Mac it can't reach, instead of the reason.
@Test func anOwnerThatRefusesAtOnceStillGetsItsReasonToThePhone() async throws {
    let keychain = try TestKeychain()
    let token = DeviceToken.make()
    let identity = try #require(try keychain.store.identity())
    let server = RemoteServer(identity: identity, epoch: "e1") { _, _ in HTTPResponse.json(200, Data("{}".utf8)) }
    server.opened = { peer in
        ScreenHub.refuse(peer, .off)
    }
    server.setDevices([(id: "d1", hash: DeviceToken.hash(token))])
    let port = freePort()
    server.serve(addresses: ["127.0.0.1"], port: port)
    defer { server.stop() }
    #expect(await eventually(15) { server.listenerStates.values.first == .ready })

    let phone = PinnedClient(port: port, pin: identity.spkiHash)
    phone.send("GET /v1/ws/events HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
               + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nAuthorization: Bearer \(token)\r\n\r\n")
    let closeFrame = Data([0x88, 5, 0x11, 0x33]) + Data("off".utf8)
    let received = await phone.wait { $0.contains(closeFrame) }
    let text = String(decoding: received, as: UTF8.self)
    #expect(text.hasPrefix("HTTP/1.1 101 Switching Protocols"))
    #expect(text.contains(#""reason":"off""#))
    #expect(try #require(received.range(of: Data(#""reason":"off""#.utf8))).lowerBound < #require(received.range(of: closeFrame)).lowerBound)
}
