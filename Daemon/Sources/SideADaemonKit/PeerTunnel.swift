import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import SideACore
import SideAProtocol

/// Another computer reached through its relay tunnel, for when none of its own addresses answers (docs/remote/tunnel.md,
/// The phone). A linked computer is a device of the other one, so this computer dials the other's install in the phone's
/// role, with the device id and secret the link carries; the relay needs no change for it. Each request is one stream on
/// one WebSocket, spliced to a socket pair whose other end carries the pinned TLS, so the relay moves bytes it can't read
/// and the other computer checks the pin and the token exactly as on its tailnet address. One per linked computer per
/// process; everything here runs on `loop`.
final class PeerTunnel: @unchecked Sendable {
    /// What a link carries for the relay path: where the other computer's install is, and who this computer is there.
    struct Route: Hashable, Sendable {
        let url: URL
        let installID: String
        let deviceID: String
        /// base64url of the 32-byte device secret, whose SHA-256 the other computer registered with the relay.
        let secret: String

        init?(relay: RelayInfo?, deviceID: String, secret: String) {
            guard let relay, let url = URL(string: relay.url), Self.allowed(url), Self.wellFormed(relay.installID), Self.wellFormed(deviceID),
                  secret.count == 43, Data(base64URL: secret)?.count == 32 else { return nil }
            self.url = url; installID = relay.installID; self.deviceID = deviceID; self.secret = secret
        }

        /// Where a relay credential may go, as on the phone: https, or plain http to this machine for a relay in a test.
        static func allowed(_ url: URL) -> Bool {
            url.scheme == "https" || (url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost"))
        }

        /// The relay's ids are 16 bytes in base64url.
        static func wellFormed(_ id: String) -> Bool {
            id.count == 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }

        var authorization: String { "Bearer d1.\(installID).\(deviceID).\(secret)" }

        var path: String {
            let base = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
            return base + "/v1/tunnel/phone"
        }
    }

    static let openWithin: TimeAmount = .seconds(8)
    /// A socket with no stream left closes after this; a move's next request usually comes well within it.
    static let idleFor: TimeAmount = .seconds(60)
    static let pingEvery: TimeAmount = .seconds(25)
    static let pongWithin: TimeAmount = .seconds(10)
    /// The other computer takes eight streams from one socket and resets the rest.
    static let maxStreams = 8

    private static let lock = NSLock()
    nonisolated(unsafe) private static var tunnels: [Route: PeerTunnel] = [:]

    static func shared(_ route: Route) -> PeerTunnel {
        lock.withLock {
            if let known = tunnels[route] { return known }
            let made = PeerTunnel(route)
            tunnels[route] = made
            return made
        }
    }

    private enum State { case closed, opening, open(online: Bool) }

    let route: Route
    let loop: any EventLoop
    private var state = State.closed
    private var channel: (any Channel)?
    private var generation = 0
    private var waiters: [EventLoopPromise<Void>] = []
    private lazy var splice: TunnelSplice = {
        let splice = TunnelSplice { [weak self] in self?.sendFrame($0) }
        splice.ended = { [weak self] _ in self?.armIdle() }
        return splice
    }()
    private var nextStream: UInt32 = 0
    private var idle: Scheduled<Void>?
    private var pinger: RepeatedTask?
    private var lastHeard = Date.distantPast

    private init(_ route: Route) {
        self.route = route
        loop = MultiThreadedEventLoopGroup.singleton.next()
    }

    /// A connected socket whose other end is a new stream to the other computer. Throws `PeerFailure.unreachable` when the
    /// relay can't be reached, refuses this computer, or says the other one isn't connected to it.
    func dial() async throws -> NIOBSDSocket.Handle {
        let ready = loop.makePromise(of: Void.self)
        loop.execute { [self] in
            idle?.cancel(); idle = nil
            switch state {
            case .open(online: true): ready.succeed(())
            case .open(online: false):
                ready.fail(PeerFailure.unreachable)
                armIdle()
            case .opening: waiters.append(ready)
            case .closed:
                waiters.append(ready)
                connect()
            }
        }
        try await ready.futureResult.get()
        return try await loop.flatSubmit { self.stream() }.get()
    }

    var streamCount: Int { get async { (try? await loop.submit { self.splice.count }.get()) ?? 0 } }

    // MARK: The socket

    private func connect() {
        state = .opening
        generation += 1
        let generation = generation
        guard let host = route.url.host else { return drop(generation, "the relay address has no host") }
        let secure = route.url.scheme == "https"
        let port = route.url.port ?? (secure ? 443 : 80)
        let context: NIOSSLContext?
        do { context = secure ? try NIOSSLContext(configuration: .makeClientConfiguration()) : nil } catch { return drop(generation, "no TLS for the relay") }
        let socket = PeerSocket(owner: self, generation: generation, path: route.path, host: port == (secure ? 443 : 80) ? host : "\(host):\(port)",
                                authorization: route.authorization)
        ClientBootstrap(group: loop)
            .connectTimeout(.seconds(5))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let context { try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: host)) }
                    try channel.pipeline.syncOperations.addHandler(socket)
                }
            }
            .connect(host: host, port: port)
            .whenComplete { [self] result in
                guard generation == self.generation else {
                    if case .success(let channel) = result { channel.close(promise: nil) }
                    return
                }
                switch result {
                case .success(let channel): self.channel = channel
                case .failure: drop(generation, "the relay couldn't be reached")
                }
            }
        loop.scheduleTask(in: Self.openWithin) { [weak self] in
            guard let self, generation == self.generation, case .opening = self.state else { return }
            self.drop(generation, "the relay didn't answer")
        }
    }

    /// Everything on the socket ends, and whoever waits for it is told the other computer can't be reached.
    private func drop(_ generation: Int, _ reason: String) {
        guard generation == self.generation else { return }
        if case .opening = state { DaemonLog.line("a linked computer's relay path: \(reason)") }
        self.generation += 1
        state = .closed
        pinger?.cancel(); pinger = nil
        idle?.cancel(); idle = nil
        channel?.close(promise: nil)
        channel = nil
        splice.drop()
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.fail(PeerFailure.unreachable) }
    }

    fileprivate func refused(_ generation: Int, status: Int) {
        drop(generation, status == 401 ? "the relay doesn't know this computer as a device of that one" : "the relay answered \(status)")
    }

    fileprivate func closed(_ generation: Int) { drop(generation, "the relay closed the connection") }

    fileprivate func message(_ generation: Int, _ message: WebSocketCodec.Message) {
        guard generation == self.generation else { return }
        lastHeard = Date()
        switch message {
        case .text(let text):
            guard text != "pong", let control = TunnelControl(text: text), control.type == "mac", let online = control.online else { return }
            changed(online: online)
        case .binary(let data):
            guard let frame = TunnelFrame(data), frame.kind != .open else { return }
            splice.received(frame)
        case .ping(let payload): writeFrame(.pong, payload)
        case .pong, .close: break
        }
    }

    /// The relay says whether the other computer is connected to it: first right after the upgrade, then on each change.
    private func changed(online: Bool) {
        if !online { splice.drop() }
        if case .opening = state {
            pinger = loop.scheduleRepeatedTask(initialDelay: Self.pingEvery, delay: Self.pingEvery) { [weak self] _ in self?.ping() }
        }
        state = .open(online: online)
        let waiting = waiters
        waiters = []
        for waiter in waiting { if online { waiter.succeed(()) } else { waiter.fail(PeerFailure.unreachable) } }
        armIdle()
    }

    private func ping() {
        guard channel != nil else { return }
        let sent = Date(), generation = generation
        writeFrame(.text, Data("ping".utf8))
        loop.scheduleTask(in: Self.pongWithin) { [weak self] in
            guard let self, generation == self.generation, self.lastHeard < sent else { return }
            self.drop(generation, "the relay stopped answering")
        }
    }

    private func armIdle() {
        guard splice.isEmpty, channel != nil else { return }
        idle?.cancel()
        let generation = generation
        idle = loop.scheduleTask(in: Self.idleFor) { [weak self] in
            guard let self, generation == self.generation, self.splice.isEmpty else { return }
            self.drop(generation, "idle")
        }
    }

    private func writeFrame(_ opcode: WebSocketFrames.Opcode, _ payload: Data) {
        channel?.writeAndFlush(ByteBuffer(bytes: WebSocketFrames.frame(opcode, payload, from: .client)), promise: nil)
    }

    private func sendFrame(_ frame: TunnelFrame) { writeFrame(.binary, frame.encoded) }

    // MARK: Streams

    #if os(Linux)
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    private static let streamType = SOCK_STREAM
    #endif

    /// A socket pair: one end is spliced to a new stream, the other is returned for the TLS client to run on.
    private func stream() -> EventLoopFuture<NIOBSDSocket.Handle> {
        guard case .open(online: true) = state, channel != nil, splice.count < Self.maxStreams else {
            armIdle()
            return loop.makeFailedFuture(PeerFailure.unreachable)
        }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Self.streamType, 0, &pair) == 0 else { return loop.makeFailedFuture(PeerFailure.unreachable) }
        let (mine, spliced) = (pair[0], pair[1])
        let id = nextID(), generation = generation
        return ClientBootstrap(group: loop)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelInitializer { [weak self] channel in
                channel.pipeline.addHandler(TunnelLocalSide(read: { self?.localRead(id, generation, $0) }, ended: { self?.localEnded(id, generation, failed: $0) }))
            }
            .withConnectedSocket(spliced)
            .flatMapThrowing { [self] local in
                guard generation == self.generation, case .open(online: true) = state else {
                    local.close(promise: nil)
                    throw PeerFailure.unreachable
                }
                sendFrame(TunnelFrame(.open, id))
                splice.attach(id, local)
                local.read()
                return mine
            }
            .flatMapErrorThrowing { _ in
                Self.release(mine)
                throw PeerFailure.unreachable
            }
    }

    private static func release(_ descriptor: Int32) { _ = close(descriptor) }

    /// 1…65535, wrapping, never one that is open.
    private func nextID() -> UInt32 {
        let live = Set(splice.ids)
        repeat { nextStream = nextStream >= 0xffff ? 1 : nextStream + 1 } while live.contains(nextStream)
        return nextStream
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

/// The upgrade to `/v1/tunnel/phone` with the device's relay credential, then the socket's messages.
private final class PeerSocket: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private weak var owner: PeerTunnel?
    private let generation: Int
    private let path: String
    private let host: String
    private let authorization: String
    private let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    private var head = Data()
    private var upgraded = false
    private var parser = WebSocketFrames(role: .client, maxMessage: 1 << 20, strict: true)

    init(owner: PeerTunnel, generation: Int, path: String, host: String, authorization: String) {
        self.owner = owner; self.generation = generation; self.path = path; self.host = host; self.authorization = authorization
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
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
        let accept = lines.dropFirst().first { $0.lowercased().hasPrefix("sec-websocket-accept:") }
            .map { $0.dropFirst("sec-websocket-accept:".count).trimmingCharacters(in: .whitespaces) }
        guard status == 101, accept == WebSocketFrames.acceptKey(nonce) else {
            owner?.refused(generation, status: status)
            context.close(promise: nil)
            return
        }
        upgraded = true
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
                    owner?.closed(generation)
                    context.close(promise: nil)
                    return
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) { owner?.closed(generation) }

    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}
