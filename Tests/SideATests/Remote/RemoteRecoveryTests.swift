import AppKit
import CryptoKit
import Foundation
@testable import SideA
import SideACore
import SideAProtocol
@testable import SideARemoteKit
import Testing

private func hex(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() }

@Test func theReleaseBuildKeepsTheMacIDPhonesHold() {
    #expect(RemoteController.macID(hardware: "UUID-1", bundleID: AppCopies.releaseID, release: true) == hex("UUID-1"))
    #expect(RemoteController.macName("Studio", release: true) == "Studio")
}

@Test func aDevBuildIsAMacOfItsOwn() {
    let release = RemoteController.macID(hardware: "UUID-1", bundleID: AppCopies.releaseID, release: true)
    let dev = RemoteController.macID(hardware: "UUID-1", bundleID: AppCopies.releaseID + ".dev", release: false)
    #expect(dev != release && dev.count == release.count)
    #expect(dev != RemoteController.macID(hardware: "UUID-1", bundleID: "com.example.other", release: false))
    #expect(dev != RemoteController.macID(hardware: "UUID-2", bundleID: AppCopies.releaseID + ".dev", release: false))
    #expect(dev == RemoteController.macID(hardware: "UUID-1", bundleID: AppCopies.releaseID + ".dev", release: false))
    #expect(RemoteController.macName("Studio", release: false) == "Studio Dev")
}

// MARK: Hello

@MainActor
private func helloAnswer(_ caller: RemoteServer.Caller) async throws -> [String: Any] {
    let remote = RemoteController(store: AccountStore(demo: true), keychain: .inMemory(), addresses: ["127.0.0.1"], port: 1_025)
    let request = HTTPRequest(method: "GET", target: "/v1/hello", path: ["v1", "hello"], query: [:], headers: HTTPHeaders([]), body: Data())
    let response = await RemoteRoutes.route(request, caller, remote)
    #expect(response.status == 200)
    return try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
}

@MainActor @Test func helloSaysWhetherItKnowsTheToken() async throws {
    let known = try await helloAnswer(RemoteServer.Caller(device: "d1", connection: 1))
    #expect(known["paired"] as? Bool == true)
    #expect((known["mac"] as? [String: Any])?["id"] as? String != "")

    let none = try await helloAnswer(RemoteServer.Caller(device: nil, connection: 1))
    #expect(none["paired"] == nil)

    // A wrong token learns that and no more than a caller with none.
    let wrong = try await helloAnswer(RemoteServer.Caller(device: nil, connection: 1, rejected: true))
    #expect(wrong["paired"] as? Bool == false)
    for key in ["mac", "endpoints", "keyID", "capabilities"] {
        #expect(String(describing: wrong[key]) == String(describing: none[key]), "\(key)")
    }
    #expect((wrong["mac"] as? [String: Any])?["id"] as? String == "" && wrong["keyID"] as? String == "")
    #expect((wrong["endpoints"] as? [String: Any])?["tailnet"] as? String == "")

    // What installed phones decode.
    let decoded = try JSONDecoder().decode(Hello.self, from: JSONSerialization.data(withJSONObject: wrong))
    #expect(decoded.paired == false)
}

/// The caller as the server builds it, over real TLS.
private final class Echo {
    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    let keychain: TestKeychain
    let server: RemoteServer
    let port = freePort()
    let pin: Data
    let token = DeviceToken.make()
    private let unavailable = Count()

    var asked: Int { unavailable.value }

    init() throws {
        keychain = try TestKeychain()
        let identity = try #require(try keychain.store.identity())
        pin = identity.spkiHash
        server = RemoteServer(identity: identity, epoch: "e1") { _, caller in
            HTTPResponse.json(200, Data(#"{"device":"\#(caller.device ?? "-")","rejected":\#(caller.rejected)}"#.utf8))
        }
        let unavailable = unavailable
        server.devicesUnavailable = { unavailable.add() }
        server.opened = { _ in }
        server.setDevices([(id: "d1", hash: DeviceToken.hash(token))])
        server.serve(addresses: ["127.0.0.1"], port: port)
    }

    func ready() async {
        for _ in 0..<750 where server.listenerStates.values.first != .ready { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func ask(_ header: String?, _ head: String) async -> String {
        let client = PinnedClient(port: port, pin: pin)
        defer { client.close() }
        client.send("\(head) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\(header.map { $0 + "\r\n" } ?? "")\r\n")
        return await client.text(until: "}")
    }
}

@Test func theServerTellsAWrongTokenFromNone() async throws {
    let echo = try Echo()
    defer { echo.server.stop() }
    await echo.ready()
    #expect(await echo.ask(nil, "GET /v1/hello").contains(#""device":"-","rejected":false"#))
    #expect(await echo.ask("Authorization: Bearer sa1_wrong", "GET /v1/hello").contains(#""device":"-","rejected":true"#))
    #expect(await echo.ask("Authorization: Bearer \(echo.token)", "GET /v1/hello").contains(#""device":"d1","rejected":false"#))
}

/// An unreadable list is an answer to come back later, never a 401 the phone reads as removed.
@Test func anUnreadableDeviceListAnswersUnavailable() async throws {
    let echo = try Echo()
    defer { echo.server.stop() }
    await echo.ready()
    let bearer = "Authorization: Bearer \(echo.token)"
    #expect(await echo.ask(bearer, "GET /v1/sessions").contains("200 OK"))

    // A socket already open stays open: 4401 is what tells a phone it was removed.
    let upgrade = "GET /v1/ws/events HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    let open = PinnedClient(port: echo.port, pin: echo.pin)
    defer { open.close() }
    open.send(upgrade + bearer + "\r\n\r\n")
    let opened = await open.text(until: "\r\n\r\n")
    #expect(opened.hasPrefix("HTTP/1.1 101"))

    echo.server.setDevices(nil)
    for target in ["GET /v1/sessions", "GET /v1/hello", "GET /v1/ws/events"] {
        let answer = await echo.ask(bearer, target)
        #expect(answer.hasPrefix("HTTP/1.1 503"), "\(target): \(answer)")
        #expect(answer.contains(#""code":"not_ready""#) && answer.contains(#""retryable":true"#) && answer.contains("Retry-After: 5"))
    }
    #expect(echo.asked == 3)
    // Nobody's token is accepted meanwhile, and none is told it's wrong.
    #expect(await echo.ask("Authorization: Bearer sa1_wrong", "GET /v1/sessions").hasPrefix("HTTP/1.1 503"))
    // Without a token, what a phone does before pairing still works.
    #expect(await echo.ask(nil, "GET /v1/hello").contains("200 OK"))
    #expect(await echo.ask(nil, "GET /v1/sessions").hasPrefix("HTTP/1.1 401"))

    let after = await open.wait(0.3) { _ in false }
    #expect(after.count == Data(opened.utf8).count, "a frame arrived: \(Array(after.suffix(20)))")

    // Read again: the same token works, and a wrong one is wrong again.
    echo.server.setDevices([(id: "d1", hash: DeviceToken.hash(echo.token))])
    #expect(await echo.ask(bearer, "GET /v1/sessions").contains(#""device":"d1""#))
    #expect(await echo.ask("Authorization: Bearer sa1_wrong", "GET /v1/sessions").hasPrefix("HTTP/1.1 401"))
}

private func device(_ id: String, hash: Data = Data(count: 32)) -> RemoteDevice {
    RemoteDevice(id: id, name: "iPhone", model: "", system: "", app: "", build: 1, hash: hash, secretHash: "s", created: 1, lastSeen: 2)
}

@MainActor @Test func anUnreadableDeviceListIsReadAgainAndNeverOverwritten() throws {
    let keychain = RemoteKeychain.inMemory()
    let garbage = Data("not json".utf8)
    try keychain.writeDevices(garbage)
    let remote = RemoteController(store: AccountStore(demo: true), keychain: keychain, addresses: ["127.0.0.1"], port: 1_025)
    remote.on = true
    remote.start()
    #expect(remote.devices.unreadable != nil && remote.devices.hashes == nil && remote.error == remote.devices.unreadable)

    let start = Date().addingTimeInterval(60)
    remote.reloadDevices(now: start)
    #expect(remote.devices.unreadable != nil && remote.devices.hashes == nil)
    #expect(try keychain.readDevices() == garbage)

    // Every phone asks, and the keychain is read once every few seconds at most.
    try keychain.writeDevices(try JSONEncoder().encode([device("d1")]))
    let reads = keychain.memoryReads
    remote.reloadDevices(now: start.addingTimeInterval(RemoteController.deviceReloadEvery - 1))
    #expect(keychain.memoryReads == reads && remote.devices.unreadable != nil)

    remote.reloadDevices(now: start.addingTimeInterval(RemoteController.deviceReloadEvery))
    #expect(remote.devices.unreadable == nil && remote.error == nil)
    #expect(remote.devices.hashes?.map(\.id) == ["d1"])

    // Readable: nothing to do, and no more reads.
    let settled = keychain.memoryReads
    remote.reloadDevices(now: start.addingTimeInterval(600))
    #expect(keychain.memoryReads == settled)
}

// MARK: Sleep

@MainActor @Test func theMacSaysGoodbyeBeforeItSleeps() async throws {
    let keychain = try TestKeychain()
    let store = AccountStore(demo: true)
    let remote = RemoteController(store: store, keychain: keychain.store, addresses: ["127.0.0.1"], port: freePort())
    store.remote = remote
    let token = DeviceToken.make()
    try remote.devices.add(device("d1", hash: DeviceToken.hash(token)), replacing: nil)
    remote.on = true
    remote.start()
    defer { remote.server?.stop() }
    for _ in 0..<750 where !remote.listening.values.contains(.ready) { try await Task.sleep(for: .milliseconds(20)) }
    let pin = try #require(remote.spki)

    var request = URLRequest(url: URL(string: "wss://127.0.0.1:\(remote.port)/v1/ws/events")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let socket = URLSessionTransport(trust: PinnedTrust(.pinned(pin.base64URL))).socket(request)
    try await socket.send(.text(String(decoding: try JSONEncoder().encode(ClientMessage.hello(epoch: nil, lastSeq: nil, capabilities: [.events])), as: UTF8.self)))
    func next() async throws -> ServerEvent {
        guard case .text(let text) = try await socket.receive() else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(EventEnvelope.self, from: Data(text.utf8)).event
    }
    guard case .welcome = try await next() else { Issue.record("no welcome"); return }

    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
    var said: ServerEvent?
    for _ in 0..<5 {
        let event = try await next()
        if case .bye = event { said = event; break }
    }
    #expect(said == .bye(reason: ServerEvent.byeSleep))
    await #expect(throws: SocketClosed(code: 1001, reason: ServerEvent.byeSleep)) { _ = try await socket.receive() }
}
