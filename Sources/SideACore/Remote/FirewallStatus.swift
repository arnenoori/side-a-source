import Foundation

/// What the macOS application firewall does with incoming connections to Side A, read from `socketfilterfw`'s answers
/// (no sudo needed to read). `--getappblocked` says "permitted" for any path it doesn't know, so the listing decides.
public enum FirewallStatus: Sendable, Equatable {
    case off
    case allowed
    /// Block all incoming, or a Block rule for Side A.
    case blocked
    /// No rule and not allowed automatically: connections are dropped without a prompt.
    case unlisted

    public var blocksPhones: Bool { self == .blocked || self == .unlisted }

    /// `signed`: a Developer ID build, which "Automatically allow downloaded signed software" lets in with no rule.
    public static func parse(global: String, blockAll: String, allowSigned: String, listing: String, executable: String,
                             signed: Bool) -> FirewallStatus {
        guard global.contains("State = 1") || global.contains("State = 2") else { return .off }
        if blockAll.contains("enabled") { return .blocked }
        let lines = listing.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            guard let colon = line.range(of: " : ") else { continue }
            let path = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            guard path == executable, index + 1 < lines.count else { continue }
            return lines[index + 1].contains("Block") ? .blocked : .allowed
        }
        return signed && allowSigned.contains("downloaded signed software ENABLED") ? .allowed : .unlisted
    }
}
