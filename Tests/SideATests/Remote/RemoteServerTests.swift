import CryptoKit
import Foundation
import Network
import os
@testable import SideA
import SideACore
import SideAProtocol
import Testing

private func makeServer(_ keychain: TestKeychain, token: String) throws -> (RemoteServer, UInt16, Data) {
    let identity = try #require(try keychain.store.identity())
    let server = RemoteServer(identity: identity, epoch: "e1") { request, caller in
        HTTPResponse.json(200, Data(#"{"path":"\#(request.path.joined(separator: "/"))","device":"\#(caller.device ?? "-")"}"#.utf8))
    }
    server.opened = { peer in
        peer.message = { message in if case .text(let text) = message { peer.send(.text("echo " + text)) } }
    }
    server.setDevices([(id: "d1", hash: DeviceToken.hash(token))])
    let port = freePort()
    server.serve(addresses: ["127.0.0.1"], port: port)
    return (server, port, identity.spkiHash)
}

/// Up to 15 s: the listener's TLS identity comes from a test keychain that every Remote test reaches at once.
private func ready(_ server: RemoteServer) async {
    for _ in 0..<750 where server.listenerStates.values.first != .ready { try? await Task.sleep(for: .milliseconds(20)) }
}

@Test func servesOverPinnedTLSWithTokensHostChecksAndKeepAlive() async throws {
    let keychain = try TestKeychain()
    let token = DeviceToken.make()
    let (server, port, pin) = try makeServer(keychain, token: token)
    defer { server.stop() }
    await ready(server)
    let host = "Host: 127.0.0.1:\(port)\r\n"

    let client = PinnedClient(port: port, pin: pin)
    client.send("GET /v1/hello HTTP/1.1\r\n\(host)\r\nGET /v1/sessions HTTP/1.1\r\n\(host)Authorization: Bearer \(token)\r\nConnection: close\r\n\r\n")
    let both = await client.text(until: "\"device\":\"d1\"")
    // Two requests on one connection, answered in order.
    #expect(both.components(separatedBy: "HTTP/1.1 200 OK").count == 3)
    #expect(both.contains(#""path":"v1/hello","device":"-""#) && both.contains("X-SideA-Epoch: e1"))

    for (request, status) in [("GET /v1/sessions HTTP/1.1\r\n\(host)\r\n", "401 Unauthorized"),
                              ("GET /v1/sessions HTTP/1.1\r\n\(host)Authorization: Bearer sa1_wrong\r\n\r\n", "401 Unauthorized"),
                              ("GET /v1/hello HTTP/1.1\r\nHost: evil.example:\(port)\r\n\r\n", "421 Misdirected Request"),
                              ("GET /v1/hello HTTP/1.1\r\n\(host)Origin: http://x\r\n\r\n", "403 Forbidden"),
                              ("POST /v1/requests/r/answer HTTP/1.1\r\n\(host)Authorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n", "400 Bad Request")] {
        let one = PinnedClient(port: port, pin: pin)
        one.send(request)
        let text = await one.text(until: "\r\n\r\n")
        #expect(text.hasPrefix("HTTP/1.1 \(status)"), "\(request) → \(text)")
        if status.hasPrefix("401") { #expect(text.contains("WWW-Authenticate: Bearer")) }
        one.close()
    }

    // A phone pinned to another key never gets as far as sending its token.
    let wrongPin = PinnedClient(port: port, pin: Data(count: 32))
    wrongPin.send("GET /v1/hello HTTP/1.1\r\n\(host)\r\n")
    #expect(await wrongPin.wait { !$0.isEmpty }.isEmpty)
}

@Test func webSocketsNeedATokenAndCloseWhenRevoked() async throws {
    let keychain = try TestKeychain()
    let token = DeviceToken.make()
    let (server, port, pin) = try makeServer(keychain, token: token)
    defer { server.stop() }
    await ready(server)
    let upgrade = "GET /v1/ws/events HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"

    let stranger = PinnedClient(port: port, pin: pin)
    stranger.send(upgrade + "\r\n")
    #expect(await stranger.text(until: "\r\n\r\n").hasPrefix("HTTP/1.1 401"))

    let phone = PinnedClient(port: port, pin: pin)
    // The first frame rides in the same packet as the upgrade.
    phone.send(Data((upgrade + "Authorization: Bearer \(token)\r\n\r\n").utf8) + maskedFrame(1, Data("hi".utf8)))
    let echoed = await phone.wait { $0.firstRange(of: Data("echo hi".utf8)) != nil }
    #expect(String(decoding: echoed, as: UTF8.self).hasPrefix("HTTP/1.1 101 Switching Protocols"))
    #expect(echoed.suffix(9) == Data([0x81, 7]) + Data("echo hi".utf8))
    #expect(String(decoding: echoed, as: UTF8.self).contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
    server.revoke("d1")
    let closed = await phone.wait { $0.firstRange(of: Data([0x88, 0x09, 0x11, 0x31])) != nil }
    #expect(closed.firstRange(of: Data([0x88, 0x09, 0x11, 0x31])) != nil, "\(Array(closed.suffix(30)))")
}

/// The header is only a courtesy to an old phone: what stops a token alone is the signature each route asks for.
@Test func aPhoneTooOldToSignIsToldToUpdate() async throws {
    let keychain = try TestKeychain()
    let token = DeviceToken.make()
    let (server, port, pin) = try makeServer(keychain, token: token)
    defer { server.stop() }
    await ready(server)
    let head = "Host: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n"
    let old = "X-SideA-Client: SideARemote/1.0 (\(RemotePolicy.minClientBuild - 1); iOS 26.0)\r\n"
    let new = "X-SideA-Client: SideARemote/1.0 (\(RemotePolicy.minClientBuild); iOS 26.0)\r\n"
    let ws = "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    for (request, status) in [("GET /v1/sessions HTTP/1.1\r\n\(head)\(old)\r\n", "426"),
                              ("POST /v1/sessions/s/reply HTTP/1.1\r\n\(head)\(old)Content-Length: 0\r\n\r\n", "426"),
                              ("GET /v1/ws/events HTTP/1.1\r\n\(head)\(old)\(ws)\r\n", "426"),
                              ("GET /v1/hello HTTP/1.1\r\n\(head)\(old)\r\n", "200"),
                              ("GET /v1/sessions HTTP/1.1\r\n\(head)\(new)\r\n", "200")] {
        let client = PinnedClient(port: port, pin: pin)
        client.send(request)
        let text = await client.text(until: "\r\n\r\n")
        #expect(text.hasPrefix("HTTP/1.1 \(status)"), "\(request) → \(text)")
        if status == "426" { #expect(await client.text(until: "upgrade_client").contains("upgrade_client")) }
        client.close()
    }
}

@Test func theIdentityIsMadeOnceAndFoundAgain() throws {
    let keychain = try TestKeychain()
    let first = try #require(try keychain.store.identity())
    let again = try #require(try keychain.store.identity(create: false))
    #expect(first.spkiHash == again.spkiHash && first.spkiHash.count == 32)
    // A named keychain's key works for any build: no partition tied to this one's cdhash, so a rebuild never asks.
    #expect(keychain.store.keyAccess() == "any app")
    keychain.store.deleteIdentity()
    #expect(try keychain.store.identity(create: false) == nil)
    #expect(try keychain.store.readDevices() == nil)
    try keychain.store.writeDevices(Data("[]".utf8))
    try keychain.store.writeDevices(Data("[1]".utf8))
    #expect(try keychain.store.readDevices() == Data("[1]".utf8))
}

@Test func aTakenPortOrAMissingAddressFailsByName() async throws {
    let keychain = try TestKeychain()
    let (first, port, _) = try makeServer(keychain, token: DeviceToken.make())
    defer { first.stop() }
    await ready(first)
    let identity = try #require(try keychain.store.identity())
    let second = RemoteServer(identity: identity, epoch: "e2") { _, _ in HTTPResponse(status: 204) }
    defer { second.stop() }
    // The controller moves to the next port on exactly this text.
    second.serve(addresses: ["127.0.0.1", "192.0.2.1"], port: port)
    let states = second.listenerStates
    #expect(states["127.0.0.1"] == .failed("Port in use"))
    #expect(states["192.0.2.1"] == .failed("The address isn't on this Mac any more"))
}

@Test func pairingWaitsHaveTheirOwnBudgetAndADroppedOneIsReported() async throws {
    let keychain = try TestKeychain()
    let (server, port, pin) = try makeServer(keychain, token: DeviceToken.make())
    defer { server.stop() }
    let closed = OSAllocatedUnfairLock(initialState: [UInt64]())
    server.connectionClosed = { id in closed.withLock { $0.append(id) } }
    await ready(server)
    let host = "Host: 127.0.0.1:\(port)\r\n"
    func status(_ request: String) async -> String {
        let client = PinnedClient(port: port, pin: pin)
        defer { client.close() }
        client.send(request)
        // Eighteen handshakes in a row: give each room when the whole suite runs at once.
        return String(await client.text(until: "\r\n", within: 10).prefix(12))
    }
    // A cancelled attempt and a quick retry: re-polls and cancels don't spend what a new pairing needs.
    for _ in 0..<4 {
        #expect(await status("POST /v1/pair/a1/wait HTTP/1.1\r\n\(host)Content-Length: 0\r\n\r\n") == "HTTP/1.1 200")
        #expect(await status("DELETE /v1/pair/a1 HTTP/1.1\r\n\(host)\r\n") == "HTTP/1.1 200")
    }
    for _ in 0..<5 { #expect(await status("GET /v1/hello HTTP/1.1\r\n\(host)\r\n") == "HTTP/1.1 200") }
    #expect(await status("GET /v1/hello HTTP/1.1\r\n\(host)\r\n") == "HTTP/1.1 429")
    for _ in 0..<50 where closed.withLock({ $0.count }) < 14 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(closed.withLock { $0.count } >= 14)
}

@Test func requestsPipelinedBehindASlowOneWaitInABoundedQueueAndAllGetAnswers() async throws {
    let keychain = try TestKeychain()
    let identity = try #require(try keychain.store.identity())
    let token = DeviceToken.make()
    let server = RemoteServer(identity: identity, epoch: "e1") { request, _ in
        if request.path.last == "slow" { try? await Task.sleep(for: .milliseconds(500)) }
        return HTTPResponse.json(200, Data(#"{"path":"\#(request.path.joined(separator: "/"))"}"#.utf8))
    }
    server.setDevices([(id: "d1", hash: DeviceToken.hash(token))])
    let port = freePort()
    server.serve(addresses: ["127.0.0.1"], port: port)
    defer { server.stop() }
    await ready(server)
    let head = "Host: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n"
    // Twelve 300 KiB bodies behind the slow one: more than the queue holds, so reading pauses and picks up again.
    let body = String(repeating: "x", count: 300 << 10)
    var stream = "GET /v1/slow HTTP/1.1\r\n\(head)\r\n"
    for index in 0..<12 { stream += "POST /v1/n\(index) HTTP/1.1\r\n\(head)Idempotency-Key: k\(index)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)" }
    let client = PinnedClient(port: port, pin: identity.spkiHash)
    defer { client.close() }
    client.send(stream)
    // 3.6 MB through TLS takes a while when the whole suite runs at once.
    let text = await client.text(until: #""path":"v1/n11""#, within: 10)
    let order = text.components(separatedBy: #""path":""#).dropFirst().map { $0.prefix { $0 != "\"" } }
    #expect(order == ["v1/slow"] + (0..<12).map { "v1/n\($0)" })
}

@Test func theTunnelKeepsTheLoopbackListenerWithNoAddressAndPassesItsHost() async throws {
    let keychain = try TestKeychain()
    let token = DeviceToken.make()
    let (server, _, pin) = try makeServer(keychain, token: token)
    defer { server.stop() }
    await ready(server)
    server.setTunnel(true)
    server.serve(addresses: [], port: server.port, names: [RemoteController.relayHost])
    let port = try #require(await withCheckedContinuation { done in server.tunnelPort { done.resume(returning: $0) } })
    #expect(server.listenerStates.isEmpty)

    let client = PinnedClient(port: port, pin: pin)
    client.send("GET /v1/sessions HTTP/1.1\r\nHost: \(RemoteController.relayHost)\r\nAuthorization: Bearer \(token)\r\nConnection: close\r\n\r\n")
    #expect(await client.text(until: "\"device\":\"d1\"").hasPrefix("HTTP/1.1 200 OK"))
    let other = PinnedClient(port: port, pin: pin)
    other.send("GET /v1/hello HTTP/1.1\r\nHost: evil.example\r\n\r\n")
    #expect(await other.text(until: "\r\n\r\n").hasPrefix("HTTP/1.1 421"))

    // Off with no addresses left, the listener goes and the tunnel gets no port.
    server.setTunnel(false)
    #expect(await withCheckedContinuation { done in server.tunnelPort { done.resume(returning: $0) } } == nil)
}

@Test func confirmRefusalsSayWhatTheMacNeeds() throws {
    let confirm = P256.Signing.PrivateKey(), unlock = P256.Signing.PrivateKey()
    let keys = ConfirmGate.Keys(confirm: confirm.publicKey.x963Representation.base64URL, unlock: unlock.publicKey.x963Representation.base64URL)
    let replay = ConfirmGate.ReplayCache()
    var seconds = 0
    func header(_ signer: ConfirmSignature.Signer) throws -> String {
        seconds += 1
        let now = Int(Date().timeIntervalSince1970) + seconds
        let text = try ConfirmMessage.text(macID: "mac", deviceID: "d1", purpose: .allow, subject: "r1:allow", at: now)
        let key = signer == .confirm ? confirm : unlock
        return ConfirmSignature(at: now, signer: signer, signature: try key.signature(for: Data(text.utf8)).derRepresentation).headerValue
    }
    func check(_ header: String?, needs: ConfirmProof, keys: ConfirmGate.Keys = keys) -> (Int, [String: Any])? {
        guard let response = RemoteServer.confirm(header, macID: "mac", device: "d1", purpose: .allow, subject: "r1:allow", needs: needs,
                                                  keys: keys, replay: replay) else { return nil }
        return (response.status, (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:])
    }
    func code(_ result: (Int, [String: Any])?) -> String? { (result?.1["error"] as? [String: Any])?["code"] as? String }
    func details(_ result: (Int, [String: Any])?) -> [String: String]? { (result?.1["error"] as? [String: Any])?["details"] as? [String: String] }

    #expect(check(nil, needs: .none) == nil)
    #expect(check(try header(.unlock), needs: .unlock) == nil)
    #expect(check(try header(.confirm), needs: .unlock) == nil)
    let short = check(try header(.unlock), needs: .biometric)
    #expect(short?.0 == 401 && code(short) == "confirm_required" && details(short)?["level"] == "biometric")
    let forged = check("v1.1.c.AAAA", needs: .unlock)
    #expect(forged?.0 == 401 && code(forged) == "confirm_invalid")
    let keyless = check(nil, needs: .unlock, keys: .init(confirm: nil, unlock: nil))
    #expect(code(keyless) == "confirm_required" && details(keyless)?["hint"] == "pairAgain")
}

@Test func aBodyIsOnlyReadForSomeoneSignedIn() async throws {
    let keychain = try TestKeychain()
    let token = DeviceToken.make()
    let (server, port, pin) = try makeServer(keychain, token: token)
    defer { server.stop() }
    await ready(server)
    let host = "Host: 127.0.0.1:\(port)\r\n"
    func send(_ text: String, within seconds: Double = 10) async -> String {
        let client = PinnedClient(port: port, pin: pin)
        defer { client.close() }
        client.send(text)
        return String(await client.text(until: "\r\n", within: seconds).prefix(12))
    }
    // No token: a 20 MiB upload is refused from its head, before any body is sent.
    #expect(await send("POST /v1/uploads HTTP/1.1\r\n\(host)Content-Length: \(20 << 20)\r\n\r\n") == "HTTP/1.1 413")
    #expect(await send("POST /v1/pair HTTP/1.1\r\n\(host)Content-Length: \(RemoteServer.unauthenticatedBody + 1)\r\n\r\n") == "HTTP/1.1 413")
    // Signed in, the same route takes more than a stranger may send.
    #expect(await send("POST /v1/sessions HTTP/1.1\r\n\(host)Authorization: Bearer \(token)\r\nIdempotency-Key: s1\r\nContent-Length: \(100 << 10)\r\n\r\n"
                       + String(repeating: "x", count: 100 << 10), within: 10) == "HTTP/1.1 200")
    let body = String(repeating: "x", count: 2 << 20)
    #expect(await send("POST /v1/uploads HTTP/1.1\r\n\(host)Authorization: Bearer \(token)\r\nIdempotency-Key: u1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)",
                       within: 10) == "HTTP/1.1 200")
}

/// A resend after a lost response carries the same key and the same signature: its stored answer comes back without
/// the signature being checked (or spent) again, and the action never runs twice. Keys are per device.
@Test func aResentSignedAnswerReplaysItsResultBeforeAnySignatureCheck() async throws {
    let keychain = try TestKeychain()
    let identity = try #require(try keychain.store.identity())
    let unlock = P256.Signing.PrivateKey()
    let runs = OSAllocatedUnfairLock(initialState: 0)
    let keys: [String: ConfirmGate.Keys] = ["d1": .init(confirm: nil, unlock: unlock.publicKey.x963Representation.base64URL),
                                            "d2": .init(confirm: nil, unlock: P256.Signing.PrivateKey().publicKey.x963Representation.base64URL)]
    let replay = ConfirmGate.ReplayCache()
    // The route's own check, as the answer route makes it: a replayed signature would be refused here.
    let server = RemoteServer(identity: identity, epoch: "e1") { request, caller in
        runs.withLock { $0 += 1 }
        let device = caller.device ?? ""
        if let refusal = RemoteServer.confirm(request.headers[ConfirmSignature.header], macID: "mac", device: device, purpose: .allow,
                                              subject: "r1:allow", needs: .unlock, keys: keys[device] ?? .init(confirm: nil, unlock: nil),
                                              replay: replay) { return refusal }
        return HTTPResponse.json(200, Data(#"{"done":true}"#.utf8))
    }
    let one = DeviceToken.make(), two = DeviceToken.make()
    server.setDevices([(id: "d1", hash: DeviceToken.hash(one)), (id: "d2", hash: DeviceToken.hash(two))])
    let port = freePort()
    server.serve(addresses: ["127.0.0.1"], port: port)
    defer { server.stop() }
    await ready(server)
    let at = Int(Date().timeIntervalSince1970)
    let text = try ConfirmMessage.text(macID: "mac", deviceID: "d1", purpose: .allow, subject: "r1:allow", at: at)
    let signature = ConfirmSignature(at: at, signer: .unlock, signature: try unlock.signature(for: Data(text.utf8)).derRepresentation).headerValue
    func post(_ token: String, _ body: String = "{}") async -> String {
        let client = PinnedClient(port: port, pin: identity.spkiHash)
        defer { client.close() }
        client.send("POST /v1/requests/r1/answer HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nIdempotency-Key: k1\r\n"
                    + "\(ConfirmSignature.header): \(signature)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        return await client.text(until: "}", within: 10)
    }
    #expect(await post(one).hasPrefix("HTTP/1.1 200") && runs.withLock { $0 } == 1)
    // The response was lost; the outbox sends it again, signature and all.
    let again = await post(one)
    #expect(again.hasPrefix("HTTP/1.1 200") && again.contains("Idempotent-Replay: true") && runs.withLock { $0 } == 1)
    // The same key from another device is that device's own request, and the first device's signature is no use to it.
    let other = await post(two)
    #expect(other.hasPrefix("HTTP/1.1 401") && !other.contains("Idempotent-Replay") && runs.withLock { $0 } == 2)
    // The same key with another body is refused without running.
    #expect(await post(one, #"{"x":1}"#).hasPrefix("HTTP/1.1 422") && runs.withLock { $0 } == 2)
}
