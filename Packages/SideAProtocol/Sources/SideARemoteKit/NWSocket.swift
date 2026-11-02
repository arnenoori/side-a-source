import CryptoKit
import Foundation
import Network
import SideAProtocol

/// A client WebSocket (RFC 6455) on an `HTTPStream`: the upgrade, masked frames out, fragments joined, pings answered.
/// A refused upgrade throws the close code its status stands for (401 → 4401, 426 → 4426, 429 → 4429), as URLSession's
/// did, and a close frame throws `SocketClosed` with its code.
final class NWSocket: SocketConnection, @unchecked Sendable {
    static let maxMessage = 16 << 20

    private let lock = NSLock()
    private var opened: Task<HTTPStream, Error>!
    private var inbox: [Result<SocketMessage, Error>] = []
    private var waiting: [CheckedContinuation<SocketMessage, Error>] = []
    private var pongs: [Data: CheckedContinuation<Void, Error>] = [:]
    private var parser = ClientFrames()
    private var ended: Error?
    private var pingCount: UInt32 = 0
    private let line: String
    private let category: KitLog.Category

    init(request: URLRequest, transport: NWTransport) {
        line = KitLog.line(request)
        category = line.contains("/ws/term") ? .terminal : .sync
        let line = line, category = category
        opened = Task {
            do {
                let stream = try await Self.upgrade(request, transport: transport, owner: self)
                KitLog.log(category, "socket open \(line)")
                return stream
            } catch {
                KitLog.log(category, "socket failed \(line): \(KitLog.describe(error))")
                throw error
            }
        }
    }

    private static func upgrade(_ request: URLRequest, transport: NWTransport, owner: NWSocket) async throws -> HTTPStream {
        guard let url = request.url, let host = url.host else { throw URLError(.badURL) }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var https = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        https.scheme = url.scheme == "ws" ? "http" : "https"
        let stream = try await transport.open(https.url!, timeout: request.timeoutInterval > 0 ? request.timeoutInterval : 30)
        let reply: HTTPStream.Reply
        do {
            reply = try await stream.exchange(NWTransport.head(request, host: host, port: url.port, upgrade: key), timeout: 30)
        } catch let failure as HTTPStream.Failure {
            throw failure.urlError
        }
        guard reply.status == 101 else {
            stream.cancel()
            throw [401, 426, 429].contains(reply.status) ? SocketClosed(code: 4000 + reply.status) : URLError(.badServerResponse)
        }
        let accept = reply.headers.first { $0.key.caseInsensitiveCompare("Sec-WebSocket-Accept") == .orderedSame }?.value
        guard accept == ClientFrames.accept(key) else {
            stream.cancel()
            throw URLError(.badServerResponse)
        }
        if !reply.rest.isEmpty { owner.received(reply.rest, on: stream) }
        owner.read(stream)
        return stream
    }

    private func read(_ stream: HTTPStream) {
        stream.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.received(data, on: stream) }
            if complete || error != nil { return self.end(URLError(.networkConnectionLost), stream) }
            if self.lock.withLock({ self.ended == nil }) { self.read(stream) }
        }
    }

    private func received(_ data: Data, on stream: HTTPStream) {
        let frames = lock.withLock { parser.feed(data) }
        for frame in frames {
            switch frame {
            case .message(let message): deliver(.success(message))
            case .ping(let payload): stream.connection.send(content: ClientFrames.frame(0xA, payload), completion: .contentProcessed { _ in })
            case .pong(let payload): lock.withLock { pongs.removeValue(forKey: payload) }?.resume()
            case .close(let code, let reason):
                stream.connection.send(content: ClientFrames.frame(0x8, ClientFrames.closePayload(code == 1005 ? 1000 : code, "")),
                                       completion: .contentProcessed { _ in stream.cancel() })
                end(SocketClosed(code: code, reason: reason), stream)
            case .invalid: end(SocketClosed(code: 1002, reason: "protocol error"), stream)
            }
        }
    }

    private func deliver(_ result: Result<SocketMessage, Error>) {
        let waiter: CheckedContinuation<SocketMessage, Error>? = lock.withLock {
            if waiting.isEmpty { inbox.append(result); return nil }
            return waiting.removeFirst()
        }
        waiter?.resume(with: result)
    }

    private func end(_ error: Error, _ stream: HTTPStream) {
        let (waiters, pending): ([CheckedContinuation<SocketMessage, Error>], [CheckedContinuation<Void, Error>]) = lock.withLock {
            guard ended == nil else { return ([], []) }
            ended = error
            KitLog.log(category, "socket ended \(line): \(KitLog.describe(error))")
            defer { waiting = []; pongs = [:] }
            return (waiting, Array(pongs.values))
        }
        for waiter in waiters { waiter.resume(throwing: error) }
        for pong in pending { pong.resume(throwing: error) }
        stream.cancel()
    }

    func send(_ message: SocketMessage) async throws {
        let stream = try await opened.value
        if let ended = lock.withLock({ ended }) { throw ended }
        let frame: Data
        switch message {
        case .text(let text): frame = ClientFrames.frame(0x1, Data(text.utf8))
        case .data(let data): frame = ClientFrames.frame(0x2, data)
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            stream.connection.send(content: frame, completion: .contentProcessed { error in
                if error != nil { done.resume(throwing: URLError(.networkConnectionLost)) } else { done.resume() }
            })
        }
    }

    func receive() async throws -> SocketMessage {
        _ = try await opened.value
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<SocketMessage, Error>) in
            let ready: Result<SocketMessage, Error>? = lock.withLock {
                if !inbox.isEmpty { return inbox.removeFirst() }
                if let ended { return .failure(ended) }
                waiting.append(done)
                return nil
            }
            if let ready { done.resume(with: ready) }
        }
    }

    /// Returns once the Mac's pong comes back; throws after 10 s without one.
    func sendPing() async throws {
        let stream = try await opened.value
        let payload: Data = lock.withLock {
            pingCount &+= 1
            return withUnsafeBytes(of: pingCount.bigEndian) { Data($0) }
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let failed: Error? = lock.withLock {
                if let ended { return ended }
                pongs[payload] = done
                return nil
            }
            if let failed { return done.resume(throwing: failed) }
            stream.connection.send(content: ClientFrames.frame(0x9, payload), completion: .contentProcessed { _ in })
            stream.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.pongs.removeValue(forKey: payload) }?.resume(throwing: URLError(.timedOut))
            }
        }
    }

    func close(code: Int, reason: String?) {
        let opened = opened!
        Task {
            guard let stream = try? await opened.value else { return opened.cancel() }
            stream.connection.send(content: ClientFrames.frame(0x8, ClientFrames.closePayload(code, reason ?? "")),
                                   completion: .contentProcessed { _ in stream.cancel() })
            end(SocketClosed(code: code, reason: reason), stream)
        }
    }
}

/// RFC 6455 frames as a client sees them: what it sends is masked, what it reads is not.
struct ClientFrames {
    enum Frame: Equatable { case message(SocketMessage), ping(Data), pong(Data), close(code: Int, reason: String?), invalid }

    private var buffer = Data()
    private var fragments = Data()
    private var fragmentOpcode: UInt8?

    static func accept(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    static func closePayload(_ code: Int, _ reason: String) -> Data {
        Data([UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]) + Data(reason.utf8.prefix(120))
    }

    static func frame(_ opcode: UInt8, _ payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count <= 0xffff {
            frame.append(contentsOf: [0x80 | 126, UInt8(count >> 8), UInt8(count & 0xff)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8(UInt64(count) >> (UInt64($0) * 8) & 0xff) })
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        var masked = [UInt8](payload)
        for index in masked.indices { masked[index] ^= mask[index & 3] }
        frame.append(contentsOf: masked)
        return frame
    }

    mutating func feed(_ data: Data) -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        while let (frame, used) = next() {
            buffer.removeFirst(used)
            guard let frame else { continue }
            frames.append(frame)
            if frame == .invalid { buffer = Data(); break }
        }
        return frames
    }

    /// The next whole frame and the bytes it took; a nil frame is a fragment kept for later.
    private mutating func next() -> (Frame?, Int)? {
        let head = [UInt8](buffer.prefix(10))
        guard head.count >= 2 else { return nil }
        let fin = head[0] & 0x80 != 0
        let opcode = head[0] & 0x0f
        // A server never masks.
        if head[1] & 0x80 != 0 { return (.invalid, 0) }
        var length = Int(head[1] & 0x7f)
        var offset = 2
        if length == 126 {
            guard head.count >= 4 else { return nil }
            length = Int(head[2]) << 8 | Int(head[3]); offset = 4
        } else if length == 127 {
            guard head.count >= 10 else { return nil }
            length = head[2..<10].reduce(0) { $0 << 8 | Int($1) }; offset = 10
        }
        guard length >= 0, length <= NWSocket.maxMessage else { return (.invalid, 0) }
        guard buffer.count >= offset + length else { return nil }
        let payload = Data(buffer.dropFirst(offset).prefix(length))
        let used = offset + length
        switch opcode {
        case 0x0:
            guard let started = fragmentOpcode else { return (.invalid, used) }
            fragments.append(payload)
            guard fragments.count <= NWSocket.maxMessage else { return (.invalid, used) }
            guard fin else { return (nil, used) }
            fragmentOpcode = nil
            defer { fragments = Data() }
            return (message(started, fragments), used)
        case 0x1, 0x2:
            guard fragmentOpcode == nil else { return (.invalid, used) }
            guard fin else {
                fragmentOpcode = opcode
                fragments = payload
                return (nil, used)
            }
            return (message(opcode, payload), used)
        case 0x8:
            let code = payload.count >= 2 ? Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1]) : 1005
            return (.close(code: code, reason: payload.count > 2 ? String(decoding: payload.dropFirst(2), as: UTF8.self) : nil), used)
        case 0x9: return (.ping(payload), used)
        case 0xA: return (.pong(payload), used)
        default: return (.invalid, used)
        }
    }

    private func message(_ opcode: UInt8, _ payload: Data) -> Frame {
        opcode == 0x1 ? .message(.text(String(decoding: payload, as: UTF8.self))) : .message(.data(payload))
    }
}
