import Foundation

/// Which relay `sidead run` uses. Like the Mac's release build, a daemon uses the production relay unless told
/// otherwise, so a phone can reach it from anywhere with no setup; `--no-relay` (or `SIDEAD_RELAY_URL=off`) keeps it
/// to the addresses the phone can reach itself.
enum RelayChoice: Equatable {
    case off
    case use(URL)
    case invalid(String)

    /// The same address the Mac's release build uses (`RemoteController.relayURL`).
    static let production = URL(string: "https://push.getsidea.com")!

    static func resolve(option: String?, disabled: Bool, environment: [String: String]) -> RelayChoice {
        if disabled { return .off }
        let text = option ?? environment["SIDEAD_RELAY_URL"]
        guard let text else { return .use(production) }
        if text.isEmpty || ["off", "none"].contains(text.lowercased()) { return .off }
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme ?? ""), url.host != nil else { return .invalid(text) }
        return .use(url)
    }
}
