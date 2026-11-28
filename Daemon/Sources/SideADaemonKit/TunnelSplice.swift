import Foundation
import NIOCore
import SideAProtocol

/// The streams of one relay tunnel socket, each spliced to a local connection (docs/remote/tunnel.md, Flow control): what
/// both ends share, `RelayTunnel` (this computer's install, where phones come in) and `PeerTunnel` (this computer dialling
/// another one's install, in the phone's role). Credit keeps each direction of a stream to `window` bytes in flight, so a
/// slow reader slows its writer through TCP and nothing piles up here. Everything runs on the owner's event loop.
final class TunnelSplice: @unchecked Sendable {
    static let window = 256 << 10
    static let creditBatch = 32 << 10

    final class Stream: @unchecked Sendable {
        let id: UInt32
        var channel: (any Channel)?
        var credit = TunnelSplice.window
        var pending = ByteBuffer()
        var owed = 0
        var unreturned = 0
        var writes = 0
        var localEnded = false
        var finishing = false
        init(id: UInt32) { self.id = id }
    }

    private var streams: [UInt32: Stream] = [:]
    private let send: (TunnelFrame) -> Void
    /// A stream ended, either way.
    var ended: ((UInt32) -> Void)?

    /// `send` puts one frame on the tunnel socket.
    init(send: @escaping (TunnelFrame) -> Void) { self.send = send }

    var count: Int { streams.count }
    var isEmpty: Bool { streams.isEmpty }
    var ids: [UInt32] { Array(streams.keys) }
    func has(_ stream: Stream) -> Bool { streams[stream.id] === stream }

    /// `channel` reads only when asked (`autoRead` off) and reports through `read` and `localEnded`; the caller asks for
    /// the first read once whatever arrived before the stream was attached has been handled.
    @discardableResult
    func attach(_ id: UInt32, _ channel: any Channel) -> Stream {
        let stream = Stream(id: id)
        stream.channel = channel
        streams[id] = stream
        return stream
    }

    /// A frame from the tunnel for a stream that is open; OPEN is the owner's.
    func received(_ frame: TunnelFrame) {
        guard let stream = streams[frame.stream] else {
            // A FIN for a stream already ended here is the other end answering this one's.
            if ![.reset, .open, .fin].contains(frame.kind) { send(.reset(frame.stream, "unknown")) }
            return
        }
        switch frame.kind {
        case .open: return
        case .data:
            stream.owed += frame.payload.count
            guard stream.owed <= Self.window else { return reset(stream.id, "over credit") }
            write(stream, frame.payload)
        case .credit:
            stream.credit = min(Self.window, stream.credit + (frame.granted ?? 0))
            drain(stream)
        case .fin:
            // Neither end half-closes: a FIN is a close. What was written goes out, then the connection; the FIN is
            // answered so the relay sees both sides end the stream.
            send(TunnelFrame(.fin, stream.id))
            stream.finishing = true
            remove(stream.id)
            if stream.writes == 0 { stream.channel?.close(promise: nil) }
        case .reset:
            end(stream.id)
        }
    }

    func read(_ id: UInt32, _ bytes: ByteBuffer) {
        guard let stream = streams[id] else { return }
        var bytes = bytes
        stream.pending.writeBuffer(&bytes)
        drain(stream)
    }

    func localEnded(_ id: UInt32, failed: Bool) {
        guard let stream = streams[id] else { return }
        if failed { return reset(id, "local error") }
        stream.localEnded = true
        drain(stream)
    }

    /// What the local side read goes out as DATA while the other end's credit lasts; reading resumes as credit returns.
    private func drain(_ stream: Stream) {
        guard streams[stream.id] === stream else { return }
        while stream.pending.readableBytes > 0, stream.credit > 0 {
            let count = min(TunnelFrame.maxPayload, stream.credit, stream.pending.readableBytes)
            guard let bytes = stream.pending.readBytes(length: count) else { break }
            stream.credit -= count
            send(TunnelFrame(.data, stream.id, Data(bytes)))
        }
        stream.pending.discardReadBytes()
        if stream.pending.readableBytes == 0 {
            if stream.localEnded {
                send(TunnelFrame(.fin, stream.id))
                remove(stream.id)
                stream.finishing = true
                if stream.writes == 0 { stream.channel?.close(promise: nil) }
            } else if stream.credit > 0 {
                stream.channel?.read()
            }
        }
    }

    private func write(_ stream: Stream, _ payload: Data) {
        guard let channel = stream.channel else { return }
        stream.writes += 1
        channel.writeAndFlush(ByteBuffer(bytes: payload)).whenComplete { [self] result in
            stream.writes -= 1
            if stream.finishing {
                if stream.writes == 0 { channel.close(promise: nil) }
                return
            }
            guard streams[stream.id] === stream else { return }
            if case .failure = result { return reset(stream.id, "local error") }
            stream.unreturned += payload.count
            if stream.unreturned >= Self.creditBatch {
                send(.credit(stream.id, stream.unreturned))
                stream.owed -= stream.unreturned
                stream.unreturned = 0
            }
        }
    }

    /// Ends a stream from this side: RESET to the other end, the local connection closed.
    func reset(_ id: UInt32, _ reason: String) {
        guard streams[id] != nil else { return }
        send(.reset(id, reason))
        end(id)
    }

    /// Ends a stream without a word to the other end.
    func end(_ id: UInt32) {
        guard let stream = remove(id) else { return }
        stream.channel?.close(promise: nil)
    }

    /// The tunnel socket is gone: every stream ends, and nobody is told.
    func drop() {
        let all = streams
        streams = [:]
        for (id, stream) in all {
            stream.channel?.close(promise: nil)
            ended?(id)
        }
    }

    @discardableResult
    private func remove(_ id: UInt32) -> Stream? {
        guard let stream = streams.removeValue(forKey: id) else { return nil }
        ended?(id)
        return stream
    }
}

/// The local connection of one stream.
final class TunnelLocalSide: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let read: (ByteBuffer) -> Void
    private let ended: (_ failed: Bool) -> Void

    init(read: @escaping (ByteBuffer) -> Void, ended: @escaping (_ failed: Bool) -> Void) { self.read = read; self.ended = ended }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { read(unwrapInboundIn(data)) }
    func channelInactive(context: ChannelHandlerContext) { ended(false) }
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        ended(true)
        context.close(promise: nil)
    }
}
