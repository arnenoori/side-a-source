import Foundation
import SideACore
import SideAProtocol

/// A paired iPhone. Only the token's hash is kept, never the token.
public struct PairedDevice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var model: String
    public var system: String
    public var app: String
    public var build: Int
    public let hash: Data
    /// base64url SHA-256 of the phone's relay secret, registered with the relay; the secret stays on the phone.
    public let secretHash: String
    public var pushKey: Data?
    public var pushKeyID: Data?
    public var confirmKey: String?
    public var unlockKey: String?
    public var push: PushRegistration?
    public var capabilities: Set<Capability>?
    public let created: Double
    public var lastSeen: Double?
}

/// The paired devices, kept in one 0600 file. A file that exists but can't be read leaves the list unavailable: nothing
/// is accepted and the file is never replaced, as with the Mac's Keychain item.
public actor DeviceRegistry {
    public private(set) var devices: [PairedDevice] = []
    public private(set) var unreadable: String?
    private let record: JSONRecord<[PairedDevice]>
    private var lastWrite = Date.distantPast
    private var dirty = false

    public init(store: any SecretStore) {
        record = JSONRecord(store: store, name: "devices.json")
        do { devices = try record.load(default: []) } catch { unreadable = "Paired devices couldn't be read (\(error)). Pair again." }
    }

    /// Nil while the list can't be read, so no token is accepted.
    public var hashes: [(id: String, hash: Data)]? { unreadable == nil ? devices.map { ($0.id, $0.hash) } : nil }

    public var confirmKeys: [String: ConfirmGate.Keys] {
        Dictionary(devices.map { ($0.id, ConfirmGate.Keys(confirm: $0.confirmKey, unlock: $0.unlockKey)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The device a bearer token belongs to. Every hash is compared in full, so the time says nothing about which.
    public func device(token: String) -> PairedDevice? {
        guard token.hasPrefix(DeviceToken.prefix), token.count < 100, let hashes else { return nil }
        return DeviceToken.match(token, in: hashes.map(\.hash)).map { devices[$0] }
    }

    public func device(id: String) -> PairedDevice? { devices.first { $0.id == id } }

    public func add(_ device: PairedDevice, replacing old: String?) throws {
        var next = devices.filter { $0.id != device.id && $0.id != old }
        next.append(device)
        try save(next)
    }

    public func remove(_ id: String) throws { try save(devices.filter { $0.id != id }) }

    @discardableResult
    public func update(_ id: String, _ change: (inout PairedDevice) -> Void) throws -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return false }
        var next = devices
        change(&next[index])
        try save(next)
        return true
    }

    /// Kept in memory, written at most every ten minutes (the first time at once: a new pairing is then not an orphan
    /// after a restart).
    public func seen(_ id: String, now: Date = Date()) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        let first = devices[index].lastSeen == nil
        devices[index].lastSeen = now.timeIntervalSince1970
        dirty = true
        if first || now.timeIntervalSince(lastWrite) > 600 { flush(now: now) }
    }

    public func flush(now: Date = Date()) {
        guard dirty, unreadable == nil else { return }
        do { try save(devices, now: now) } catch { dirty = true }
    }

    private func save(_ next: [PairedDevice], now: Date = Date()) throws {
        guard unreadable == nil else { throw SecretStoreError.permissions("devices.json") }
        try record.save(next)
        devices = next
        lastWrite = now
        dirty = false
    }
}
