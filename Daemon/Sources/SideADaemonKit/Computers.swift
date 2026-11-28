import Foundation
import SideACore
import SideAProtocol

/// Another of the user's computers (a Mac running Side A, or another `sidead`) that this one may send sessions to and
/// take them from (docs/remote/protocol.md, "Linking two computers"). The other computer paired here as a client, and
/// sent this half: where it listens, the key to pin, and a token for its server. A token here is shell access there,
/// which is what a link is, so the record lives in a 0600 file beside the paired devices.
public struct LinkedComputer: Codable, Sendable, Equatable, Identifiable {
    /// The other computer's host id.
    public let id: String
    public var name: String
    public var os: HostOS?
    public var endpoints: Endpoints
    /// base64url SHA-256 of the other computer's TLS SPKI: what every call to it is pinned to.
    public var pin: String
    /// The token its server gave this computer.
    public var token: String
    public var relay: RelayInfo?
    /// The device id this computer is known by there, and the relay secret that goes with it.
    public var deviceID: String
    public var deviceSecret: String
    /// The device here that the other computer calls in as.
    public var device: String?
    /// This computer's signing keys for calls to the other one (P-256, raw): the stand-ins for a phone's two keys.
    public var confirm: Data?
    public var unlock: Data?
    public let linked: Double

    /// Its relay tunnel, tried when none of `addresses` answers: the link names its install and this computer's device there.
    var route: PeerTunnel.Route? { PeerTunnel.Route(relay: relay, deviceID: deviceID, secret: deviceSecret) }

    /// Where to dial it directly, best first: the tailnet address, its name, then the LAN ones.
    var addresses: [(host: String, port: Int)] {
        var seen = Set<String>(), out: [(host: String, port: Int)] = []
        for text in [endpoints.tailnet, endpoints.name, endpoints.lan].compactMap({ $0 }) + (endpoints.lans ?? []) {
            guard seen.insert(text.lowercased()).inserted, let address = Self.address(text) else { continue }
            out.append(address)
        }
        return out
    }

    /// `100.101.12.4:47800` or `[fd7a::1]:47800`.
    static func address(_ text: String) -> (host: String, port: Int)? {
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65_535).contains(port), !host.isEmpty else { return nil }
            return (host, port)
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let port = Int(parts[1]), (1...65_535).contains(port) else { return nil }
        return (String(parts[0]), port)
    }

    var wire: RemoteComputer { RemoteComputer(id: id, name: name, os: os) }
}

/// The linked computers, one 0600 file (`computers.json`). As with the paired devices, a file that exists but can't be
/// read leaves the list empty and is never replaced.
public actor ComputerLinks {
    private let record: JSONRecord<[LinkedComputer]>
    public private(set) var all: [LinkedComputer] = []
    private var unreadable = false

    public init(store: any SecretStore) {
        record = JSONRecord(store: store, name: "computers.json")
        do { all = try record.load(default: []) } catch { unreadable = true }
    }

    public var any: Bool { !all.isEmpty }

    func computer(_ id: String) -> LinkedComputer? { all.first { $0.id == id } }

    /// By host id, its start, or its name.
    func find(_ text: String) -> LinkedComputer? {
        let wanted = text.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        return all.first { $0.id == wanted } ?? all.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
            ?? all.first { $0.id.hasPrefix(wanted.lowercased()) }
    }

    /// One link per computer. Returns the devices an older link let in, which the caller revokes.
    func keep(_ computer: LinkedComputer) throws -> [String] {
        guard !unreadable else { throw SecretStoreError.permissions("computers.json") }
        let old = all.filter { $0.id == computer.id }.compactMap(\.device).filter { $0 != computer.device }
        let next = all.filter { $0.id != computer.id } + [computer]
        try record.save(next)
        all = next
        return old
    }

    func update(_ id: String, _ change: (inout LinkedComputer) -> Void) throws {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        var next = all
        change(&next[index])
        try record.save(next)
        all = next
    }

    @discardableResult
    func remove(_ id: String) throws -> LinkedComputer? {
        guard let gone = all.first(where: { $0.id == id }) else { return nil }
        let next = all.filter { $0.id != id }
        try record.save(next)
        all = next
        return gone
    }

    /// The other computer unlinked: forget it, when `device` is the way it comes in here.
    func dropped(_ id: String, by device: String) throws -> Bool {
        guard all.contains(where: { $0.id == id && $0.device == device }) else { return false }
        try remove(id)
        return true
    }
}
