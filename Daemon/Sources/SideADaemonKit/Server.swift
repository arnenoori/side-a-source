import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import SideACore

/// An HTTPS server for the Side A Remote protocol on SwiftNIO and NIOSSL. The HTTP/1.1 parsing is `HTTPParser` from
/// SideACore, the same code the Mac's `NWListener` front uses, so a request that parses on the Mac parses here, with the
/// same limits and the same refusals; NIO supplies only the sockets, TLS and event loops. (NIOHTTP1 would be a second
/// parser to keep in step with the first, and it accepts chunked bodies and `Expect`, which the protocol refuses.)
/// After a 101 the same connection carries WebSocket frames, parsed by SideACore's `WebSocketCodec`.
public final class DaemonServer: Sendable {
    /// What a route may know about the connection its request came in on.
    public struct Connection: Sendable {
        public let id: UInt64
        public let localPort: Int
        /// The peer's address without a port; what per-address limits are keyed on.
        public let source: String
    }

    public enum Reply: Sendable {
        case response(HTTPResponse)
        /// A 101; `open` runs on the connection's event loop with the socket, before any frame is read.
        case upgrade(HTTPResponse, open: @Sendable (SocketPeer) -> Void)
    }

    public typealias Handler = @Sendable (HTTPRequest, Connection) async -> Reply

    static let unauthenticatedBody = 64 << 10

    private let group: MultiThreadedEventLoopGroup
    private let channels: [any Channel]
    public let identity: DaemonIdentity
    public let port: Int

    private init(group: MultiThreadedEventLoopGroup, channels: [any Channel], identity: DaemonIdentity, port: Int) {
        self.group = group; self.channels = channels; self.identity = identity; self.port = port
    }

    /// Binds every address on `port` (0 picks a free one for the first, and the rest follow it) and answers with `handler`.
    /// `stamp` adds the headers every response carries.
    public static func start(identity: DaemonIdentity, addresses: [String] = ["127.0.0.1"], port: Int = 0, threads: Int = 2,
                             stamp: @escaping @Sendable (inout HTTPResponse) -> Void = { _ in }, handler: @escaping Handler) async throws -> DaemonServer {
        let context = try NIOSSLContext(configuration: identity.serverConfiguration())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: threads)
        let ids = IDSource()
        var bound: [any Channel] = []
        do {
            var chosen = port
            for address in addresses {
                let channel = try await ServerBootstrap(group: group)
                    .serverChannelOption(.backlog, value: 64)
                    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                            try channel.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: .seconds(30)))
                            try channel.pipeline.syncOperations.addHandler(HTTPConnection(id: ids.next(), handler: handler, stamp: stamp))
                        }
                    }
                    .bind(host: address, port: chosen).get()
                bound.append(channel)
                chosen = channel.localAddress?.port ?? chosen
            }
            return DaemonServer(group: group, channels: bound, identity: identity, port: chosen)
        } catch {
            for channel in bound { try? await channel.close() }
            // swiftlint:disable:next swallowed_try -- the bind error is the one reported; a failed shutdown adds nothing.
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func stop() async throws {
        for channel in channels { try await channel.close() }
        try await group.shutdownGracefully()
    }
}

final class IDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

/// One connection: bytes in, `HTTPParser`, the handler, an answer written whole with a Content-Length, strictly in order.
/// A request the parser refuses gets its status and the connection closes, as on the Mac.
final class HTTPConnection: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let maxQueued = 4
    static let requestsPerConnection = 1_000

    private let id: UInt64
    private let handler: DaemonServer.Handler
    private let stamp: @Sendable (inout HTTPResponse) -> Void
    private var parser = HTTPParser { head in head.headers["Authorization"] == nil ? DaemonServer.unauthenticatedBody : nil }
    private var queued: [HTTPRequest] = []
    private var busy = false
    private var closing = false
    private var served = 0
    private var peer: SocketPeer?

    init(id: UInt64, handler: @escaping DaemonServer.Handler, stamp: @escaping @Sendable (inout HTTPResponse) -> Void) {
        self.id = id; self.handler = handler; self.stamp = stamp
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        if let peer { peer.received(bytes); return }
        guard !closing else { return }
        for result in parser.feed(bytes) {
            switch result {
            case .success(let request):
                queued.append(request)
            case .failure(let error):
                queued.removeAll()
                closing = true
                var response = HTTPResponse.apiError(error.status, .badRequest, error.message)
                stamp(&response)
                write(context, response, close: true)
                return
            }
        }
        if queued.count > Self.maxQueued { context.close(promise: nil); return }
        next(context)
    }

    private func next(_ context: ChannelHandlerContext) {
        guard !busy, !closing, !queued.isEmpty else { return }
        let request = queued.removeFirst()
        busy = true
        served += 1
        let connection = DaemonServer.Connection(id: id, localPort: context.localAddress?.port ?? 0, source: context.remoteAddress?.ipAddress ?? "")
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        let box = NIOLoopBound(self, eventLoop: context.eventLoop)
        let handler = handler
        let loop = context.eventLoop
        Task {
            let reply = await handler(request, connection)
            loop.execute { box.value.finish(bound.value, request, reply, connection) }
        }
    }

    private func finish(_ context: ChannelHandlerContext, _ request: HTTPRequest, _ reply: DaemonServer.Reply, _ connection: DaemonServer.Connection) {
        busy = false
        switch reply {
        case .response(var response):
            stamp(&response)
            let close = !request.keepAlive || served >= Self.requestsPerConnection
            write(context, response, close: close)
            if close { closing = true; return }
            next(context)
        case .upgrade(var response, let open):
            stamp(&response)
            let peer = SocketPeer(channel: context.channel, connection: connection)
            self.peer = peer
            queued.removeAll()
            var out = context.channel.allocator.buffer(capacity: 0)
            out.writeBytes(response.encoded(close: false))
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
            open(peer)
            peer.startKeepalive()
            let rest = parser.takeRemainder()
            if !rest.isEmpty { peer.received(rest) }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            // A pairing long-poll is a request in flight, and a socket has its own pings.
            if !busy && peer == nil { context.close(promise: nil) }
        } else { context.fireUserInboundEventTriggered(event) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer?.ended()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }

    private func write(_ context: ChannelHandlerContext, _ response: HTTPResponse, close: Bool) {
        var out = context.channel.allocator.buffer(capacity: 0)
        out.writeBytes(response.encoded(close: close))
        let written = context.writeAndFlush(wrapOutboundOut(out))
        if close { written.whenComplete { _ in context.close(promise: nil) } }
    }
}

/// A WebSocket after its upgrade. Frames in come from `WebSocketCodec.Parser`, frames out from `WebSocketCodec.frame`.
/// Callable from any thread: the work hops to the connection's event loop.
public final class SocketPeer: @unchecked Sendable {
    public static let maxQueued = 1 << 20
    public static let pingEvery: TimeAmount = .seconds(15)
    public static let silentFor: TimeInterval = 45

    public let connection: DaemonServer.Connection
    private let channel: any Channel
    private var parser = WebSocketCodec.Parser()
    private var queuedBytes = 0
    private var closed = false
    private var heard = Date()
    private var pinger: RepeatedTask?
    /// Set from `open`, which runs on the event loop before the first frame is read.
    public var onMessage: (@Sendable (WebSocketCodec.Message) -> Void)?
    public var onEnd: (@Sendable () -> Void)?

    init(channel: any Channel, connection: DaemonServer.Connection) { self.channel = channel; self.connection = connection }

    func startKeepalive() {
        pinger = channel.eventLoop.scheduleRepeatedTask(initialDelay: Self.pingEvery, delay: Self.pingEvery) { [weak self] _ in
            guard let self, !self.closed else { return }
            if -self.heard.timeIntervalSinceNow > Self.silentFor { self.closeNow(1001, "silent"); return }
            self.writeNow(WebSocketCodec.frame(.ping(Data())))
        }
    }

    func received(_ data: Data) {
        guard !closed else { return }
        heard = Date()
        for result in parser.feed(data) {
            switch result {
            case .failure(let failure): closeNow(failure.code, failure.reason); return
            case .success(.ping(let payload)): writeNow(WebSocketCodec.frame(.pong(payload)))
            case .success(.pong): break
            case .success(.close(let code, _)): closeNow(code == nil || code == 1005 ? 1000 : code!, "")
            case .success(let other): onMessage?(other)
            }
            if closed { return }
        }
    }

    public func send(text: String) { let frame = WebSocketCodec.frame(.text(text)); channel.eventLoop.execute { self.writeNow(frame) } }

    public func close(_ code: UInt16, _ reason: String = "") { channel.eventLoop.execute { self.closeNow(code, reason) } }

    private func writeNow(_ frame: Data) {
        guard !closed else { return }
        if queuedBytes + frame.count > Self.maxQueued { closeNow(4008, "too slow"); return }
        queuedBytes += frame.count
        var buffer = channel.allocator.buffer(capacity: frame.count)
        buffer.writeBytes(frame)
        channel.writeAndFlush(buffer).whenComplete { [self] _ in queuedBytes -= frame.count }
    }

    private func closeNow(_ code: UInt16, _ reason: String) {
        guard !closed else { return }
        closed = true
        pinger?.cancel()
        var buffer = channel.allocator.buffer(capacity: 0)
        buffer.writeBytes(WebSocketCodec.frame(.close(code: code, reason: reason)))
        channel.writeAndFlush(buffer).whenComplete { [channel] _ in channel.close(promise: nil) }
        ended()
    }

    func ended() {
        closed = true
        pinger?.cancel()
        let end = onEnd
        onEnd = nil
        end?()
    }
}
