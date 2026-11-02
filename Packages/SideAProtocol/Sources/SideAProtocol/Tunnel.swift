import Foundation
import Network

/// One binary message on a relay tunnel socket: `type u8 | stream u32 big-endian | payload`
/// (docs/remote/tunnel.md, Frames). What a stream carries is the phone's TLS to the Mac; the relay never reads it.
public struct TunnelFrame: Sendable, Equatable {
    public enum Kind: UInt8, Sendable { case open = 1, data, fin, reset, credit }

    public static let header = 5
    public static let maxPayload = 32 << 10

    public let kind: Kind
    public let stream: UInt32
    public let payload: Data

    public init(_ kind: Kind, _ stream: UInt32, _ payload: Data = Data()) {
        self.kind = kind; self.stream = stream; self.payload = payload
    }

    public static func credit(_ stream: UInt32, _ bytes: Int) -> TunnelFrame {
        var value = UInt32(clamping: bytes).bigEndian
        return TunnelFrame(.credit, stream, Data(bytes: &value, count: 4))
    }

    public static func reset(_ stream: UInt32, _ reason: String) -> TunnelFrame {
        TunnelFrame(.reset, stream, Data(reason.utf8.prefix(64)))
    }

    /// nil for anything the relay would also refuse.
    public init?(_ data: Data) {
        let bytes = [UInt8](data.prefix(Self.header))
        guard data.count >= Self.header, data.count <= Self.header + Self.maxPayload, let kind = Kind(rawValue: bytes[0]) else { return nil }
        self.kind = kind
        stream = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
        payload = Data(data.dropFirst(Self.header))
    }

    public var encoded: Data {
        var data = Data([kind.rawValue, UInt8(stream >> 24), UInt8(stream >> 16 & 0xff), UInt8(stream >> 8 & 0xff), UInt8(stream & 0xff)])
        data.append(payload)
        return data
    }

    /// A CREDIT frame's bytes.
    public var granted: Int? {
        guard kind == .credit, payload.count == 4 else { return nil }
        return payload.reduce(0) { $0 << 8 | Int($1) }
    }

    public var reason: String { String(decoding: payload, as: UTF8.self) }
}

/// The tunnel's text messages, `{"type": …}`. Each side reads only the ones meant for it.
public struct TunnelControl: Codable, Sendable, Equatable {
    public struct Device: Codable, Sendable, Equatable {
        public let id: String
        /// base64url(SHA-256(deviceSecret)), as the Mac has it from pairing.
        public let secretHash: String
        public init(id: String, secretHash: String) { self.id = id; self.secretHash = secretHash }
    }

    /// `devices`, `pairing` (Mac → relay); `gone` (relay → Mac); `mac` (relay → phone).
    public let type: String
    public var devices: [Device]?
    public var ticketHash: String?
    public var expiresAt: Double?
    public var slot: Int?
    public var online: Bool?

    public init(type: String, devices: [Device]? = nil, ticketHash: String? = nil, expiresAt: Double? = nil, slot: Int? = nil, online: Bool? = nil) {
        self.type = type; self.devices = devices; self.ticketHash = ticketHash; self.expiresAt = expiresAt; self.slot = slot; self.online = online
    }

    public var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    public init?(text: String) {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)) else { return nil }
        self = value
    }
}

/// The streams on one tunnel socket, each spliced to a local TCP connection: the Mac's loopback TLS listener on one
/// end, URLSession's proxied connection on the other. Credit keeps every stream to `window` bytes in flight, so a slow
/// reader slows its writer through TCP and nothing piles up here. Everything runs on `queue`.
public final class TunnelMux: @unchecked Sendable {
    public struct Tuning: Sendable {
        public var window = 256 << 10
        /// Credit goes back once this much was written out. Well under `window`, so a sender never waits on credit
        /// held back, and a quiet stream sends no credit frames at all.
        public var creditBatch = 32 << 10
        /// The first `immediate` frames in each window of `coalesce` go at once, so a request and its answer never
        /// wait; past that, reads wait out the window or until `coalesceBytes`, so a terminal's burst of records goes as
        /// one frame.
        public var coalesce: TimeInterval = 0.016
        public var coalesceBytes = 8 << 10
        public var immediate = 2
        public init() {}
    }

    public let queue: DispatchQueue
    private let tuning: Tuning
    private let output: @Sendable (TunnelFrame) -> Void
    private var streams: [UInt32: Stream] = [:]
    /// A stream ended, either way.
    public var ended: ((UInt32) -> Void)?

    /// `output` sends one frame on the tunnel socket; it's called on `queue`.
    public init(queue: DispatchQueue, tuning: Tuning = Tuning(), output: @escaping @Sendable (TunnelFrame) -> Void) {
        self.queue = queue; self.tuning = tuning; self.output = output
    }

    public var ids: [UInt32] { Array(streams.keys) }
    public var count: Int { streams.count }

    /// Splices `connection` to stream `id`, starting it on `queue` if it isn't yet. `initial` is anything already read
    /// from it, such as bytes behind a CONNECT.
    /// `ready` runs once the connection is up, before anything is read from it: where the Mac learns the local port
    /// its server will see the stream come from. The mux owns the state handler, so this is the way in.
    public func attach(_ id: UInt32, _ connection: NWConnection, initial: Data = Data(), ready: (@Sendable (NWConnection) -> Void)? = nil) {
        let stream = Stream(id: id, connection: connection, credit: tuning.window)
        streams[id] = stream
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: ready?(connection)
            case .failed, .cancelled: self?.lost(id, "closed")
            default: break
            }
        }
        if connection.state == .setup { connection.start(queue: queue) }
        if !initial.isEmpty { take(stream, initial) }
        read(stream)
    }

    /// One frame from the tunnel for a stream already attached; OPEN is the owner's.
    public func received(_ frame: TunnelFrame) {
        guard let stream = streams[frame.stream] else {
            // A FIN for a stream already ended here is the peer answering this side's FIN.
            if ![.reset, .open, .fin].contains(frame.kind) { output(.reset(frame.stream, "unknown")) }
            return
        }
        switch frame.kind {
        case .open: return
        case .data:
            // The peer may have `window` bytes here that haven't been credited back, and no more.
            stream.owed += frame.payload.count
            guard stream.owed <= tuning.window else { return reset(frame.stream, "over credit") }
            write(stream, frame.payload)
        case .credit:
            // Never more than the window back: a peer that grants more than it was sent can't make this side overrun it.
            stream.credit = min(tuning.window, stream.credit + (frame.granted ?? 0))
            read(stream)
        case .fin:
            // Neither end half-closes (the phone's transport doesn't, and the Mac's server closes outright), so a FIN is a
            // close: what was written goes out, then the connection. It's answered with a FIN, so the relay sees both
            // sides end the stream.
            output(TunnelFrame(.fin, stream.id))
            finish(stream)
        case .reset:
            streams[frame.stream] = nil
            stream.connection.cancel()
            ended?(frame.stream)
        }
    }

    /// Ends a stream from this side: RESET to the peer, the local connection cancelled.
    public func reset(_ id: UInt32, _ reason: String) {
        guard let stream = streams.removeValue(forKey: id) else { return }
        output(.reset(id, reason))
        stream.connection.cancel()
        ended?(id)
    }

    /// The tunnel socket is gone: every stream ends without telling a peer that can't hear.
    public func drop(where matches: (UInt32) -> Bool = { _ in true }) {
        for (id, stream) in streams where matches(id) {
            streams[id] = nil
            stream.connection.cancel()
            ended?(id)
        }
    }

    // MARK: Streams

    private final class Stream: @unchecked Sendable {
        let id: UInt32
        let connection: NWConnection
        var credit: Int
        var buffer = Data()
        var reading = false
        var writes = 0
        var unreturned = 0
        /// Bytes the peer sent that haven't been credited back yet.
        var owed = 0
        var window: DispatchTime = .now() - .seconds(1)
        var inWindow = 0
        var flushQueued = false
        /// Closed by either end; the connection goes once the last write is out.
        var finishing = false
        init(id: UInt32, connection: NWConnection, credit: Int) { self.id = id; self.connection = connection; self.credit = credit }
    }

    private func read(_ stream: Stream) {
        let room = min(TunnelFrame.maxPayload, stream.credit - stream.buffer.count)
        guard !stream.reading, room > 0, streams[stream.id] === stream else { return }
        stream.reading = true
        stream.connection.receive(minimumIncompleteLength: 1, maximumLength: room) { [weak self] data, _, complete, error in
            guard let self, self.streams[stream.id] === stream else { return }
            stream.reading = false
            if let data, !data.isEmpty { self.take(stream, data) }
            if error != nil { return self.reset(stream.id, "local error") }
            if complete {
                self.flush(stream)
                self.output(TunnelFrame(.fin, stream.id))
                self.finish(stream)
                return
            }
            self.read(stream)
        }
    }

    private func take(_ stream: Stream, _ data: Data) {
        stream.buffer.append(data)
        let now = DispatchTime.now()
        if Double(now.uptimeNanoseconds - stream.window.uptimeNanoseconds) / 1e9 >= tuning.coalesce {
            stream.window = now
            stream.inWindow = 0
        }
        if stream.buffer.count >= tuning.coalesceBytes || (stream.inWindow < tuning.immediate && !stream.flushQueued) { return flush(stream) }
        guard !stream.flushQueued else { return }
        stream.flushQueued = true
        queue.asyncAfter(deadline: stream.window + tuning.coalesce) { [weak self] in
            stream.flushQueued = false
            guard let self, self.streams[stream.id] === stream else { return }
            self.flush(stream)
            self.read(stream)
        }
    }

    private func flush(_ stream: Stream) {
        while !stream.buffer.isEmpty {
            let chunk = stream.buffer.prefix(TunnelFrame.maxPayload)
            stream.buffer.removeFirst(chunk.count)
            stream.credit -= chunk.count
            output(TunnelFrame(.data, stream.id, Data(chunk)))
            stream.inWindow += 1
        }
    }

    private func write(_ stream: Stream, _ payload: Data) {
        stream.writes += 1
        stream.connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard self.streams[stream.id] === stream || stream.finishing else { return }
            stream.writes -= 1
            if stream.finishing {
                if stream.writes == 0 { stream.connection.cancel() }
                return
            }
            if error != nil { return self.reset(stream.id, "local error") }
            stream.unreturned += payload.count
            if stream.unreturned >= self.tuning.creditBatch {
                self.output(.credit(stream.id, stream.unreturned))
                stream.owed -= stream.unreturned
                stream.unreturned = 0
            }
        })
    }

    private func finish(_ stream: Stream) {
        guard streams[stream.id] === stream else { return }
        stream.finishing = true
        if stream.writes == 0 { stream.connection.cancel() }
        streams[stream.id] = nil
        ended?(stream.id)
    }

    private func lost(_ id: UInt32, _ reason: String) {
        guard streams[id] != nil else { return }
        reset(id, reason)
    }
}
