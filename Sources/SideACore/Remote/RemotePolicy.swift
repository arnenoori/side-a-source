import Foundation

/// Checks every request makes before auth: whose address it was sent to, and that no browser sent it.
public enum RemotePolicy {
    /// Whose budget an unauthenticated caller spends. Phones behind the relay share one: a new tunnel socket gets a new
    /// slot, so a budget per slot would let anyone cycling sockets start afresh every time.
    public static func budget(_ source: String) -> String { source.hasPrefix("tunnel:") ? "tunnel" : source }

    /// The first phone build that signs what the Mac now requires. Below it, `Hello` and every authenticated call say to update.
    public static let minClientBuild = 12

    /// The build in `X-SideA-Client: SideARemote/1.0 (12; iOS 26.0)`. Only for the update message: the header is the
    /// caller's word, and the signatures behind it are what's enforced.
    public static func clientBuild(_ header: String?) -> Int? {
        guard let header, header.hasPrefix("SideARemote/"), let open = header.firstIndex(of: "(") else { return nil }
        return Int(header[header.index(after: open)...].prefix { $0.isNumber })
    }

    public enum Refusal: Sendable, Equatable {
        /// 421: a Host that isn't one of the Mac's own addresses, as DNS rebinding sends.
        case host
        /// 403: browsers send Origin or Sec-Fetch-Site on the requests that matter; the app sends neither.
        case browser
    }

    /// `hosts` are the names and addresses the Mac answers to, without ports, lowercased; IPv6 without brackets.
    public static func check(_ headers: HTTPHeaders, hosts: Set<String>, port: UInt16) -> Refusal? {
        guard headers.all("Host").count == 1, let host = headers["Host"], let (name, given) = split(host),
              hosts.contains(name), given == nil || given == port else { return .host }
        if headers["Origin"] != nil || headers["Sec-Fetch-Site"] != nil { return .browser }
        return nil
    }

    /// A dev server preview is a page in the phone's WebView, so it may send `Origin` and `Sec-Fetch-Site`, but only
    /// for this listener's own origin: another site can't drive a preview from inside someone's browser.
    public static func checkPreview(_ headers: HTTPHeaders, hosts: Set<String>, port: UInt16) -> Refusal? {
        guard headers.all("Host").count == 1, let host = headers["Host"], let (name, given) = split(host),
              hosts.contains(name), given == nil || given == port else { return .host }
        if let origin = headers["Origin"], origin.lowercased() != "https://" + host.lowercased() { return .browser }
        if let site = headers["Sec-Fetch-Site"], !["same-origin", "none"].contains(site.lowercased()) { return .browser }
        return nil
    }

    /// `[fd7a::1]:47800` → ("fd7a::1", 47800); `mac.local` → ("mac.local", nil).
    static func split(_ host: String) -> (String, UInt16?)? {
        let host = host.lowercased()
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let name = String(host[host.index(after: host.startIndex)..<close])
            let rest = host[host.index(after: close)...]
            if rest.isEmpty { return (name, nil) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return (name, port)
        }
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        guard !host.isEmpty, parts.count <= 2 else { return nil }
        // A fully qualified name may end in a dot.
        let name = parts[0].hasSuffix(".") ? String(parts[0].dropLast()) : String(parts[0])
        if parts.count == 1 { return (name, nil) }
        guard let port = UInt16(parts[1]) else { return nil }
        return (name, port)
    }

    /// A token bucket on a clock the caller passes, so tests run it without waiting.
    public struct TokenBucket: Sendable {
        public let rate: Double
        public let burst: Double
        /// After the bucket runs dry, refused until this long has passed, however it refills.
        public let lockout: TimeInterval
        private var tokens: Double
        private var at: TimeInterval
        private var lockedUntil: TimeInterval = 0

        public init(rate: Double, burst: Double, lockout: TimeInterval = 0, now: TimeInterval) {
            self.rate = rate; self.burst = burst; self.lockout = lockout
            tokens = burst; at = now
        }

        /// nil when allowed, else the seconds to wait.
        public mutating func take(now: TimeInterval) -> TimeInterval? {
            if now < lockedUntil { return lockedUntil - now }
            tokens = min(burst, tokens + max(0, now - at) * rate)
            at = now
            if tokens >= 1 { tokens -= 1; return nil }
            if lockout > 0 { lockedUntil = now + lockout; return lockout }
            return (1 - tokens) / rate
        }
    }
}
