import CryptoKit
import Foundation
import SideACore
import SideAProtocol

/// The Mac's side of the push relay (relay-and-release, Push relay): every request signed with the install key. The
/// install registers itself on first use, and again if the relay has forgotten it; a clock the relay calls skewed is
/// corrected from its `Date` once and retried.
final class RelayClient: @unchecked Sendable {
    struct Failure: Error, LocalizedError, Equatable {
        let status: Int
        let code: String
        let message: String
        var retryAfter: Double?
        var errorDescription: String? { message.isEmpty ? "The notification relay answered \(status)." : message }
        static let unreachable = Failure(status: 0, code: "unreachable", message: "Side A can't reach the notification relay.")
    }

    /// `PUT /v1/devices/{id}`.
    struct Device: Encodable {
        let apnsToken: String
        let bundleID: String
        let apnsEnvironment: String
        let secretHash: String
        let pushToStartToken: String?
        let appVersion: String
    }

    /// `POST /v1/send`, an alert or a dismissal.
    struct Send: Encodable, Sendable {
        let devices: [String]
        let kind: String
        var category: String?
        let collapseId: String
        var priority: Int?
        var expiresIn: Int?
        var sound: Bool?
        var level: String?
        var sealed: [String: String]?
    }

    /// `POST /v1/send` with `kind: "liveactivity"`.
    struct Activity: Encodable, Sendable {
        let devices: [String]
        let kind = "liveactivity"
        let event: String
        var activityId: String?
        let contentState: ActivityContentState
        var staleDate: Double?
        var dismissalDate: Double?
        var priority: Int?
    }

    struct Result: Decodable, Equatable {
        let device: String
        /// ok, gone, retry, rejected, unverified.
        let result: String
        var after: Double?
        var reason: String?
        var apnsId: String?
    }

    let base: URL
    let installID: String
    private let key: Curve25519.Signing.PrivateKey
    private let session: URLSession
    private let lock = NSLock()
    private var skew = 0
    private var registered = false

    init(base: URL, key: Curve25519.Signing.PrivateKey, session: URLSession = .shared) {
        self.base = base; self.key = key; self.session = session
        installID = RelaySignature.installID(key.publicKey.rawRepresentation)
    }

    func register() async throws {
        struct Register: Encodable { let publicKey: String }
        _ = try await call("POST", "/v1/installs", Register(publicKey: key.publicKey.rawRepresentation.base64URL), registering: true)
        lock.withLock { registered = true }
    }

    /// Whether the token is already verified; otherwise the relay has sent the phone its challenge.
    func put(_ id: String, _ device: Device) async throws -> Bool {
        struct Verified: Decodable { let verified: Bool }
        return try JSONDecoder().decode(Verified.self, from: try await call("PUT", "/v1/devices/\(id)", device)).verified
    }

    /// `GET /v1/installs/self`; false when the relay doesn't know the install. Never registers it.
    func registered() async throws -> Bool {
        do {
            _ = try await attempt("GET", "/v1/installs/self", Optional<String>.none)
            return true
        } catch let failure as Failure where failure.status == 404 {
            return false
        } catch let failure as Failure where failure.status == 401 && failure.code == "clock_skew" {
            _ = try await attempt("GET", "/v1/installs/self", Optional<String>.none)
            return true
        }
    }

    func delete(_ id: String) async throws { _ = try await call("DELETE", "/v1/devices/\(id)", Optional<String>.none) }
    func deleteInstall() async throws { _ = try await call("DELETE", "/v1/installs", Optional<String>.none) }

    private struct Results: Decodable { let results: [Result] }
    private struct Envelope: Decodable { struct Body: Decodable { let code: String; let message: String? }; let error: Body }

    func send(_ send: some Encodable & Sendable) async throws -> [Result] {
        try JSONDecoder().decode(Results.self, from: try await call("POST", "/v1/send", send)).results
    }

    private func call(_ method: String, _ path: String, _ body: (some Encodable)?, registering: Bool = false) async throws -> Data {
        if !registering, !lock.withLock({ registered }) { try await register() }
        do {
            return try await attempt(method, path, body)
        } catch let failure as Failure where failure.status == 401 && failure.code == "clock_skew" {
            return try await attempt(method, path, body)
        } catch let failure as Failure where failure.status == 401 && failure.code == "unauthorized" && !registering {
            // An install the relay dropped (30 days without a device, 90 without a send) comes back under the same key.
            try await register()
            return try await attempt(method, path, body)
        }
    }

    private func attempt(_ method: String, _ path: String, _ body: (some Encodable)?) async throws -> Data {
        let data = try body.map { try JSONEncoder().encode($0) } ?? Data()
        var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())), timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body == nil ? nil : data
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let ts = Int(Date().timeIntervalSince1970) + lock.withLock { skew }
        request.setValue(try RelaySignature.authorization(key, method: method, path: path, body: data, ts: ts), forHTTPHeaderField: "Authorization")
        let (reply, response): (Data, URLResponse)
        do { (reply, response) = try await session.data(for: request) } catch { throw Failure.unreachable }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        if (200..<300).contains(http.statusCode) { return reply }
        let error = try? JSONDecoder().decode(Envelope.self, from: reply).error
        let failure = Failure(status: http.statusCode, code: error?.code ?? "http_\(http.statusCode)", message: error?.message ?? "",
                              retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        if failure.code == "clock_skew", let date = http.value(forHTTPHeaderField: "Date").flatMap(Self.httpDate) {
            lock.withLock { skew = Int(date.timeIntervalSinceNow.rounded()) }
        }
        throw failure
    }

    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
