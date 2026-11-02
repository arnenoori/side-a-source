import Foundation

/// What `tailscale status --json` says about this Mac. Side A only reads it; nothing in tailscaled changes.
public struct TailscaleStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case notInstalled, stopped, needsLogin, noAddress
        case ready
    }

    public struct Peer: Sendable, Equatable {
        public let name: String
        public let online: Bool
    }

    public var state: State
    public var version: String?
    /// IPv4 first, then IPv6.
    public var addresses: [String] = []
    /// Without the trailing dot; nil when the tailnet has no MagicDNS.
    public var dnsName: String?
    public var tailnet: String?
    public var login: String?
    /// iPhones and iPads on the tailnet: advice for setup, never a gate.
    public var phones: [Peer] = []

    public init(state: State, version: String? = nil) { self.state = state; self.version = version }

    public static func parse(_ data: Data) -> TailscaleStatus {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return TailscaleStatus(state: .stopped) }
        var status = TailscaleStatus(state: .ready, version: (root["Version"] as? String).map { String($0.split(separator: "-").first ?? "") })
        switch root["BackendState"] as? String {
        case "Running": break
        case "NeedsLogin", "NeedsMachineAuth": status.state = .needsLogin; return status
        default: status.state = .stopped; return status
        }
        let me = root["Self"] as? [String: Any] ?? [:]
        let ips = (me["TailscaleIPs"] as? [String] ?? root["TailscaleIPs"] as? [String] ?? []).filter(RemoteAddresses.isTailnet)
        status.addresses = ips.sorted { ($0.contains(":") ? 1 : 0, $0) < ($1.contains(":") ? 1 : 0, $1) }
        let tailnet = root["CurrentTailnet"] as? [String: Any]
        status.tailnet = tailnet?["Name"] as? String
        if tailnet?["MagicDNSEnabled"] as? Bool != false, let name = me["DNSName"] as? String, !name.isEmpty {
            status.dnsName = name.hasSuffix(".") ? String(name.dropLast()) : name
        }
        if let id = me["UserID"].map({ "\($0)" }), let users = root["User"] as? [String: Any],
           let user = users[id] as? [String: Any] {
            status.login = user["LoginName"] as? String
        }
        let peers = (root["Peer"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
        status.phones = peers.filter { ["iOS", "iPadOS"].contains($0["OS"] as? String ?? "") }
            .map { peer in
                let dns = (peer["DNSName"] as? String ?? "").split(separator: ".").first.map(String.init)
                let host = peer["HostName"] as? String
                return Peer(name: host.flatMap { $0 == "localhost" || $0.isEmpty ? nil : $0 } ?? dns ?? "iPhone", online: peer["Online"] as? Bool ?? false)
            }
            .sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
        if status.addresses.isEmpty { status.state = .noAddress }
        return status
    }
}
