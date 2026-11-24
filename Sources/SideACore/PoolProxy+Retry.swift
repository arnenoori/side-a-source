#if canImport(Network)
import Foundation

extension PoolProxy {
    /// Failures from before a byte left this Mac: it was offline, or the name or the host couldn't be reached. Sending
    /// again can't bill a turn twice.
    /// A TLS handshake that failed, as it does while Wi-Fi comes back, ends before the request is written.
    static func unsent(_ error: any Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .dataNotAllowed,
                .internationalRoamingOff, .secureConnectionFailed, .cannotLoadFromNetwork].contains(code)
    }

    static func cutOff(_ error: any Error) -> Bool {
        [.networkConnectionLost, .timedOut].contains((error as? URLError)?.code)
    }

    /// A token renewal the bridge couldn't make for want of a network: Python's urllib says so in its own words.
    public static func networkAway(_ error: any Error) -> Bool {
        unsent(error) || cutOff(error) || error.localizedDescription.contains("urlopen error")
    }

    /// The routes that produce a turn, and those that change nothing (a read, a token count). Nothing else admitted is
    /// resent on a lost connection.
    public static func resends(_ target: String, method: String = "POST") -> Bool {
        if ["GET", "HEAD"].contains(method.uppercased()) { return true }
        let path = target.split(separator: "?", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return ["/v1/messages", "/codex/responses", "/v1/messages/count_tokens"].contains(path)
    }
}
#endif
