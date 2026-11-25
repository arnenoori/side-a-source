import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

/// Waits for `condition`, checking every 20 ms, for at most `seconds`. Returns whether it held.
@discardableResult
func eventually(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if await condition() { return true }
        // swiftlint:disable:next sleep_as_sync_in_tests -- the poll interval itself
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

struct Answer {
    var status: Int
    var headers: String
    var body: Data
    func header(_ name: String) -> String? {
        headers.split(separator: "\r\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == name.lowercased() ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        }.first
    }
    func json<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: body) }
    var errorCode: String? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["code"] as? String }
    }
}

/// A TLS connection that trusts one key and nothing else, the way the phone does: it ignores the certificate chain and the
/// host name and checks that the server's SPKI hash is the pinned one. It keeps what arrives, so a test can read an HTTP
/// answer, then WebSocket frames, off the same connection.
final class TestConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var received = Data()
    private var closed = false
    private let channel: any Channel
    private let group: MultiThreadedEventLoopGroup
    private var frames = WebSocketFrames(role: .client, maxMessage: 4 << 20, strict: false)
    let port: Int

    private init(channel: any Channel, group: MultiThreadedEventLoopGroup, port: Int) { self.channel = channel; self.group = group; self.port = port }

    static func open(port: Int, pin: String, maximumTLSVersion: TLSVersion? = nil) async throws -> TestConnection {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .noHostnameVerification
        configuration.minimumTLSVersion = .tlsv12
        if let maximumTLSVersion { configuration.maximumTLSVersion = maximumTLSVersion }
        let context = try NIOSSLContext(configuration: configuration)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let sink = Sink()
        do {
            let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let tls = try NIOSSLClientHandler(context: context, serverHostname: nil) { chain, promise in
                        guard let leaf = chain.first, let key = try? leaf.extractPublicKey().toSPKIBytes() else { return promise.succeed(.failed) }
                        promise.succeed(Data(SHA256.hash(data: key)).base64URL == pin ? .certificateVerified : .failed)
                    }
                    try channel.pipeline.syncOperations.addHandler(tls)
                    try channel.pipeline.syncOperations.addHandler(Collect(sink: sink))
                }
            }.connect(host: "127.0.0.1", port: port).get()
            let connection = TestConnection(channel: channel, group: group, port: port)
            sink.target = connection
            // Writing forces the handshake, so a refused key fails here.
            return connection
        } catch {
            // swiftlint:disable:next swallowed_try -- the test's own error is the one reported.
            try? await group.shutdownGracefully()
            throw error
        }
    }

    final class Sink: @unchecked Sendable { weak var target: TestConnection? }
    final class Collect: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let sink: Sink
        init(sink: Sink) { self.sink = sink }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            sink.target?.add(Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
        }
        func channelInactive(context: ChannelHandlerContext) { sink.target?.end() }
        func errorCaught(context: ChannelHandlerContext, error: any Error) { sink.target?.end(); context.close(promise: nil) }
    }

    private func add(_ data: Data) { lock.lock(); received.append(data); lock.unlock() }
    private func end() { lock.lock(); closed = true; lock.unlock() }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func close() async {
        try? await channel.close()
        // swiftlint:disable:next swallowed_try -- shutting a test client down.
        try? await group.shutdownGracefully()
    }

    func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    func request(_ method: String, _ path: String, headers: [String: String] = [:], body: Data = Data(), close: Bool = false,
                 host: String? = nil, raw extra: String = "") async throws -> Answer {
        var text = "\(method) \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n"
        if close { text += "Connection: close\r\n" }
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if !body.isEmpty || method == "POST" { text += "Content-Length: \(body.count)\r\n" }
        text += extra + "\r\n"
        try await write(Data(text.utf8) + body)
        return try await readAnswer()
    }

    /// What has arrived, under the lock, for code that can't hold one across an await.
    private func withBuffer<T>(_ body: (inout Data, Bool) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&received, closed) }

    private static func headLength(_ data: Data) -> (head: String, end: Int, body: Int)? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
        let status = head.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        let length = status == 101 ? 0 : head.split(separator: "\r\n").compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "content-length" ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first ?? 0
        return (head, range.upperBound, length)
    }

    /// The next HTTP answer, whole.
    func readAnswer() async throws -> Answer {
        let ready = await eventually(20) {
            withBuffer { data, closed in
                guard let parsed = Self.headLength(data) else { return closed }
                return data.count >= parsed.end + parsed.body || closed
            }
        }
        let answer: Answer? = withBuffer { data, _ in
            guard ready, let parsed = Self.headLength(data) else { return nil }
            let end = min(data.count, parsed.end + parsed.body)
            let body = Data(data[parsed.end..<end])
            data = Data(data[end...])
            let status = parsed.head.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            return Answer(status: status, headers: parsed.head, body: body)
        }
        guard let answer else { throw Refused(reason: "no answer") }
        return answer
    }

    struct Refused: Error, Equatable { let reason: String }

    // MARK: WebSocket

    static func key() -> String { Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString() }

    func upgrade(_ path: String, token: String) async throws -> Answer {
        try await request("GET", path, headers: ["Authorization": "Bearer \(token)", "Upgrade": "websocket", "Connection": "Upgrade",
                                                  "Sec-WebSocket-Key": Self.key(), "Sec-WebSocket-Version": "13"])
    }

    func send(text: String) async throws {
        try await write(WebSocketFrames.frame(.text, Data(text.utf8), from: .client))
    }

    private func pump() -> (opcode: WebSocketFrames.Opcode, payload: Data)? {
        lock.lock(); defer { lock.unlock() }
        if !received.isEmpty { frames.append(received); received = Data() }
        if case .success(let next)? = frames.next() { return next }
        return nil
    }

    /// The next frame from the server.
    func frame() async throws -> (opcode: WebSocketFrames.Opcode, payload: Data) {
        var found: (opcode: WebSocketFrames.Opcode, payload: Data)?
        await eventually(20) {
            found = pump()
            return found != nil || isClosed
        }
        if found == nil { found = pump() }
        guard let found else { throw Refused(reason: "no frame") }
        return found
    }

    /// The next text frame, ignoring pings.
    func event() async throws -> [String: Any] {
        while true {
            let next = try await frame()
            if next.opcode == .text, let object = (try JSONSerialization.jsonObject(with: next.payload)) as? [String: Any] { return object }
            if next.opcode == .close { throw Refused(reason: "closed \(next.payload.prefix(2).map { String($0) }.joined(separator: ","))") }
        }
    }

    func closeCode() async -> UInt16? {
        while let next = try? await frame() {
            if next.opcode == .close, next.payload.count >= 2 { return UInt16(next.payload[next.payload.startIndex]) << 8 | UInt16(next.payload[next.payload.startIndex + 1]) }
        }
        return nil
    }
}

func temporaryDirectory(_ label: String = "sd") throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/\(label)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}

/// A daemon on port 0 over loopback, in a state directory of its own, with no discovery.
func withDaemon<T>(services: any DaemonServices = NoServices(), _ body: (SideADaemon, URL) async throws -> T) async throws -> T {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = DaemonConfig(paths: DaemonPaths(state: directory))
    config.port = 0
    config.discover = false
    config.os = .linux
    let daemon = try SideADaemon(config: config, services: services)
    try await daemon.start()
    do {
        let result = try await body(daemon, directory)
        try await daemon.stop()
        return result
    } catch {
        // swiftlint:disable:next swallowed_try -- the test's own error is the one reported.
        try? await daemon.stop()
        throw error
    }
}

/// One iPhone's half of pairing, with real keys: what `SideARemoteKit` does, without Network.framework.
struct FakePhone {
    let deviceID = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64URL
    let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    var secretHash: String { Data(SHA256.hash(data: secret)).base64URL }
    let key = Curve25519.KeyAgreement.PrivateKey()
    /// Signs `X-SideA-Confirm` as the phone's unlock key does (its Secure Enclave key, here in software).
    let unlock = P256.Signing.PrivateKey()
    var unlockKey: String { unlock.publicKey.x963Representation.base64URL }
    /// And as the Face ID key does.
    let biometric = P256.Signing.PrivateKey()
    var confirmKey: String { biometric.publicKey.x963Representation.base64URL }
    let name = "Test iPhone"

    func request(code: String, spki: String) -> PairRequest {
        PairRequest(code: code, device: DeviceInfo(name: name, model: "iPhone18,1", system: "iOS 27.0", app: "1.0", build: 40, capabilities: [.events]),
                    deviceID: deviceID, devicePublicKey: key.publicKey.rawRepresentation.base64URL,
                    deviceSecretHash: Data(SHA256.hash(data: secret)).base64URL, serverKeyHash: spki, confirmKey: confirmKey, unlockKey: unlockKey)
    }

    /// The header for a call that needs the unlock key, or with `biometric` the Face ID key.
    func confirm(purpose: ConfirmPurpose, subject: String, biometric face: Bool = false, at: Int = Int(Date().timeIntervalSince1970)) throws -> String {
        let text = try ConfirmMessage.text(macID: HostInfo.machineID(), deviceID: deviceID, purpose: purpose, subject: subject, at: at)
        let signature = try (face ? biometric : unlock).signature(for: Data(text.utf8))
        return ConfirmSignature(at: at, signer: face ? .confirm : .unlock, signature: signature.derRepresentation).headerValue
    }

    /// Pairs with `daemon` as the person at the machine would confirm it. Returns the token.
    func pair(with daemon: SideADaemon, pin: String, confirm: Bool = true) async throws -> PairResponse {
        await daemon.pairing.open()
        let code = try #require(await daemon.pairing.currentCode)
        let connection = try await TestConnection.open(port: daemon.port, pin: pin)
        let body = try JSONEncoder().encode(request(code: code, spki: pin))
        let pending = try await connection.request("POST", "/v1/pair", headers: ["Content-Type": "application/json"], body: body)
        #expect(pending.status == 202)
        let attempt = try pending.json(PairPending.self)
        let waiter = try await TestConnection.open(port: daemon.port, pin: pin)
        async let finished = waiter.request("POST", "/v1/pair/\(attempt.attemptID)/wait")
        #expect(await eventually { await daemon.pairing.attempt != nil })
        let shown = try #require(await daemon.pairing.attempt?.comparison)
        // The phone computes the same digits from what it was sent.
        let phones = try PairingTranscript.display(PairingTranscript.comparisonCode(
            code: code, nonce: attempt.nonce, macPublicKey: attempt.macPublicKey, devicePublicKey: key.publicKey.rawRepresentation.base64URL, serverKeyHash: pin,
            confirmKey: confirmKey, unlockKey: unlockKey))
        #expect(shown == phones)
        await daemon.pairing.decide(confirm ? .pair : .cancel)
        let answer = try await finished
        await connection.close(); await waiter.close()
        guard confirm else { throw TestConnection.Refused(reason: "declined \(answer.status)") }
        #expect(answer.status == 201)
        return try answer.json(PairResponse.self)
    }
}
