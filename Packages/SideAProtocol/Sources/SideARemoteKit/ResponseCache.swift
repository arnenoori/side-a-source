import CryptoKit
import Foundation

/// The last body and `ETag` of each cacheable GET, so a resend carries `If-None-Match` and a 304 reuses the body.
/// Memory only, keyed per Mac and per device token; an unpair (`Paths.forget`) or a 401 drops the Mac's entries.
public final class ResponseCache: @unchecked Sendable {
    public static let shared = ResponseCache()

    /// The reads whose bodies the Mac tags (state, sessions, history, projects, options, accounts).
    static let paths: Set<String> = ["/v1/state", "/v1/sessions", "/v1/history", "/v1/projects", "/v1/options", "/v1/accounts"]

    struct Entry { let etag: String; let body: Data }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Oldest first, for eviction past `limit`.
    private var order: [String] = []
    let limit: Int

    public init(limit: Int = 64) { self.limit = limit }

    /// Nil when the request isn't one the cache keeps.
    static func key(macID: String, _ request: URLRequest) -> String? {
        guard request.httpMethod == "GET", let url = request.url, paths.contains(url.path) else { return nil }
        let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let device = Data(SHA256.hash(data: Data(token.utf8)).prefix(16)).base64EncodedString()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery.map { "?" + $0 } ?? ""
        return macID + "\n" + device + "\n" + url.path + query
    }

    func entry(_ key: String) -> Entry? { lock.withLock { entries[key] } }

    func store(_ key: String, etag: String, body: Data) {
        lock.withLock {
            if entries.updateValue(Entry(etag: etag, body: body), forKey: key) != nil { order.removeAll { $0 == key } }
            order.append(key)
            while order.count > limit { entries.removeValue(forKey: order.removeFirst()) }
        }
    }

    func remove(_ key: String) {
        lock.withLock {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
    }

    /// Every entry for the Mac, whatever token it was read with.
    public func forget(macID: String) {
        lock.withLock {
            order.removeAll { key in
                guard key.hasPrefix(macID + "\n") else { return false }
                entries.removeValue(forKey: key)
                return true
            }
        }
    }

    var count: Int { lock.withLock { entries.count } }
}
