import Crypto
import Foundation
import NIOCore
import NIOPosix
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

/// A relay in a few lines: the REST calls answer 200 and are recorded, `/v1/tunnel/mac` upgrades to a WebSocket the test
/// drives, and a second port plays the phone side, splicing each TCP connection to a tunnel stream. It checks nothing about
/// signatures (relay/test does that); it proves what the daemon does with what a relay sends.
final class StubRelay: @unchecked Sendable {
    struct Call { let method: String; let path: String; let body: Data; let authorization: String? }

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private let lock = NSLock()
    private var calls_: [Call] = []
    private var texts_: [String] = []
    private var sockets: [Channel] = []
    private var phones: [UInt32: Channel] = [:]
    private var nextStream: UInt32 = 1 << 16
    private var frames_: [UInt32: [TunnelFrame]] = [:]
    private var http: Channel?
    private var phone: Channel?
    private(set) var connections = 0
    var refuseWith: Int?

    var url: URL { URL(string: "http://127.0.0.1:\(httpPort)")! }
    private(set) var httpPort = 0
    private(set) var phonePort = 0
    var calls: [Call] { lock.withLock { calls_ } }
    var texts: [String] { lock.withLock { texts_ } }

    init() throws {
        http = try ServerBootstrap(group: group).serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in channel.pipeline.addHandler(HTTPSide(owner: self)) }
            .bind(host: "127.0.0.1", port: 0).wait()
        httpPort = http?.localAddress?.port ?? 0
        phone = try ServerBootstrap(group: group).serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in channel.pipeline.addHandler(PhoneSide(owner: self)) }
            .bind(host: "127.0.0.1", port: 0).wait()
        phonePort = phone?.localAddress?.port ?? 0
    }

    func shutdown() {
        try? http?.close().wait()
        try? phone?.close().wait()
        try? group.syncShutdownGracefully()
    }

    func sendText(_ text: String) {
        let frame = WebSocketFrames.frame(.text, Data(text.utf8), from: .server)
        lock.withLock { sockets.last }?.writeAndFlush(ByteBuffer(bytes: frame), promise: nil)
    }

    func send(_ frame: TunnelFrame) {
        let wire = WebSocketFrames.frame(.binary, frame.encoded, from: .server)
        lock.withLock { sockets.last }?.writeAndFlush(ByteBuffer(bytes: wire), promise: nil)
    }

    func dropSocket() { lock.withLock { sockets.last }?.close(promise: nil) }

    // Called by the handlers.
    fileprivate func record(_ call: Call) { lock.withLock { calls_.append(call) } }
    fileprivate func attach(_ socket: Channel) { lock.withLock { sockets.append(socket); connections += 1 } }
    fileprivate func text(_ text: String) { lock.withLock { texts_.append(text) } }
    fileprivate func binary(_ data: Data) {
        guard let frame = TunnelFrame(data) else { return }
        let channel: Channel? = lock.withLock { frames_[frame.stream, default: []].append(frame); return phones[frame.stream] }
        switch frame.kind {
        case .data: channel?.writeAndFlush(ByteBuffer(bytes: frame.payload), promise: nil)
        case .fin, .reset: channel?.close(promise: nil)
        default: break
        }
    }
    fileprivate func open(_ channel: Channel) -> UInt32 {
        let id: UInt32 = lock.withLock { nextStream += 1; phones[nextStream] = channel; return nextStream }
        send(TunnelFrame(.open, id))
        return id
    }
    fileprivate func closed(_ id: UInt32) { send(TunnelFrame(.fin, id)); lock.withLock { phones[id] = nil } }

    func framesReceived(_ kind: TunnelFrame.Kind) -> [TunnelFrame] { lock.withLock { frames_.values.flatMap { $0 }.filter { $0.kind == kind } } }

    private final class HTTPSide: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let owner: StubRelay
        var buffer = Data()
        var upgraded = false
        var parser = WebSocketFrames(role: .server, maxMessage: 1 << 20, strict: false)
        init(owner: StubRelay) { self.owner = owner }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let bytes = Data(unwrapInboundIn(data).readableBytesView)
            if upgraded { return frames(bytes, context) }
            buffer.append(bytes)
            while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let parts = lines[0].split(separator: " ")
                var fields: [String: String] = [:]
                for line in lines.dropFirst() { if let colon = line.firstIndex(of: ":") { fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) } }
                let length = Int(fields["content-length"] ?? "0") ?? 0
                guard buffer.count >= end.upperBound + length else { return }
                let body = Data(buffer[end.upperBound..<end.upperBound + length])
                let rest = Data(buffer[(end.upperBound + length)...])
                buffer = Data()
                let (method, path) = (String(parts[0]), String(parts[1]))
                owner.record(Call(method: method, path: path, body: body, authorization: fields["authorization"]))
                if path == "/v1/tunnel/mac", let key = fields["sec-websocket-key"] {
                    if let status = owner.refuseWith {
                        context.writeAndFlush(wrap("HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"), promise: nil)
                        return context.close(promise: nil)
                    }
                    upgraded = true
                    context.writeAndFlush(wrap("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WebSocketFrames.acceptKey(key))\r\n\r\n"), promise: nil)
                    owner.attach(context.channel)
                    if !rest.isEmpty { frames(rest, context) }
                    return
                }
                let answer: String
                if path == "/v1/send", let sent = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let devices = sent["devices"] as? [String] {
                    let results = devices.map { "{\"device\":\"\($0)\",\"result\":\"ok\"}" }.joined(separator: ",")
                    answer = "{\"results\":[\(results)]}"
                } else if method == "PUT" { answer = "{\"verified\":true}" } else { answer = "{}" }
                context.writeAndFlush(wrap("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(answer.utf8.count)\r\n\r\n\(answer)"), promise: nil)
                if rest.isEmpty { return }
                buffer = rest
            }
        }

        func frames(_ bytes: Data, _ context: ChannelHandlerContext) {
            parser.append(bytes)
            while let next = parser.next() {
                guard case .success(let frame) = next else { return context.close(promise: nil) }
                switch frame.opcode {
                case .text:
                    let text = String(decoding: frame.payload, as: UTF8.self)
                    owner.text(text)
                    if text == "ping" { context.writeAndFlush(wrap(frameBytes(.text, Data("pong".utf8))), promise: nil) }
                case .binary: owner.binary(frame.payload)
                case .ping: context.writeAndFlush(wrap(frameBytes(.pong, frame.payload)), promise: nil)
                default: break
                }
            }
        }

        private func frameBytes(_ opcode: WebSocketFrames.Opcode, _ payload: Data) -> Data { WebSocketFrames.frame(opcode, payload, from: .server) }
        private func wrap(_ text: String) -> NIOAny { NIOAny(ByteBuffer(string: text)) }
        private func wrap(_ data: Data) -> NIOAny { NIOAny(ByteBuffer(bytes: data)) }
    }

    private final class PhoneSide: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let owner: StubRelay
        var id: UInt32 = 0
        init(owner: StubRelay) { self.owner = owner }
        func channelActive(context: ChannelHandlerContext) { id = owner.open(context.channel); context.fireChannelActive() }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            while bytes.readableBytes > 0, let chunk = bytes.readBytes(length: min(bytes.readableBytes, TunnelFrame.maxPayload)) {
                owner.send(TunnelFrame(.data, id, Data(chunk)))
            }
        }
        func channelInactive(context: ChannelHandlerContext) { owner.closed(id) }
    }
}

private func relayConfig(_ stub: StubRelay) -> RelayConfig { RelayConfig(url: stub.url) }

private func withRelay<T>(_ stub: StubRelay, _ body: (SideADaemon, URL) async throws -> T) async throws -> T {
    let directory = try temporaryDirectory("relay")
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = DaemonConfig(paths: DaemonPaths(state: directory))
    config.port = 0; config.discover = false; config.os = .linux
    config.relay = relayConfig(stub)
    let daemon = try SideADaemon(config: config)
    try await daemon.start()
    do {
        let result = try await body(daemon, directory)
        try await daemon.stop()
        return result
    } catch {
        try? await daemon.stop()
        throw error
    }
}

@Test func theTunnelOpensTellsTheRelayWhoMayComeAndLetsAPhoneThroughToTheSameServer() async throws {
    let stub = try StubRelay()
    defer { stub.shutdown() }
    try await withRelay(stub) { daemon, _ in
        #expect(await eventually { stub.connections == 1 && stub.texts.contains { $0.contains("\"watch\"") } })
        let upgrade = try #require(stub.calls.first { $0.path == "/v1/tunnel/mac" })
        #expect(upgrade.authorization?.hasPrefix("SideA-Sig v=1, install=\(daemon.relay?.installID ?? "-"),") == true)
        #expect(stub.calls.contains { $0.method == "POST" && $0.path == "/v1/installs" })

        // Pairing over the tunnel's own listener, as `sidead pair` would, names a ticket to the relay and puts it in the link.
        daemon.pairingOpened(true)
        #expect(await eventually { stub.texts.contains { $0.contains("\"pairing\"") && $0.contains("ticketHash") } })
        await daemon.pairing.open()
        let link = daemon.link(code: await daemon.pairing.currentCode ?? "")
        #expect(link.contains("i=\(daemon.relay?.installID ?? "-")") && link.contains("r=") && link.contains("p="))

        let phone = FakePhone()
        let pin = daemon.identity.spkiHash
        let paired = try await phone.pair(with: daemon, pin: pin)
        daemon.pairingOpened(false)
        #expect(paired.relay?.installID == daemon.relay?.installID && paired.relay?.url == stub.url.absoluteString)
        #expect(await eventually { stub.texts.contains { $0.contains("\"devices\"") && $0.contains(paired.deviceID) && $0.contains(phone.secretHash) } })
        #expect(await eventually { stub.texts.contains { $0.contains("\"pairing\"") && !$0.contains("ticketHash") } })

        // The phone's TLS, pinned to the daemon's key, runs across the relay's frames and comes out at the daemon.
        let through = try await TestConnection.open(port: stub.phonePort, pin: pin)
        let hello = try await through.request("GET", "/v1/hello", headers: ["Authorization": "Bearer \(paired.token)"], host: "sidea-relay.invalid")
        #expect(hello.status == 200)
        let decoded = try hello.json(Hello.self)
        #expect(decoded.paired == true && decoded.capabilities.contains(.push))
        // A host that isn't the relay's is still refused over the tunnel.
        let wrong = try await through.request("GET", "/v1/hello", headers: ["Authorization": "Bearer \(paired.token)"], host: "evil.example")
        #expect(wrong.status >= 400)
        await through.close()
        #expect(await eventually { stub.framesReceived(.fin).count >= 1 || stub.framesReceived(.reset).count >= 1 })
    }
}

@Test func theTunnelComesBackAfterTheRelayDropsItAndAnswersItsPings() async throws {
    let stub = try StubRelay()
    defer { stub.shutdown() }
    try await withRelay(stub) { _, _ in
        #expect(await eventually { stub.connections == 1 })
        #expect(await eventually { stub.texts.contains("ping") })
        stub.dropSocket()
        #expect(await eventually(30) { stub.connections == 2 })
        // After a refusal it waits and tries again rather than spinning.
        stub.refuseWith = 503
        stub.dropSocket()
        #expect(await eventually(30) { stub.calls.filter { $0.path == "/v1/tunnel/mac" }.count >= 3 })
    }
}

@Test func aStreamTheDaemonCantServeIsResetAndTooManyFromOneSlotAreRefused() async throws {
    let stub = try StubRelay()
    defer { stub.shutdown() }
    try await withRelay(stub) { _, _ in
        #expect(await eventually { stub.connections == 1 })
        for index in 0..<10 { stub.send(TunnelFrame(.open, (5 << 16) | UInt32(index))) }
        #expect(await eventually { stub.framesReceived(.reset).contains { $0.reason == "too_many_streams" } })
        stub.send(TunnelFrame(.data, 0xdead_0001, Data("x".utf8)))
        #expect(await eventually { stub.framesReceived(.reset).contains { $0.stream == 0xdead_0001 && $0.reason == "unknown" } })
    }
}

@Test func aPhonesPushRegistrationReachesTheRelayAndAFinishedTurnGoesOutSealed() async throws {
    let stub = try StubRelay()
    defer { stub.shutdown() }
    try await withRelay(stub) { daemon, _ in
        let phone = FakePhone()
        let pin = daemon.identity.spkiHash
        let paired = try await phone.pair(with: daemon, pin: pin)
        let connection = try await TestConnection.open(port: daemon.port, pin: pin)
        let headers = ["Authorization": "Bearer \(paired.token)", "Content-Type": "application/json"]
        let registration = PushRegistration(apnsToken: "ab12cd34", bundleID: "com.arnenoori.sidea.remote.dev", apnsEnvironment: .sandbox)
        let answer = try await connection.request("POST", "/v1/devices/push", headers: headers.merging(["Idempotency-Key": "p-1"]) { $1 }, body: try JSONEncoder().encode(registration))
        #expect(answer.status == 204)
        #expect(await eventually {
            guard let put = stub.calls.first(where: { $0.method == "PUT" && $0.path == "/v1/devices/\(paired.deviceID)" }),
                  let body = try? JSONSerialization.jsonObject(with: put.body) as? [String: Any] else { return false }
            return body["apnsToken"] as? String == "ab12cd34" && body["secretHash"] as? String == phone.secretHash && body["apnsEnvironment"] as? String == "sandbox"
        })

        let turn = FinishedSession(sessionID: "s1", turnID: "turn-1", title: "Refactor", summary: "Done.", at: Date().timeIntervalSince1970, canFollowUp: false)
        await daemon.sessionFinished(turn)
        let sent = try #require(stub.calls.first { $0.path == "/v1/send" })
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(body["category"] as? String == "FINISHED" && body["collapseId"] as? String == "turn-1" && body["devices"] as? [String] == [paired.deviceID])
        let sealed = try #require((body["sealed"] as? [String: String])?[paired.deviceID])
        // Only the phone's key opens it: the one derived at pairing, which the daemon holds for this device.
        let device = try #require(await daemon.devices.device(id: paired.deviceID))
        let key = PushKey(key: SymmetricKey(data: try #require(device.pushKey)), keyID: try #require(device.pushKeyID))
        let plain = try PushEnvelope.open(sealed, with: key, category: .finished, collapseID: "turn-1", deviceID: paired.deviceID)
        let payload = try JSONDecoder().decode(PushPayload.self, from: plain)
        #expect(payload.t == PushKind.finished.rawValue && payload.title == "Refactor" && payload.turnID == "turn-1")
        #expect(!String(decoding: sent.body, as: UTF8.self).contains("Refactor"))

        // The phone's test button.
        let test = try await connection.request("POST", "/v1/diagnostics/push", headers: headers.merging(["Idempotency-Key": "p-2"]) { $1 }, body: Data("{}".utf8))
        #expect(test.status == 200)
        let diagnostic = try test.json(DiagnosticPush.self)
        #expect(diagnostic.relay == .ok)
        let received = try await connection.request("POST", "/v1/diagnostics/push/\(diagnostic.id)/received", headers: headers.merging(["Idempotency-Key": "p-3"]) { $1 }, body: Data("{}".utf8))
        #expect(received.status == 204)
        await connection.close()
    }
}

@Test func aPhoneLookingAtTheAppIsNotPushedAndARevokedOneIsForgottenByTheRelay() async throws {
    let stub = try StubRelay()
    defer { stub.shutdown() }
    try await withRelay(stub) { daemon, _ in
        let phone = FakePhone()
        let paired = try await phone.pair(with: daemon, pin: daemon.identity.spkiHash)
        _ = try await daemon.devices.update(paired.deviceID) { $0.push = PushRegistration(apnsToken: "ab12") }
        await daemon.revoke(paired.deviceID)
        #expect(await eventually { stub.calls.contains { $0.method == "DELETE" && $0.path == "/v1/devices/\(paired.deviceID)" } })
        #expect(await eventually { stub.texts.contains { $0.contains("\"devices\"") && !$0.contains(paired.deviceID) } })
        #expect(RelayLink.skips(EventHub.Presence(foreground: true, viewing: nil, at: Date()), now: Date()))
        #expect(!RelayLink.skips(EventHub.Presence(foreground: true, viewing: nil, at: Date(timeIntervalSinceNow: -60)), now: Date()))
        #expect(!RelayLink.skips(EventHub.Presence(foreground: false, viewing: nil, at: Date()), now: Date()))
    }
}

// MARK: which relay `sidead run` uses

@Test func aDaemonUsesTheProductionRelayUnlessTold() {
    #expect(RelayChoice.resolve(option: nil, disabled: false, environment: [:]) == .use(URL(string: "https://push.getsidea.com")!))
    #expect(RelayChoice.production.absoluteString == "https://push.getsidea.com")
    #expect(RelayChoice.resolve(option: "http://192.0.2.7:8799", disabled: false, environment: [:]) == .use(URL(string: "http://192.0.2.7:8799")!))
    #expect(RelayChoice.resolve(option: nil, disabled: false, environment: ["SIDEAD_RELAY_URL": "https://relay.example.test"]) == .use(URL(string: "https://relay.example.test")!))
    #expect(RelayChoice.resolve(option: "https://a.example.test", disabled: false, environment: ["SIDEAD_RELAY_URL": "https://b.example.test"]) == .use(URL(string: "https://a.example.test")!))
}

@Test func theRelayCanBeSwitchedOff() {
    #expect(RelayChoice.resolve(option: nil, disabled: true, environment: [:]) == .off)
    #expect(RelayChoice.resolve(option: "https://a.example.test", disabled: true, environment: [:]) == .off)
    #expect(RelayChoice.resolve(option: nil, disabled: false, environment: ["SIDEAD_RELAY_URL": "off"]) == .off)
    #expect(RelayChoice.resolve(option: nil, disabled: false, environment: ["SIDEAD_RELAY_URL": ""]) == .off)
}

@Test func aRelayThatIsNotAnAddressIsRefused() {
    #expect(RelayChoice.resolve(option: "ftp://x", disabled: false, environment: [:]) == .invalid("ftp://x"))
    #expect(RelayChoice.resolve(option: "nonsense", disabled: false, environment: [:]) == .invalid("nonsense"))
}

@Test func aForwardedAddressIsAnsweredOnlyWhenTheOwnerNamedIt() throws {
    var config = DaemonConfig(paths: DaemonPaths.resolve(override: try temporaryDirectory("hosts").path))
    config.discover = false
    #expect(!SideADaemon.plan(config).hosts.contains("192.0.2.9"))
    config.allowedHosts = ["192.0.2.9", "NAS.Example.Test"]
    let hosts = SideADaemon.plan(config).hosts
    #expect(hosts.contains("192.0.2.9") && hosts.contains("nas.example.test") && hosts.contains("127.0.0.1"))
}
