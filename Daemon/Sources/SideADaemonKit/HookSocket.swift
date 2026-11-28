import Foundation
import NIOCore
import NIOPosix

/// The Unix socket the agent's permission hook (`bridge/island_hook.py`, the same script the Mac's island runs) talks to: one
/// JSON line in, then the hook waits for one line back. A hook that closes before the answer means the agent stopped it
/// (its session quit), which `closed` reports. Only the daemon's own user may connect: the folder is 0700, the socket 0600,
/// and the peer's uid is checked as well, since an answer here grants a permission.
final class HookSocket: Sendable {
    typealias Received = @Sendable (_ connection: UInt64, _ line: Data) -> Void
    typealias Closed = @Sendable (_ connection: UInt64) -> Void

    /// What fits in the sockaddr_un a path is copied into (104 bytes on macOS, 108 on Linux), less its terminator.
    static let pathLimit = 100
    static let lineLimit = 4 << 20

    let path: String
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    fileprivate let connections: Connections

    private init(path: String, group: MultiThreadedEventLoopGroup, channel: any Channel, connections: Connections) {
        self.path = path; self.group = group; self.channel = channel; self.connections = connections
    }

    struct PathTooLong: Error, CustomStringConvertible {
        var description: String { "The path to the permission hook's socket is longer than a socket address holds. Use a shorter --state-dir." }
    }

    struct Refused: Error {}

    static func start(path: String, received: @escaping Received, closed: @escaping Closed) async throws -> HookSocket {
        guard path.utf8.count < pathLimit else { throw PathTooLong() }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connections = Connections()
        do {
            let channel = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    Self.sameUser(channel).flatMapThrowing {
                        let id = connections.add(channel)
                        try channel.pipeline.syncOperations.addHandler(HookConnection(id: id, connections: connections, received: received, closed: closed))
                    }
                }
                .bind(unixDomainSocketPath: path).get()
            chmod(path, 0o600)
            return HookSocket(path: path, group: group, channel: channel, connections: connections)
        } catch {
            // swiftlint:disable:next swallowed_try -- the bind's own error is the one reported.
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// Writes the answer line and closes the connection; false when the hook had already gone.
    @discardableResult
    func reply(_ connection: UInt64, _ line: Data) -> Bool {
        guard let channel = connections.take(connection) else { return false }
        var buffer = channel.allocator.buffer(capacity: line.count)
        buffer.writeBytes(line)
        channel.writeAndFlush(buffer).whenComplete { _ in channel.close(promise: nil) }
        return true
    }

    func stop() async {
        // swiftlint:disable swallowed_try -- shutting down.
        try? await channel.close()
        try? await group.shutdownGracefully()
        // swiftlint:enable swallowed_try
        unlink(path)
    }

    fileprivate final class Connections: @unchecked Sendable {
        private let lock = NSLock()
        private var counter: UInt64 = 0
        private var channels: [UInt64: any Channel] = [:]

        func add(_ channel: any Channel) -> UInt64 {
            lock.withLock { counter += 1; channels[counter] = channel; return counter }
        }

        /// The channel to answer on, once: `reply` and a hook closing each take it, which is how an answered hook is told
        /// from one that vanished.
        func take(_ id: UInt64) -> (any Channel)? { lock.withLock { channels.removeValue(forKey: id) } }
    }

    /// The peer's uid must be this process's. Where it can't be read the connection is refused.
    private static func sameUser(_ channel: any Channel) -> EventLoopFuture<Void> {
        guard let provider = channel as? any SocketOptionProvider else { return channel.eventLoop.makeFailedFuture(Refused()) }
        #if os(Linux)
        // glibc's `struct ucred` is only declared with _GNU_SOURCE, which Swift's import doesn't set; this is its layout.
        struct Credentials { var pid: Int32 = 0; var uid: UInt32 = 0; var gid: UInt32 = 0 }
        let uid = provider.unsafeGetSocketOption(level: NIOBSDSocket.OptionLevel(rawValue: SOL_SOCKET), name: NIOBSDSocket.Option(rawValue: SO_PEERCRED))
            .map { (credentials: Credentials) in credentials.uid }
        #else
        // LOCAL_PEERCRED, at the SOL_LOCAL level (0).
        let uid = provider.unsafeGetSocketOption(level: NIOBSDSocket.OptionLevel(rawValue: 0), name: NIOBSDSocket.Option(rawValue: LOCAL_PEERCRED))
            .map { (credentials: xucred) in credentials.cr_uid }
        #endif
        return uid.flatMapThrowing { if $0 != getuid() { throw Refused() } }
    }
}

private final class HookConnection: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let id: UInt64
    private let connections: HookSocket.Connections
    private let received: HookSocket.Received
    private let closed: HookSocket.Closed
    private var buffer = Data()
    private var delivered = false

    init(id: UInt64, connections: HookSocket.Connections, received: @escaping HookSocket.Received, closed: @escaping HookSocket.Closed) {
        self.id = id; self.connections = connections; self.received = received; self.closed = closed
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !delivered else { return }
        var input = unwrapInboundIn(data)
        // Only what just arrived is searched, so a line that never ends costs no more per chunk than the first.
        let fresh = buffer.endIndex
        buffer.append(contentsOf: input.readBytes(length: input.readableBytes) ?? [])
        if buffer.count > HookSocket.lineLimit { context.close(promise: nil); return }
        if let newline = buffer[fresh...].firstIndex(of: 0x0A) {
            delivered = true
            received(id, Data(buffer[buffer.startIndex..<newline]))
            buffer = Data()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // A hook that quit before it was answered; an answered one was taken by `reply`.
        if connections.take(id) != nil, delivered { closed(id) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}
