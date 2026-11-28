import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import SideACore
import SideAProtocol

/// The daemon's end of the relay tunnel (docs/remote/tunnel.md, The Mac): one outbound WebSocket to the install's object at
/// the relay, each stream on it spliced to the daemon's own loopback TLS listener. The phone's TLS ends there exactly as
/// on the LAN, so the pin, the token and every check are the same; this only moves bytes it can't read.
///
/// The Mac's `TunnelClient` and `TunnelMux` are the same thing on Network.framework; this one is on NIO, which is what a
/// Linux host has. Both speak `TunnelFrame` and `TunnelControl` from SideAProtocol. Everything here runs on `loop`.
final class RelayTunnel: @unchecked Sendable {
    enum Status: Sendable, Equatable {
        case off, connecting, connected
        case waiting(String)
    }

    static let perSlot = 8
    static let total = 24
    static let pingEvery: TimeAmount = .seconds(25)
    static let pongWithin: TimeAmount = .seconds(10)
    static let backoffCap = 60.0
    static let clockWindow = 120.0
    static let trace = ProcessInfo.processInfo.environment["SIDEAD_TUNNEL_TRACE"] != nil

    let loop: any EventLoop
    private let url: URL
    private let key: Curve25519.Signing.PrivateKey
    private let register: @Sendable () async throws -> Void
    private let target: @Sendable () -> UInt16?
    private let tls: NIOSSLContext?
    var statusChanged: (@Sendable (Status) -> Void)?

    private var running = false
    private var generation = 0
    private var attempt = 0
    private var skew = 0
    private var signed = 0
    private var reclocked = false
    private var registered = false
    private var channel: (any Channel)?
    private var session: TunnelSession?
    private var devices: [TunnelControl.Device]?
    private var ticket: Data?
    private var retry: Scheduled<Void>?
    private var pinger: RepeatedTask?
    private var lastPong = Date.distantPast
    private lazy var splice = TunnelSplice { [weak self] in self?.sendFrame($0) }
    private var opening: [UInt32: [TunnelFrame]] = [:]
    private(set) var status: Status = .off

    init(base: URL, key: Curve25519.Signing.PrivateKey, loop: any EventLoop, register: @escaping @Sendable () async throws -> Void,
         target: @escaping @Sendable () -> UInt16?) throws {
        self.url = base; self.key = key; self.loop = loop; self.register = register; self.target = target
        tls = base.scheme == "https" ? try NIOSSLContext(configuration: .makeClientConfiguration()) : nil
    }

    // MARK: Driving it

    func start() {
        loop.execute { [self] in
            guard !running else { return }
            running = true
            connect()
        }
    }

    /// Leaving on purpose: the relay is told why before the socket goes, so it doesn't call this computer quiet to the phones.
    func stop(goodbye reason: String? = nil) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            loop.execute { [self] in
                if let reason { sendText(TunnelControl.goodbye(reason).text) }
                running = false
                retry?.cancel()
                drop()
                set(.off)
                done.resume()
            }
        }
    }

    func setDevices(_ devices: [TunnelControl.Device]) {
        loop.execute { [self] in
            self.devices = devices
            sendText(TunnelControl(type: "devices", devices: devices).text)
        }
    }

    func setPairing(ticket: Data?) {
        loop.execute { [self] in
            self.ticket = ticket
            sendText(pairing.text)
        }
    }

    func networkChanged() {
        loop.execute { [self] in
            guard running else { return }
            if channel == nil { retry?.cancel(); attempt = 0; connect() } else { ping() }
        }
    }

    func streamCount() async -> Int { (try? await loop.submit { self.splice.count }.get()) ?? 0 }

    private var pairing: TunnelControl {
        guard let ticket else { return TunnelControl(type: "pairing") }
        return TunnelControl(type: "pairing", ticketHash: Data(SHA256.hash(data: ticket)).base64URL, expiresAt: Date().timeIntervalSince1970 + 120)
    }

    private func set(_ next: Status) {
        guard next != status else { return }
        status = next
        statusChanged?(next)
    }

    // MARK: The socket

    private func connect() {
        guard running, channel == nil else { return }
        set(.connecting)
        generation += 1
        let generation = generation
        let register = register
        Task {
            let known = (try? await loop.submit { self.registered }.get()) ?? false
            if !known {
                do { try await register() } catch {
                    return loop.execute { [self] in
                        guard generation == self.generation else { return }
                        fail("Can't reach the relay: \(error)", unregistered: false)
                    }
                }
                loop.execute { [self] in registered = true }
            }
            loop.execute { [self] in
                guard running, generation == self.generation else { return }
                open(generation)
            }
        }
    }

    private func open(_ generation: Int) {
        guard let host = url.host else { return fail("The relay address has no host", unregistered: false) }
        let secure = tls != nil
        let port = url.port ?? (secure ? 443 : 80)
        let ts = Int(Date().timeIntervalSince1970) + skew
        signed = ts
        guard let authorization = try? RelaySignature.authorization(key, method: "GET", path: "/v1/tunnel/mac", body: Data(), ts: ts) else {
            return fail("The relay key can't sign", unregistered: false)
        }
        let session = TunnelSession(owner: self, generation: generation, host: port == (secure ? 443 : 80) ? host : "\(host):\(port)", authorization: authorization)
        self.session = session
        let context = tls
        ClientBootstrap(group: loop)
            .channelInitializer { channel in
                do {
                    if let context { try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: host)) }
                    try channel.pipeline.syncOperations.addHandler(session)
                    return channel.eventLoop.makeSucceededFuture(())
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }
            .connect(host: host, port: port)
            .whenComplete { [self] result in
                guard generation == self.generation else { if case .success(let channel) = result { channel.close(promise: nil) }; return }
                switch result {
                case .success(let channel): self.channel = channel
                case .failure(let error): fail(String(describing: error), unregistered: false)
                }
            }
    }

    /// The upgrade went through: first, so the relay may tell the phones if this computer goes quiet; then what it needs to let a
    /// phone in.
    fileprivate func upgraded(_ generation: Int) {
        guard generation == self.generation else { return }
        sendText(TunnelControl.watch.text)
        if let devices { sendText(TunnelControl(type: "devices", devices: devices).text) }
        if ticket != nil { sendText(pairing.text) }
        pinger?.cancel()
        pinger = loop.scheduleRepeatedTask(initialDelay: Self.pingEvery, delay: Self.pingEvery) { [weak self] _ in self?.ping() }
        lastPong = Date()
        ping()
    }

    fileprivate func refused(_ generation: Int, status: Int, date: String?) {
        guard generation == self.generation else { return }
        let relayNow = date.flatMap(RelayHTTP.httpDate)
        if let relayNow { skew = Int(relayNow.timeIntervalSinceNow.rounded()) }
        switch status {
        case 401 where relayNow.map({ abs($0.timeIntervalSince1970 - Double(signed)) > Self.clockWindow - 2 }) == true:
            guard reclocked else { reclocked = true; drop(); return connect() }
            fail("This computer's clock is too far from the relay's", unregistered: false)
        case 401: fail("The relay didn't recognise this computer", unregistered: true)
        case 503: fail("The relay's tunnel is paused", unregistered: false, wait: 300)
        default: fail("The relay answered \(status)", unregistered: false)
        }
    }

    fileprivate func closed(_ generation: Int, code: UInt16?, reason: String) {
        guard generation == self.generation else { return }
        switch code {
        case 4409: fail("Replaced by a newer connection", unregistered: false)
        case 4401: fail("The relay key changed", unregistered: false)
        default: fail(reason.isEmpty ? "The relay closed the connection" : reason, unregistered: false)
        }
    }

    fileprivate func message(_ generation: Int, _ message: WebSocketCodec.Message) {
        guard generation == self.generation else { return }
        if status != .connected { attempt = 0; reclocked = false; set(.connected) }
        lastPong = Date()
        switch message {
        case .text(let text): control(text)
        case .binary(let data): frame(data)
        case .ping(let payload): writeFrame(.pong, payload)
        case .pong, .close: break
        }
    }

    private func fail(_ reason: String, unregistered: Bool, wait: Double? = nil) {
        drop()
        if unregistered { registered = false }
        guard running else { return }
        set(.waiting(reason))
        let delay = wait ?? min(Self.backoffCap, pow(2, Double(attempt))) * Double.random(in: 0.8...1.2)
        attempt += 1
        retry = loop.scheduleTask(in: .milliseconds(Int64(delay * 1000))) { [weak self] in self?.connect() }
    }

    private func drop() {
        generation += 1
        pinger?.cancel(); pinger = nil
        channel?.close(promise: nil)
        channel = nil
        session = nil
        opening = [:]
        splice.drop()
    }

    private func writeFrame(_ opcode: WebSocketFrames.Opcode, _ payload: Data) {
        guard let channel else { return }
        channel.writeAndFlush(ByteBuffer(bytes: WebSocketFrames.frame(opcode, payload, from: .client)), promise: nil)
    }

    private func sendText(_ text: String) { writeFrame(.text, Data(text.utf8)) }
    private func sendFrame(_ frame: TunnelFrame) {
        if Self.trace { FileHandle.standardError.write(Data("sidead: tunnel out \(frame.kind) stream \(frame.stream) \(frame.payload.count) bytes\n".utf8)) }
        writeFrame(.binary, frame.encoded)
    }

    /// A text `ping`, answered by the relay without waking the object; any message counts as the answer.
    private func ping() {
        guard channel != nil else { return }
        let sent = Date()
        let generation = generation
        sendText("ping")
        if ticket != nil { sendText(pairing.text) }
        loop.scheduleTask(in: Self.pongWithin) { [weak self] in
            guard let self, generation == self.generation, self.channel != nil, self.lastPong < sent else { return }
            self.fail("The relay stopped answering", unregistered: false)
        }
    }

    private func control(_ text: String) {
        guard text != "pong", let control = TunnelControl(text: text) else { return }
        if control.type == "gone", let value = control.slot, let slot = UInt32(exactly: value), slot <= 0xffff {
            for id in opening.keys.filter({ $0 >> 16 == slot }) { opening[id] = nil }
            for id in splice.ids where id >> 16 == slot { splice.end(id) }
        }
    }

    // MARK: Streams

    private func frame(_ data: Data) {
        guard let frame = TunnelFrame(data) else { return }
        if Self.trace { FileHandle.standardError.write(Data("sidead: tunnel in \(frame.kind) stream \(frame.stream) \(frame.payload.count) bytes\n".utf8)) }
        if frame.kind == .open { return open(frame) }
        if var waiting = opening[frame.stream] {
            guard waiting.reduce(frame.payload.count, { $0 + $1.payload.count }) <= TunnelSplice.window, waiting.count < 64 else {
                opening[frame.stream] = nil
                return sendFrame(.reset(frame.stream, "over credit"))
            }
            waiting.append(frame)
            opening[frame.stream] = waiting
            return
        }
        splice.received(frame)
    }

    private func open(_ frame: TunnelFrame) {
        let slot = frame.stream >> 16
        let fromSlot = splice.ids.filter { $0 >> 16 == slot }.count + opening.keys.filter { $0 >> 16 == slot }.count
        guard splice.count + opening.count < Self.total, fromSlot < Self.perSlot else {
            return sendFrame(.reset(frame.stream, "too_many_streams"))
        }
        guard let port = target() else { return sendFrame(.reset(frame.stream, "mac_not_listening")) }
        opening[frame.stream] = []
        let generation = generation, id = frame.stream
        ClientBootstrap(group: loop)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { [weak self] channel in
                channel.pipeline.addHandler(TunnelLocalSide(read: { self?.localRead(id, generation, $0) }, ended: { self?.localEnded(id, generation, failed: $0) }))
            }
            .connect(host: "127.0.0.1", port: Int(port))
            .whenComplete { [self] result in
                guard generation == self.generation, let waiting = opening.removeValue(forKey: id) else {
                    if case .success(let channel) = result { channel.close(promise: nil) }
                    return
                }
                switch result {
                case .failure(let error):
                    FileHandle.standardError.write(Data("sidead: relay stream \(id) couldn't reach the local listener: \(error)\n".utf8))
                    sendFrame(.reset(id, "mac_not_listening"))
                case .success(let channel):
                    let stream = splice.attach(id, channel)
                    for queued in waiting { splice.received(queued) }
                    if splice.has(stream) { channel.read() }
                }
            }
    }

    private func localRead(_ id: UInt32, _ generation: Int, _ bytes: ByteBuffer) {
        guard generation == self.generation else { return }
        splice.read(id, bytes)
    }

    private func localEnded(_ id: UInt32, _ generation: Int, failed: Bool) {
        guard generation == self.generation else { return }
        splice.localEnded(id, failed: failed)
    }
}

/// The upgrade to a WebSocket on the relay's connection, then its frames.
private final class TunnelSession: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private weak var owner: RelayTunnel?
    private let generation: Int
    private let host: String
    private let authorization: String
    private let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    private var head = Data()
    private var upgraded = false
    private var parser = WebSocketFrames(role: .client, maxMessage: 1 << 20, strict: true)

    init(owner: RelayTunnel, generation: Int, host: String, authorization: String) {
        self.owner = owner; self.generation = generation; self.host = host; self.authorization = authorization
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = "GET /v1/tunnel/mac HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(nonce)\r\nSec-WebSocket-Version: 13\r\nAuthorization: \(authorization)\r\n\r\n"
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: request)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        if upgraded { return feed(bytes, context) }
        head.append(bytes)
        guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
            if head.count > 16 << 10 { context.close(promise: nil) }
            return
        }
        let text = String(decoding: head[..<end.lowerBound], as: UTF8.self)
        let rest = Data(head[end.upperBound...])
        head = Data()
        let lines = text.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard status == 101, fields["sec-websocket-accept"] == WebSocketFrames.acceptKey(nonce) else {
            let (owner, generation, date) = (owner, generation, fields["date"])
            context.eventLoop.execute { owner?.refused(generation, status: status, date: date) }
            context.close(promise: nil)
            return
        }
        upgraded = true
        owner?.upgraded(generation)
        if !rest.isEmpty { feed(rest, context) }
    }

    private func feed(_ bytes: Data, _ context: ChannelHandlerContext) {
        parser.append(bytes)
        while let next = parser.next() {
            switch next {
            case .failure: return context.close(promise: nil)
            case .success(let frame):
                switch frame.opcode {
                case .text: owner?.message(generation, .text(String(decoding: frame.payload, as: UTF8.self)))
                case .binary, .continuation: owner?.message(generation, .binary(frame.payload))
                case .ping: owner?.message(generation, .ping(frame.payload))
                case .pong: owner?.message(generation, .pong(frame.payload))
                case .close:
                    let code = frame.payload.count >= 2 ? UInt16(frame.payload[frame.payload.startIndex]) << 8 | UInt16(frame.payload[frame.payload.startIndex + 1]) : nil
                    owner?.closed(generation, code: code, reason: String(decoding: frame.payload.dropFirst(2), as: UTF8.self))
                    context.close(promise: nil)
                    return
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if upgraded { owner?.closed(generation, code: nil, reason: "") }
        else if !head.isEmpty || owner != nil { owner?.closed(generation, code: nil, reason: "The relay closed the connection") }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}
