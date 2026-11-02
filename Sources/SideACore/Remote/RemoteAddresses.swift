import Darwin
import Foundation

/// Which of the Mac's addresses Remote listens on: its tailnet addresses, and with Wi-Fi pairing on, its LAN ones.
public struct RemoteAddresses: Sendable, Equatable {
    public var tailnet: [String] = []
    public var lan: [String] = []

    public init(tailnet: [String] = [], lan: [String] = []) { self.tailnet = tailnet; self.lan = lan }

    public struct Interface: Sendable, Equatable {
        public let name: String
        public let address: String
        public init(_ name: String, _ address: String) { self.name = name; self.address = address }
    }

    /// Tailscale's are on a utun interface: IPv4 in 100.64.0.0/10, IPv6 in fd7a:115c:a1e0::/48. LAN is a private
    /// IPv4 on an en interface; link-local and public addresses are never served.
    public static func classify(_ interfaces: [Interface]) -> RemoteAddresses {
        var out = RemoteAddresses()
        for interface in interfaces {
            if interface.name.hasPrefix("utun"), isTailnet(interface.address) {
                if !out.tailnet.contains(interface.address) { out.tailnet.append(interface.address) }
            } else if interface.name.hasPrefix("en"), isPrivateIPv4(interface.address), !out.lan.contains(interface.address) {
                out.lan.append(interface.address)
            }
        }
        // IPv4 first: it's the one the QR code carries.
        out.tailnet.sort { ($0.contains(":") ? 1 : 0, $0) < ($1.contains(":") ? 1 : 0, $1) }
        return out
    }

    public static func isTailnet(_ address: String) -> Bool {
        if let v4 = ipv4(address) { return v4[0] == 100 && v4[1] & 0xC0 == 64 }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        return withUnsafeBytes(of: v6) { Array($0.prefix(6)) } == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
    }

    static func isPrivateIPv4(_ address: String) -> Bool {
        guard let v4 = ipv4(address) else { return false }
        return v4[0] == 10 || (v4[0] == 172 && v4[1] & 0xF0 == 16) || (v4[0] == 192 && v4[1] == 168)
    }

    private static func ipv4(_ address: String) -> [UInt8]? {
        var v4 = in_addr()
        guard inet_pton(AF_INET, address, &v4) == 1 else { return nil }
        return withUnsafeBytes(of: v4) { Array($0) }
    }

    /// The Mac's interfaces now, up and with an address; `primary`'s first.
    public static func current(primary: String? = nil) -> RemoteAddresses {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return RemoteAddresses() }
        defer { freeifaddrs(list) }
        var interfaces: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, let address = entry.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(decoding: UnsafeRawBufferPointer(start: entry.ifa_name, count: strlen(entry.ifa_name)), as: UTF8.self)
            interfaces.append(Interface(name, String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
        }
        return classify(interfaces.filter { $0.name == primary } + interfaces.filter { $0.name != primary })
    }
}
