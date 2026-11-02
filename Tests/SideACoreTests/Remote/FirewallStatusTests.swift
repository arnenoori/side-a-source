import Testing
@testable import SideACore

private let me = "/Applications/Side A.app/Contents/MacOS/SideA"
private let on = "Firewall is enabled. (State = 1)"
private let open = "Firewall has block all state set to disabled."
private let signedOK = "Automatically allow built-in signed software ENABLED.\nAutomatically allow downloaded signed software ENABLED."

private func listing(_ rule: String?) -> String {
    var lines = ["Total number of apps = 2 ", "1 : /Applications/Safari.app/Contents/MacOS/Safari ", "             (Allow incoming connections)"]
    if let rule { lines += ["2 : \(me) ", "             (\(rule) incoming connections)"] }
    return lines.joined(separator: "\n")
}

/// socketfilterfw's own words, as macOS 27 prints them; `--getappblocked` is never trusted (it permits unknown paths).
@Test func theFirewallVerdictComesFromTheListingNotGetAppBlocked() {
    func verdict(global: String = on, blockAll: String = open, allowSigned: String = signedOK, rule: String?, signed: Bool) -> FirewallStatus {
        FirewallStatus.parse(global: global, blockAll: blockAll, allowSigned: allowSigned, listing: listing(rule), executable: me, signed: signed)
    }
    #expect(verdict(global: "Firewall is disabled. (State = 0)", rule: "Block", signed: false) == .off)
    #expect(verdict(blockAll: "Firewall has block all state set to enabled.", rule: "Allow", signed: true) == .blocked)
    #expect(verdict(rule: "Allow", signed: false) == .allowed)
    #expect(verdict(rule: "Block", signed: true) == .blocked)
    // No rule: a Developer ID build is let in by "downloaded signed software"; an ad-hoc one is dropped silently.
    #expect(verdict(rule: nil, signed: true) == .allowed)
    #expect(verdict(rule: nil, signed: false) == .unlisted)
    #expect(verdict(allowSigned: "Automatically allow downloaded signed software DISABLED.", rule: nil, signed: true) == .unlisted)
    #expect(FirewallStatus.unlisted.blocksPhones && FirewallStatus.blocked.blocksPhones && !FirewallStatus.allowed.blocksPhones)
}
