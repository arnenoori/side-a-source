import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import SideACore

/// An HTTPS server for the Side A Remote protocol on SwiftNIO and NIOSSL. The HTTP/1.1 parsing is `HTTPParser` from
/// SideACore, the same code the Mac's `NWListener` front uses, so a request that parses on the Mac parses here, with the
/// same limits and the same refusals; NIO supplies only the sockets, TLS and event loops. (NIOHTTP1 would be a second
/// parser to keep in step with the first, and it accepts chunked bodies and `Expect`, which the protocol refuses.)
public final class DaemonServer: Sendable {
    /// What a route may know about the connection its request came in on.
    public struct Connection: Sendable { public let localPort: Int }
    public typealias Router = @Sendable (HTTPRequest, Connection) -> HTTPResponse

    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    public let identity: DaemonIdentity
    public let host: String
    public let port: Int

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel, identity: DaemonIdentity, host: String, port: Int) {
        self.group = group; self.channel = channel; self.identity = identity; self.host = host; self.port = port
    }

    /// Binds `host:port` (port 0 picks a free one) and starts answering with `router`.
    public static func start(identity: DaemonIdentity, host: String = "127.0.0.1", port: Int = 0, threads: Int = 2,
                             router: @escaping Router) async throws -> DaemonServer {
        let context = try NIOSSLContext(configuration: identity.serverConfiguration())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: threads)
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(.backlog, value: 64)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                        try channel.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: .seconds(30)))
                        try channel.pipeline.syncOperations.addHandler(HTTPConnection(router: router))
                    }
                }
                .bind(host: host, port: port).get()
            return DaemonServer(group: group, channel: channel, identity: identity, host: host, port: channel.localAddress?.port ?? port)
        } catch {
            // swiftlint:disable:next swallowed_try -- the bind error is the one reported; a failed shutdown adds nothing.
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func stop() async throws {
        try await channel.close()
        try await group.shutdownGracefully()
    }
}

/// One connection: bytes in, `HTTPParser`, the router, an answer written whole with a Content-Length. A request the
/// parser refuses gets its status and the connection closes, as on the Mac.
final class HTTPConnection: ChannelInboundHandler {

    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var parser = HTTPParser()
    private let router: DaemonServer.Router

    init(router: @escaping DaemonServer.Router) { self.router = router }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        for result in parser.feed(bytes) {
            switch result {
            case .success(let request):
                respond(context, router(request, DaemonServer.Connection(localPort: context.localAddress?.port ?? 0)), close: !request.keepAlive)
                if !request.keepAlive { return }
            case .failure(let error):
                respond(context, HTTPResponse.json(error.status, Data(#"{"error":{"message":"\#(error.message)"}}"#.utf8)), close: true)
                return
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil) } else { context.fireUserInboundEventTriggered(event) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }

    private func respond(_ context: ChannelHandlerContext, _ response: HTTPResponse, close: Bool) {
        var out = context.channel.allocator.buffer(capacity: 0)
        out.writeBytes(response.encoded(close: close))
        let written = context.writeAndFlush(wrapOutboundOut(out))
        if close { written.whenComplete { _ in context.close(promise: nil) } }
    }
}
