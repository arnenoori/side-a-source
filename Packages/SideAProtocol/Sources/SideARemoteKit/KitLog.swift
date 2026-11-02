import Foundation
import SideAProtocol

/// Where the kit's diagnostics go: the app points `sink` at its log. Nothing logged carries a token,
/// a pairing code or a body; addresses, paths, status codes, durations and key-hash prefixes only.
public enum KitLog {
    public enum Category: String, Sendable { case pairing, transport, sync, terminal }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _sink: (@Sendable (Category, String) -> Void)?

    public static var sink: (@Sendable (Category, String) -> Void)? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }

    static func log(_ category: Category, _ message: @autoclosure () -> String) {
        guard let sink else { return }
        sink(category, message())
    }

    /// The first 8 characters of a key hash: enough to tell two keys apart in a log.
    public static func prefix(_ hash: String?) -> String {
        hash.map { String($0.prefix(8)) + "…" } ?? "none"
    }

    /// Which way a request went: the relay, a tailnet address (100.64.0.0/10 or MagicDNS), or the LAN.
    public static func route(_ host: String?) -> String {
        guard let host else { return "?" }
        if host == Paths.relayHost { return "relay" }
        if host.hasSuffix(".ts.net") { return "tailnet" }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return "tailnet" }
        return "lan"
    }

    /// "GET 100.93.122.83:47900/v1/hello [tailnet]": no headers, and the path as `path(_:)` leaves it.
    static func line(_ request: URLRequest) -> String {
        let url = request.url
        return "\(request.httpMethod ?? "GET") \(url?.host() ?? "?")\(url?.port.map { ":\($0)" } ?? "")\(path(url)) [\(route(url?.host()))]"
    }

    /// A request's path with anything secret taken out, as the Mac's `RemoteLog.path` does: never a query or fragment,
    /// a pairing attempt's id as "…" (it stands for the code until the Mac confirms), everything after
    /// `/v1/preview/` (a preview's credential), and a preview page's own path as "/(preview page)". For the app's
    /// log too, so both redact alike.
    public static func path(_ url: URL?) -> String {
        guard let url else { return "?" }
        var parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0].isEmpty, parts[1] == "v1" else { return "/(preview page)" }
        if parts.count >= 3, parts[2] == "pair", parts.count >= 4 { parts[3] = "…" }
        if parts.count >= 3, parts[2] == "preview" { parts = Array(parts.prefix(3)) + ["…"] }
        return parts.joined(separator: "/")
    }

    /// Milliseconds since `start`.
    static func ms(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// "URLError -1001 timedOut; NSPOSIXErrorDomain 60; stream 1/60; path …": the codes that say where a
    /// connection failed, which `localizedDescription` hides.
    public static func describe(_ error: any Error) -> String {
        switch error {
        case let error as URLError:
            var parts = ["URLError \(error.code.rawValue)"]
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                parts.append("\(underlying.domain) \(underlying.code)")
            }
            if let domain = error.userInfo["_kCFStreamErrorDomainKey"] as? Int, let code = error.userInfo["_kCFStreamErrorCodeKey"] as? Int {
                parts.append("stream \(domain)/\(code)")
            }
            if let path = error.userInfo["_NSURLErrorNWPathKey"] {
                parts.append("path \(String(describing: path))")
            }
            return parts.joined(separator: "; ")
        case let error as SocketClosed:
            return "socket closed \(error.code)\(error.reason.map { " \($0)" } ?? "")"
        case let error as ServerKeyChanged:
            return "server key changed, saw \(prefix(error.seen))"
        case is LocalNetworkDenied:
            return "Local Network denied"
        case let error as RemoteFailure:
            return "HTTP \(error.status) \(error.error.code.rawValue)"
        default:
            let error = error as NSError
            return "\(error.domain) \(error.code)"
        }
    }
}

/// What one pairing probe tried, address by address, for the failure card's Details.
public final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []

    public init() {}

    /// "192.168.1.20:47800 · timed out after 4.0 s (URLError -1001; …)", in the order tried.
    public var lines: [String] { lock.withLock { _lines } }

    func reset() { lock.withLock { _lines = [] } }
    func add(_ line: String) { lock.withLock { _lines.append(line) } }
}
