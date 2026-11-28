import Foundation
import NIOCore
import NIOPosix
import SideACore
import SideAProtocol

/// The local control socket: `sidead pair`, `status`, `devices` and `revoke` talk to the running daemon over a Unix socket in
/// the user's own directory (mode 0600, so only the same user connects), one JSON object per line each way. Nothing on it
/// is reachable from the network.
public final class ControlServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    public let path: String

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel, path: String) { self.group = group; self.channel = channel; self.path = path }

    public static func start(daemon: SideADaemon, path: String) async throws -> ControlServer {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ControlConnection(daemon: daemon))
                }
            }
            .bind(unixDomainSocketPath: path).get()
        chmod(path, 0o600)
        return ControlServer(group: group, channel: channel, path: path)
    }

    public func stop() async throws {
        try await channel.close()
        try await group.shutdownGracefully()
        unlink(path)
    }
}

enum ControlWire {
    static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func phase(_ phase: PairingBroker.Phase, link: (String) -> String, code: String?) -> [String: Any] {
        switch phase {
        case .code(let display, let expiresAt):
            ["event": "code", "code": display, "link": link((code ?? display).replacingOccurrences(of: "-", with: "")), "expiresAt": expiresAt]
        case .confirm(let attempt):
            ["event": "confirm", "device": attempt.request.device.name, "model": attempt.request.device.model, "comparison": attempt.comparison,
             "keyMatches": attempt.keyMatches]
        case .pairing: ["event": "pairing"]
        case .paired(let name): ["event": "paired", "device": name]
        case .stopped(let stop): ["event": "stopped", "reason": stop.rawValue]
        }
    }
}

final class ControlConnection: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let daemon: SideADaemon
    private var buffer = Data()
    private var lines: AsyncStream<String>.Continuation?

    init(daemon: SideADaemon) { self.daemon = daemon }

    func channelActive(context: ChannelHandlerContext) {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        lines = continuation
        let channel = context.channel
        let daemon = daemon
        let box = box
        Task { await ControlConnection.serve(stream, daemon: daemon, channel: channel, box: box) }
    }

    /// Commands in the order they arrive; when the client goes away, a pairing it opened closes with it.
    static func serve(_ lines: AsyncStream<String>, daemon: SideADaemon, channel: any Channel, box: Box) async {
        for await line in lines { await handle(line, daemon: daemon, channel: channel, connection: box) }
        let state = box.take()
        state.watcher?.cancel()
        if state.opened { await daemon.pairing.close() }
    }

    /// The connection's own state that commands touch from tasks.
    private let box = Box()
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var watcher: Task<Void, Never>?
        private var opened = false
        func setWatcher(_ task: Task<Void, Never>) { lock.lock(); watcher?.cancel(); watcher = task; opened = true; lock.unlock() }
        func take() -> (watcher: Task<Void, Never>?, opened: Bool) { lock.lock(); defer { lock.unlock() }; return (watcher, opened) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var input = unwrapInboundIn(data)
        buffer.append(contentsOf: input.readBytes(length: input.readableBytes) ?? [])
        if buffer.count > 1 << 20 { context.close(promise: nil); return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer = Data(buffer[(newline + 1)...])
            lines?.yield(line)
        }
    }

    func channelInactive(context: ChannelHandlerContext) { lines?.finish() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }

    static func send(_ channel: any Channel, _ object: [String: Any]) {
        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString(ControlWire.line(object))
        channel.writeAndFlush(buffer, promise: nil)
    }

    static func handle(_ line: String, daemon: SideADaemon, channel: any Channel, connection: Box) async {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let command = object["cmd"] as? String else {
            return send(channel, ["ok": false, "error": "Send a JSON object with a cmd."])
        }
        switch command {
        case "status":
            send(channel, ["ok": true, "status": await daemon.status()])
        case "devices":
            let devices = await daemon.devices.devices.map { ["id": $0.id, "name": $0.name, "model": $0.model, "app": $0.app,
                                                               "created": $0.created, "lastSeen": $0.lastSeen ?? 0] as [String: Any] }
            send(channel, ["ok": true, "devices": devices])
        case "revoke":
            guard let id = object["id"] as? String else { return send(channel, ["ok": false, "error": "Say which device."]) }
            let match = await daemon.devices.devices.first { $0.id == id || $0.id.hasPrefix(id) }
            guard let match else { return send(channel, ["ok": false, "error": "No such device."]) }
            await daemon.revoke(match.id)
            send(channel, ["ok": true, "revoked": match.name])
        case "pair":
            await daemon.pairing.open()
            daemon.pairingOpened(true)
            let updates = await daemon.pairing.updates()
            let task = Task {
                defer { daemon.pairingOpened(false) }
                for await phase in updates {
                    let code = await daemon.pairing.currentCode
                    send(channel, ControlWire.phase(phase, link: { daemon.link(code: $0) }, code: code))
                    if case .paired = phase { break }
                    if case .stopped = phase { break }
                }
            }
            connection.setWatcher(task)
        case "decide":
            switch object["decision"] as? String {
            case "pair": await daemon.pairing.decide(.pair)
            case "mismatch": await daemon.pairing.decide(.mismatch)
            default: await daemon.pairing.decide(.cancel)
            }
        default:
            let arguments = object.compactMapValues { $0 as? String }
            guard let answer = await daemon.control(command, arguments),
                  let reply = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] else {
                return send(channel, ["ok": false, "error": "Unknown command."])
            }
            send(channel, reply)
        }
    }
}
