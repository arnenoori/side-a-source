import Foundation
import SideAProtocol

public enum SocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// The peer closed the socket with this code.
public struct SocketClosed: Error, Sendable, Equatable {
    public let code: Int
    public let reason: String?
    public init(code: Int, reason: String? = nil) { self.code = code; self.reason = reason }
}

/// One WebSocket. `receive` throws `SocketClosed` once the peer closes it.
public protocol SocketConnection: Sendable {
    func send(_ message: SocketMessage) async throws
    func receive() async throws -> SocketMessage
    func sendPing() async throws
    func close(code: Int, reason: String?)
}

/// HTTP and WebSockets, so tests can play a scripted Mac.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func socket(_ request: URLRequest) -> any SocketConnection
    /// The Mac reported these addresses in a hello over the pinned key.
    func learned(_ endpoints: Endpoints) async
}

extension Transport {
    public func learned(_ endpoints: Endpoints) async {}
}

/// The Mac answered with a TLS key other than the one pinned at pairing. Nothing was sent: the
/// handshake was refused before any request, token included, left the phone.
public struct ServerKeyChanged: Error, Sendable, Equatable {
    /// The hash of the key it offered.
    public let seen: String
    public init(seen: String) { self.seen = seen }
}

/// Accepts one TLS key and no other, whatever the name or chain says: the SPKI hash from the pairing QR code.
/// Pairing is QR-only, so there is no mode that accepts a key it hasn't seen before.
public final class PinnedTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    public enum Mode: Sendable, Equatable { case pinned(String) }
    public let mode: Mode
    private let lock = NSLock()
    private var _observed: String?

    public init(_ mode: Mode) { self.mode = mode }

    /// The hash of the last key seen.
    public var observed: String? { lock.withLock { _observed } }

    func saw(_ hash: String?) { lock.withLock { _observed = hash } }

    /// The last key seen, when it is a P-256 key other than the pinned one.
    public var mismatch: String? {
        guard case .pinned(let pin) = mode, let observed, observed != pin else { return nil }
        return observed
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let hash = Self.hash(trust)
        saw(hash)
        let host = challenge.protectionSpace.host
        switch mode {
        case .pinned(let pin) where hash == pin:
            KitLog.log(.transport, "TLS \(host): pin \(KitLog.prefix(pin)) matched")
            return (.useCredential, URLCredential(trust: trust))
        case .pinned(let pin):
            KitLog.log(.transport, "TLS \(host): saw \(KitLog.prefix(hash)), expected \(KitLog.prefix(pin)), refused")
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    /// The leaf certificate's SPKI hash; nil for anything but a P-256 key.
    public static func hash(_ trust: SecTrust) -> String? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first, let key = SecCertificateCopyKey(leaf),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              attributes[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              let x963 = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return SPKI.hash(p256: x963)
    }
}

public struct URLSessionTransport: Transport {
    let session: URLSession
    let trust: PinnedTrust?
    public init(session: URLSession = .shared) { self.session = session; trust = nil }

    /// `session` already has `trust` as its delegate.
    init(session: URLSession, trust: PinnedTrust) { self.session = session; self.trust = trust }

    /// A session that checks every connection, REST and WebSocket alike, against `trust`.
    public init(trust: PinnedTrust) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
        self.trust = trust
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let line = KitLog.line(request)
        let start = ContinuousClock.now
        let (data, response): (Data, URLResponse)
        do {
            do { (data, response) = try await session.data(for: request) } catch let error as URLError where error.code == .cancelled {
                // The trust delegate refused the handshake: say why, rather than "cancelled".
                if let seen = trust?.mismatch { throw ServerKeyChanged(seen: seen) }
                throw error
            }
        } catch {
            KitLog.log(.transport, "\(line) failed after \(KitLog.ms(since: start)) ms: \(KitLog.describe(error))")
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        KitLog.log(.transport, "\(line) → \(http.statusCode) in \(KitLog.ms(since: start)) ms")
        return (data, http)
    }

    public func socket(_ request: URLRequest) -> any SocketConnection {
        URLSessionSocket(task: session.webSocketTask(with: request))
    }
}

final class URLSessionSocket: SocketConnection, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    let category: KitLog.Category
    let line: String
    init(task: URLSessionWebSocketTask) {
        self.task = task
        line = task.originalRequest.map(KitLog.line) ?? "socket"
        category = line.contains("/ws/term") ? .terminal : .sync
        task.maximumMessageSize = 1 << 20
        task.resume()
        KitLog.log(category, "socket open \(line)")
    }

    func send(_ message: SocketMessage) async throws {
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .data(let data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> SocketMessage {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .data(data)
            @unknown default: throw URLError(.cannotParseResponse)
            }
        } catch {
            // Application close codes (4401, 4426, …) come through as raw values of the imported enum.
            // A refused upgrade never opens; its status says the same as the matching close code.
            if let status = (task.response as? HTTPURLResponse)?.statusCode, [401, 426, 429].contains(status) {
                KitLog.log(category, "socket refused \(line): HTTP \(status)")
                throw SocketClosed(code: 4000 + status)
            }
            guard task.closeCode != .invalid else {
                KitLog.log(category, "socket failed \(line): \(KitLog.describe(error))")
                throw error
            }
            KitLog.log(category, "socket closed \(line): \(task.closeCode.rawValue)")
            throw SocketClosed(code: task.closeCode.rawValue, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) })
        }
    }

    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            task.sendPing { error in if let error { done.resume(throwing: error) } else { done.resume() } }
        }
    }

    func close(code: Int, reason: String?) {
        KitLog.log(category, "socket close \(line): \(code)")
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: reason.map { Data($0.utf8) })
    }
}
