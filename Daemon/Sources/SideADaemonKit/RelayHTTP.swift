import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SideACore
import SideAProtocol

/// The relay a daemon pairs through and pushes through: the same Cloudflare Worker the Mac uses (relay/DEPLOY.md), with
/// the same signed requests. The daemon never changes what the relay accepts; it is one more install.
public struct RelayConfig: Sendable {
    public var url: URL
    /// How a request leaves; tests answer it themselves. Nil is `URLSession`.
    public var fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    /// Whether to hold the tunnel open (the push relay alone needs no tunnel).
    public var tunnel = true

    public init(url: URL) { self.url = url }
}

/// The daemon's install key at the relay: an Ed25519 key made once and kept with the other secrets. Its public half names
/// the install (`RelaySignature.installID`); the relay knows nothing else about this computer.
public enum RelayIdentity {
    static let name = "relay-install.key"

    public static func loadOrCreate(in store: any SecretStore) throws -> Curve25519.Signing.PrivateKey {
        if let raw = try store.read(name), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return key }
        let key = Curve25519.Signing.PrivateKey()
        try store.write(name, key.rawRepresentation)
        return key
    }

    public static func installID(_ key: Curve25519.Signing.PrivateKey) -> String { RelaySignature.installID(key.publicKey.rawRepresentation) }
}

/// The daemon's side of the relay's REST calls, as the Mac's `RelayClient` makes them: every request signed, the install
/// registered on first use and again if the relay forgot it, a clock the relay calls skewed corrected from its `Date`.
final class RelayHTTP: @unchecked Sendable {
    struct Failure: Error, Equatable, CustomStringConvertible {
        let status: Int
        let code: String
        let message: String
        var retryAfter: Double?
        var description: String { message.isEmpty ? "The notification relay answered \(status)." : message }
        static let unreachable = Failure(status: 0, code: "unreachable", message: "The daemon can't reach the notification relay.")
    }

    struct Device: Encodable {
        let apnsToken: String
        let bundleID: String
        let apnsEnvironment: String
        let secretHash: String
        let pushToStartToken: String?
        let appVersion: String
        var notifyQuiet: Bool?
    }

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

    struct Result: Decodable, Equatable {
        let device: String
        let result: String
        var after: Double?
        var reason: String?
    }

    let base: URL
    let installID: String
    private let key: Curve25519.Signing.PrivateKey
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let lock = NSLock()
    private var skew = 0
    private var registered = false

    init(base: URL, key: Curve25519.Signing.PrivateKey, fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.base = base; self.key = key
        self.fetch = fetch ?? { try await URLSession.shared.data(for: $0) }
        installID = RelayIdentity.installID(key)
    }

    func register() async throws {
        struct Register: Encodable { let publicKey: String }
        _ = try await call("POST", "/v1/installs", Register(publicKey: key.publicKey.rawRepresentation.base64URL), registering: true)
        lock.withLock { registered = true }
    }

    func put(_ id: String, _ device: Device) async throws -> Bool {
        struct Verified: Decodable { let verified: Bool }
        return try JSONDecoder().decode(Verified.self, from: try await call("PUT", "/v1/devices/\(id)", device)).verified
    }

    func delete(_ id: String) async throws { _ = try await call("DELETE", "/v1/devices/\(id)", Optional<String>.none) }

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
        do { (reply, response) = try await fetch(request) } catch { throw Failure.unreachable }
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

    /// The most devices one send may name: the relay's MAX_DEVICES.
    static let maxDevices = 10

    /// A version string the relay accepts: up to 32 of [0-9A-Za-z.+() -].
    static func version(_ app: String) -> String {
        let clean = String(app.filter { $0.isASCII && ($0.isLetter || $0.isNumber || ".+() -".contains($0)) }.prefix(32))
        return clean.isEmpty ? "0" : clean
    }

    /// A collapse id: up to 64 of [A-Za-z0-9_-]; anything else is hashed.
    static func collapse(_ id: String) -> String {
        let clean = String(id.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-" || $0 == "_") })
        return clean.isEmpty || clean.count > 64 ? Data(SHA256.hash(data: Data(id.utf8)).prefix(24)).base64URL : clean
    }
}
