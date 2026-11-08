import Foundation
import Network
import Security
import SideAProtocol

/// The Mac refused nothing, but iOS hasn't let the app on the local network: the user turned Local Network off for it
/// in Settings, or hasn't answered the prompt before the request ran out of time.
public struct LocalNetworkDenied: Error, Sendable, Equatable {
    public init() {}
}

/// HTTP/1.1 and WebSockets to the Mac on Network.framework, so the self-signed, IP-addressed certificate is judged by
/// its pinned SPKI alone and App Transport Security needs no exception. `trust` pins (or observes) every connection's
/// key exactly as it did for URLSession. Idle connections are kept per address and reused, under the Mac's 30 s idle
/// timeout.
public final class NWTransport: Transport, @unchecked Sendable {
    public static let idleFor: TimeInterval = 20

    /// Idle connections kept per address. The relay path keeps fewer: each is a stream of the Mac's 8 per phone.
    let poolSize: Int

    public let trust: PinnedTrust
    /// Where to dial instead of the URL's own host and port: the relay bridge's loopback port, with the URL's host
    /// still sent as `Host`.
    private let dial: (@Sendable (URL) -> NWEndpoint?)?
    private let queue = DispatchQueue(label: "com.arnenoori.sidea.nwtransport")
    private let lock = NSLock()
    private var idle: [String: [(connection: HTTPStream, since: Date)]] = [:]

    public init(trust: PinnedTrust, poolSize: Int = 4, dial: (@Sendable (URL) -> NWEndpoint?)? = nil) {
        self.trust = trust; self.poolSize = poolSize; self.dial = dial
    }

    // MARK: HTTP

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request, fresh: false)
    }

    /// `fresh` skips the kept connections: a probe asks whether the path answers now, which an old connection can't say.
    public func send(_ request: URLRequest, fresh: Bool) async throws -> (Data, HTTPURLResponse) {
        let line = KitLog.line(request)
        let start = ContinuousClock.now
        do {
            let (data, response) = try await exchange(request, fresh: fresh)
            KitLog.log(.transport, "\(line) → \(response.statusCode) in \(KitLog.ms(since: start)) ms\(fresh ? " (fresh)" : "")")
            return (data, response)
        } catch {
            KitLog.log(.transport, "\(line) failed after \(KitLog.ms(since: start)) ms: \(KitLog.describe(error))")
            throw error
        }
    }

    private func exchange(_ request: URLRequest, fresh: Bool) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host else { throw URLError(.badURL) }
        let key = Self.key(url)
        let head = Self.head(request, host: host, port: url.port)
        let body = request.httpBody ?? Data()
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 30
        // A kept connection the Mac may have closed meanwhile gets one retry on a fresh one, as browsers do; the request
        // never reached the Mac's handler, since nothing came back on it.
        if !fresh, let kept = take(key) {
            do {
                return try await exchange(kept, key: key, url: url, head: head, body: body, timeout: timeout)
            } catch let failure as HTTPStream.Failure where failure == .closedBeforeResponse {}
        }
        let stream = try await open(url, timeout: timeout, for: request)
        do {
            return try await exchange(stream, key: key, url: url, head: head, body: body, timeout: timeout)
        } catch let failure as HTTPStream.Failure {
            throw failure.urlError
        }
    }

    private func exchange(_ stream: HTTPStream, key: String, url: URL, head: Data, body: Data, timeout: TimeInterval) async throws
        -> (Data, HTTPURLResponse) {
        let reply = try await stream.exchange(head + body, timeout: timeout)
        if reply.keepAlive { put(stream, key) } else { stream.cancel() }
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            throw URLError(.badServerResponse)
        }
        return (reply.body, response)
    }

    static func key(_ url: URL) -> String { "\(url.host ?? ""):\(url.port ?? 443)" }

    static func head(_ request: URLRequest, host: String, port: Int?, upgrade: String? = nil) -> Data {
        let url = request.url!
        var target = url.path.isEmpty ? "/" : URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        if let query = url.query { target += "?" + query }
        let hostHeader = (host.contains(":") ? "[\(host)]" : host) + (port.map { ":\($0)" } ?? "")
        var lines = ["\(request.httpMethod ?? "GET") \(target) HTTP/1.1", "Host: \(hostHeader)"]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name.lowercased() != "host" && name.lowercased() != "content-length" {
            lines.append("\(name): \(value)")
        }
        if let upgrade {
            lines += ["Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: \(upgrade)"]
        } else {
            lines.append("Content-Length: \(request.httpBody?.count ?? 0)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func take(_ key: String) -> HTTPStream? {
        lock.withLock {
            var list = idle[key] ?? []
            list.removeAll { -$0.since.timeIntervalSinceNow > Self.idleFor || !$0.connection.usable }
            let kept = list.popLast()?.connection
            idle[key] = list
            return kept
        }
    }

    private func put(_ stream: HTTPStream, _ key: String) {
        let extra: HTTPStream? = lock.withLock {
            var list = idle[key] ?? []
            list.append((stream, Date()))
            let extra = list.count > poolSize ? list.removeFirst().connection : nil
            idle[key] = list
            return extra
        }
        extra?.cancel()
    }

    /// Drops every kept connection: the network changed under them.
    public func reset() {
        let all = lock.withLock { () -> [HTTPStream] in
            let all = idle.values.flatMap { $0.map(\.connection) }
            idle = [:]
            return all
        }
        for stream in all { stream.cancel() }
    }

    // MARK: Connections

    /// `seen` gets this connection's key, so concurrent connections each judge their own handshake.
    func parameters(_ seen: SeenKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
        let trust = trust
        sec_protocol_options_set_verify_block(options, { metadata, secTrust, complete in
            let hash = PinnedTrust.hash(sec_trust_copy_ref(secTrust).takeRetainedValue())
            trust.saw(hash)
            seen.hash = hash
            let host = sec_protocol_metadata_get_server_name(metadata).map { String(cString: $0) } ?? "?"
            switch trust.mode {
            case .pinned(let pin):
                KitLog.log(.transport, hash == pin ? "TLS \(host): pin \(KitLog.prefix(pin)) matched"
                                                  : "TLS \(host): saw \(KitLog.prefix(hash)), expected \(KitLog.prefix(pin)), refused")
                complete(hash == pin)
            }
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 30
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// `request` names the first request in the connection's log line; without one it's a GET of `url`.
    func open(_ url: URL, timeout: TimeInterval, for request: URLRequest? = nil) async throws -> HTTPStream {
        guard let host = url.host else { throw URLError(.badURL) }
        let endpoint = dial?(url) ?? .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) ?? 443)
        let seen = SeenKey()
        let stream = HTTPStream(connection: NWConnection(to: endpoint, using: parameters(seen)), queue: queue)
        try await stream.ready(timeout: timeout, mismatch: { seen.mismatch(self.trust.mode) })
        if KitLog.sink != nil { Self.logEstablishment(stream.connection, KitLog.line(request ?? URLRequest(url: url))) }
        return stream
    }

    /// Where a new connection's time went: "connected GET 100.64.1.2:47800/v1/hello: dns 12 ms, tcp 41 ms, tls 38 ms,
    /// 95 ms in all". On cellular this is what says whether the path or the handshake is slow.
    private static func logEstablishment(_ connection: NWConnection, _ line: String) {
        connection.requestEstablishmentReport(queue: .global(qos: .utility)) { report in
            guard let report else { return }
            let ms = { (seconds: TimeInterval) in Int((seconds * 1000).rounded()) }
            var parts: [String] = []
            if let resolution = report.resolutions.first, resolution.duration > 0 { parts.append("dns \(ms(resolution.duration)) ms") }
            for handshake in report.handshakes {
                let name = handshake.definition.name.lowercased()
                parts.append("\(name.contains("tls") ? "tls" : name.contains("tcp") ? "tcp" : name) \(ms(handshake.handshakeDuration)) ms")
            }
            parts.append("\(ms(report.duration)) ms in all")
            KitLog.log(.transport, "connected \(line): \(parts.joined(separator: ", "))")
        }
    }

    // MARK: WebSocket

    public func socket(_ request: URLRequest) -> any SocketConnection {
        NWSocket(request: request, transport: self)
    }
}

/// One TLS connection carrying HTTP/1.1 requests one at a time, then perhaps a WebSocket.
final class HTTPStream: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case closedBeforeResponse, malformed, tooLarge, timedOut, lost
        var urlError: URLError {
            switch self {
            case .closedBeforeResponse, .lost: URLError(.networkConnectionLost)
            case .malformed, .tooLarge: URLError(.badServerResponse)
            case .timedOut: URLError(.timedOut)
            }
        }
    }

    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
        let keepAlive: Bool
        /// Bytes after the head, for a socket.
        let rest: Data
    }

    static let maxHead = 64 << 10
    static let maxBody = 64 << 20

    let connection: NWConnection
    let queue: DispatchQueue
    private var buffer = Data()
    private var failed = false

    init(connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }

    var usable: Bool { !failed && connection.state == .ready }

    func cancel() { failed = true; connection.cancel() }

    /// Waits for the TLS handshake. A key other than the pinned one is `ServerKeyChanged`; Local Network denied waits for
    /// the user's answer until `timeout`, then is `LocalNetworkDenied`.
    func ready(timeout: TimeInterval, mismatch: @escaping @Sendable () -> String?) async throws {
        try await cancellable { [self] once in
            // Both handlers run on `queue`.
            let denied = Flag()
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready: once.resume()
                case .waiting(let error):
                    KitLog.log(.transport, "connect \(connection.endpoint) waiting: \(error) path \(connection.currentPath.map { "\($0.status) \($0.unsatisfiedReason)" } ?? "none")")
                    // Only the Local Network prompt is worth waiting through; anything else, the paths race on rather
                    // than sit out a timeout.
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { denied.value = true; return }
                    connection.cancel()
                    if let seen = mismatch() { return once.resume(throwing: ServerKeyChanged(seen: seen)) }
                    once.resume(throwing: Self.urlError(error))
                case .failed(let error):
                    if let seen = mismatch() { return once.resume(throwing: ServerKeyChanged(seen: seen)) }
                    once.resume(throwing: Self.urlError(error))
                case .cancelled: once.resume(throwing: URLError(.cancelled))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                guard !once.done else { return }
                KitLog.log(.transport, "connect \(connection.endpoint) timed out in \(connection.state)"
                           + " path \(connection.currentPath.map { "\($0.status) \($0.unsatisfiedReason)" } ?? "none")")
                connection.cancel()
                once.resume(throwing: denied.value ? LocalNetworkDenied() : URLError(.timedOut))
            }
        }
    }

    /// Runs `body` with a continuation that a cancelled task ends at once, connection and all: a race's losers stop
    /// when the winner answers instead of holding the group open until their timeouts.
    private func cancellable<T: Sendable>(_ body: @escaping (Once<T>) -> Void) async throws -> T {
        let box = OnceBox<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
                let once = Once(done)
                box.set(once)
                if Task.isCancelled {
                    connection.cancel()
                    return once.resume(throwing: CancellationError())
                }
                body(once)
            }
        } onCancel: { [connection] in
            connection.cancel()
            box.once?.resume(throwing: CancellationError())
        }
    }

    static func urlError(_ error: NWError) -> Error {
        let result = mapped(error)
        // The NWError underneath, so a log can say which POSIX or TLS code it was.
        guard let url = result as? URLError, url.userInfo[NSUnderlyingErrorKey] == nil else { return result }
        var info = url.userInfo
        info[NSUnderlyingErrorKey] = error as NSError
        return URLError(url.code, userInfo: info)
    }

    private static func mapped(_ error: NWError) -> Error {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED, .EHOSTUNREACH, .EHOSTDOWN, .EADDRNOTAVAIL: return URLError(.cannotConnectToHost)
            case .ENETUNREACH, .ENETDOWN: return URLError(.notConnectedToInternet)
            case .ETIMEDOUT: return URLError(.timedOut)
            case .ECONNRESET, .EPIPE, .ECONNABORTED: return URLError(.networkConnectionLost)
            default: return URLError(.cannotConnectToHost)
            }
        case .dns: return URLError(.cannotFindHost)
        case .tls(let status):
            return URLError(.secureConnectionFailed, userInfo: ["_kCFStreamErrorCodeKey": Int(status), "_kCFStreamErrorDomainKey": 3])
        default: return URLError(.cannotConnectToHost)
        }
    }

    func exchange(_ request: Data, timeout: TimeInterval) async throws -> Reply {
        try await cancellable { [self] once in
            connection.send(content: request, completion: .contentProcessed { error in
                if error != nil { once.resume(throwing: Failure.closedBeforeResponse) }
            })
            read(once, sawBytes: false)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                guard !once.done else { return }
                cancel()
                once.resume(throwing: Failure.timedOut)
            }
        }
    }

    private func read(_ once: Once<Reply>, sawBytes: Bool) {
        if let reply = parse() {
            switch reply {
            case .success(let reply): return once.resume(returning: reply)
            case .failure(let failure): cancel(); return once.resume(throwing: failure)
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
            guard !once.done else { return }
            if let data { buffer.append(data) }
            if complete || error != nil, parse() == nil {
                failed = true
                return once.resume(throwing: sawBytes || !(data?.isEmpty ?? true) ? Failure.lost : Failure.closedBeforeResponse)
            }
            read(once, sawBytes: sawBytes || !(data?.isEmpty ?? true))
        }
    }

    /// Adds bytes as if read, and parses: for tests.
    func feed(_ data: Data) -> Result<Reply, Failure>? {
        buffer.append(data)
        return parse()
    }

    /// A whole response from `buffer`, nil while more is needed.
    private func parse() -> Result<Reply, Failure>? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return buffer.count > Self.maxHead ? .failure(.tooLarge) : nil }
        let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else { return .failure(.malformed) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        let start = end.upperBound
        let header = { (name: String) in headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
        let close = header("Connection")?.lowercased().contains("close") ?? false
        if status == 101 || status == 204 || status == 304 || (100..<200).contains(status) {
            let rest = Data(buffer[start...])
            buffer = Data()
            return .success(Reply(status: status, headers: headers, body: Data(), keepAlive: !close && status != 101, rest: rest))
        }
        if let chunked = header("Transfer-Encoding"), chunked.lowercased().contains("chunked") {
            return parseChunked(from: start, status: status, headers: headers, close: close)
        }
        guard let length = header("Content-Length").flatMap(Int.init), length >= 0 else {
            // No length: the body runs to the close, which this server never does; refuse rather than guess.
            return .failure(.malformed)
        }
        guard length <= Self.maxBody else { return .failure(.tooLarge) }
        guard buffer.count - start >= length else { return nil }
        let body = Data(buffer[start..<start + length])
        buffer = Data(buffer[(start + length)...])
        return .success(Reply(status: status, headers: headers, body: body, keepAlive: !close, rest: Data()))
    }

    private func parseChunked(from start: Data.Index, status: Int, headers: [String: String], close: Bool) -> Result<Reply, Failure>? {
        var body = Data()
        var index = start
        while true {
            guard let lineEnd = buffer[index...].range(of: Data("\r\n".utf8)) else { return nil }
            let sizeText = String(decoding: buffer[index..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            let digits = sizeText.trimmingCharacters(in: .whitespaces)
            guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit), digits.count <= 8,
                  let size = Int(digits, radix: 16) else { return .failure(.malformed) }
            guard body.count + size <= Self.maxBody else { return .failure(.tooLarge) }
            let dataStart = lineEnd.upperBound
            if size == 0 {
                // Trailers, if any, then the empty line that ends the message.
                let rest = buffer[dataStart...]
                let end: Data.Index
                if rest.starts(with: Data("\r\n".utf8)) {
                    end = dataStart + 2
                } else {
                    guard let trailers = rest.range(of: Data("\r\n\r\n".utf8)) else {
                        return rest.count > Self.maxHead ? .failure(.tooLarge) : nil
                    }
                    end = trailers.upperBound
                }
                buffer = Data(buffer[end...])
                return .success(Reply(status: status, headers: headers, body: body, keepAlive: !close, rest: Data()))
            }
            guard buffer.count - dataStart >= size + 2 else { return nil }
            guard buffer[dataStart + size..<dataStart + size + 2].elementsEqual(Data("\r\n".utf8)) else { return .failure(.malformed) }
            body.append(buffer[dataStart..<dataStart + size])
            guard body.count <= Self.maxBody else { return .failure(.tooLarge) }
            index = dataStart + size + 2
        }
    }
}

final class Flag: @unchecked Sendable { var value = false }

/// The key one connection's handshake offered.
final class SeenKey: @unchecked Sendable {
    private let lock = NSLock()
    private var _hash: String?
    var hash: String? {
        get { lock.withLock { _hash } }
        set { lock.withLock { _hash = newValue } }
    }

    /// The key seen, when it is a P-256 key other than the pinned one.
    func mismatch(_ mode: PinnedTrust.Mode) -> String? {
        guard case .pinned(let pin) = mode, let hash, hash != pin else { return nil }
        return hash
    }
}

/// Where a cancellation handler finds the continuation, which exists only once the body runs.
final class OnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _once: Once<T>?
    var once: Once<T>? { lock.withLock { _once } }
    func set(_ once: Once<T>) { lock.withLock { _once = once } }
}

/// Resumes a continuation once, whichever callback gets there first.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    var done: Bool { lock.withLock { continuation == nil } }
    private func take() -> CheckedContinuation<T, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
    func resume(returning value: sending T) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }
}

extension Once where T == Void {
    func resume() { resume(returning: ()) }
}
