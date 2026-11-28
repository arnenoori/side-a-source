import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import SideACore
import SideAProtocol

/// What went wrong talking to another computer, below the level of its answer.
enum PeerFailure: Error, Equatable, CustomStringConvertible {
    /// No address answered under the pinned key; nothing was sent.
    case unreachable
    /// The request went out and no whole answer came back: it may or may not have run there.
    case noAnswer
    var description: String { self == .unreachable ? "couldn't reach it" : "no answer came" }
}

/// An answer outside 2xx, with the other computer's error when it sent one.
struct PeerRefusal: Error, Equatable {
    let status: Int
    let code: ErrorCode
    let message: String
    let retryAfter: Double?
    var retryable: Bool { status == 429 || status == 503 || code == .inProgress }
}

struct PeerResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

/// HTTPS to another computer's Remote server on SwiftNIO and NIOSSL, trusting one key and nothing else, as the phone
/// does (and `TestConnection` in the tests): no chain or host name check, the leaf's SPKI SHA-256 must be the pin. One
/// connection per request, closed after the answer; the server's own parser and limits are the ones it applies to
/// phones. Each path is tried in turn (the addresses, then the relay tunnel when the link has one) only until one has
/// shaken hands under the pin, so a request is written at most once.
enum PeerHTTP {
    private static let context: NIOSSLContext? = {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .noHostnameVerification
        configuration.minimumTLSVersion = .tlsv12
        configuration.applicationProtocols = ["http/1.1"]
        return try? NIOSSLContext(configuration: configuration)
    }()

    static let maxAnswer = 8 << 20
    static let handshakeWithin: TimeAmount = .seconds(15)
    /// After the relay answered where the addresses did not, it goes first for this long, so each piece of a move doesn't
    /// wait out addresses that don't answer.
    static let relayFirstFor = 60.0

    private enum Path {
        case direct(host: String, port: Int)
        case relay(PeerTunnel.Route)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var relayUntil: [String: Date] = [:]

    private static func relayFirst(_ pin: String) -> Bool { lock.withLock { (relayUntil[pin] ?? .distantPast) > Date() } }

    private static func answered(_ pin: String, relay: Bool) {
        lock.withLock { relayUntil[pin] = relay ? Date().addingTimeInterval(relayFirstFor) : nil }
    }

    /// `headers` are the request's own, without Host, Content-Length or Connection, which are added here.
    static func send(to addresses: [(host: String, port: Int)], relay: PeerTunnel.Route? = nil, pin: String, method: String, path: String,
                     headers: [(String, String)], body: Data, timeout: TimeAmount, connectTimeout: TimeAmount = .seconds(5)) async throws -> PeerResponse {
        guard let context else { throw PeerFailure.unreachable }
        var paths = addresses.map { Path.direct(host: $0.host, port: $0.port) }
        if let relay {
            if relayFirst(pin) { paths.insert(.relay(relay), at: 0) } else { paths.append(.relay(relay)) }
        }
        for route in paths {
            let loop = MultiThreadedEventLoopGroup.singleton.next()
            let reader = PeerReader(promise: loop.makePromise(of: PeerResponse.self))
            let initializer: @Sendable (any Channel) -> EventLoopFuture<Void> = { channel in
                channel.eventLoop.makeCompletedFuture {
                    let tls = try NIOSSLClientHandler(context: context, serverHostname: nil) { chain, verdict in
                        guard let leaf = chain.first, let key = try? leaf.extractPublicKey().toSPKIBytes() else { return verdict.succeed(.failed) }
                        verdict.succeed(Data(SHA256.hash(data: key)).base64URL == pin ? .certificateVerified : .failed)
                    }
                    try channel.pipeline.syncOperations.addHandler(tls)
                    try channel.pipeline.syncOperations.addHandler(PeerReaderHandler(reader: reader))
                }
            }
            let channel: any Channel
            let host: String
            do {
                switch route {
                case .direct(let address, let port):
                    host = SideADaemon.hostPort(address, port)
                    channel = try await ClientBootstrap(group: loop).connectTimeout(connectTimeout).channelInitializer(initializer)
                        .connect(host: address, port: port).get()
                case .relay(let relay):
                    // The other computer answers this name only through its tunnel (docs/remote/tunnel.md, The Mac).
                    host = SideADaemon.relayHost
                    let socket = try await PeerTunnel.shared(relay).dial()
                    channel = try await ClientBootstrap(group: loop).channelInitializer(initializer).withConnectedSocket(socket).get()
                }
            } catch {
                // No channel ever held this path's promises: they are settled here.
                reader.fail(PeerFailure.unreachable)
                continue
            }
            // The handshake (and so the pin) is settled before a byte of the request goes, so a wrong key is "unreachable".
            let shaking = loop.scheduleTask(in: handshakeWithin) { reader.fail(PeerFailure.unreachable); channel.close(promise: nil) }
            do {
                try await reader.handshake.futureResult.get()
                shaking.cancel()
            } catch {
                shaking.cancel()
                channel.close(promise: nil)
                continue
            }
            if case .relay = route { answered(pin, relay: true) } else { answered(pin, relay: false) }
            var text = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n"
            for (name, value) in headers { text += "\(name): \(value)\r\n" }
            if method != "GET" || !body.isEmpty { text += "Content-Length: \(body.count)\r\n" }
            text += "Connection: close\r\n\r\n"
            var buffer = channel.allocator.buffer(capacity: text.utf8.count + body.count)
            buffer.writeString(text)
            buffer.writeBytes(body)
            let timer = loop.scheduleTask(in: timeout) { reader.fail(PeerFailure.noAnswer); channel.close(promise: nil) }
            channel.writeAndFlush(buffer).whenFailure { _ in reader.fail(PeerFailure.noAnswer) }
            defer { timer.cancel(); channel.close(promise: nil) }
            do { return try await reader.promise.futureResult.get() } catch { throw PeerFailure.noAnswer }
        }
        throw PeerFailure.unreachable
    }

    /// The whole answer in `data`, or nil while more is to come.
    static func parse(_ data: Data, closed: Bool) -> PeerResponse? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }
        let status = lines.removeFirst().split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let start = end.upperBound
        if let length = headers["content-length"].flatMap(Int.init) {
            guard data.count - (start - data.startIndex) >= length else { return nil }
            return PeerResponse(status: status, headers: headers, body: Data(data[start..<(start + length)]))
        }
        return closed ? PeerResponse(status: status, headers: headers, body: Data(data[start...])) : nil
    }
}

/// The answer being collected, completed once: by the whole answer, an early close, an error or the timer.
final class PeerReader: @unchecked Sendable {
    let promise: EventLoopPromise<PeerResponse>
    let handshake: EventLoopPromise<Void>
    private let lock = NSLock()
    private var done = false, shaken = false
    private var data = Data()

    init(promise: EventLoopPromise<PeerResponse>) {
        self.promise = promise
        handshake = promise.futureResult.eventLoop.makePromise(of: Void.self)
    }

    func shook() {
        lock.lock(); let first = !shaken; shaken = true; lock.unlock()
        if first { handshake.succeed(()) }
    }

    func add(_ bytes: [UInt8]) {
        lock.lock()
        data.append(contentsOf: bytes)
        let too = data.count > PeerHTTP.maxAnswer
        let answer = too ? nil : PeerHTTP.parse(data, closed: false)
        lock.unlock()
        if too { fail(PeerFailure.noAnswer) } else if let answer { succeed(answer) }
    }

    func closed() {
        lock.lock(); let answer = PeerHTTP.parse(data, closed: true); lock.unlock()
        if let answer { succeed(answer) } else { fail(PeerFailure.noAnswer) }
    }

    private func succeed(_ answer: PeerResponse) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { promise.succeed(answer) }
    }

    func fail(_ error: any Error) {
        lock.lock(); let first = !done; done = true; let unshaken = !shaken; shaken = true; lock.unlock()
        if unshaken { handshake.fail(error) }
        if first { promise.fail(error) }
    }
}

final class PeerReaderHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let reader: PeerReader
    init(reader: PeerReader) { self.reader = reader }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? TLSUserEvent, case .handshakeCompleted = event { reader.shook() }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        reader.add(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }

    func channelInactive(context: ChannelHandlerContext) { reader.closed() }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        reader.fail(error)
        context.close(promise: nil)
    }
}
