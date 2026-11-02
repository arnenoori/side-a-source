import Foundation
import Observation
import SideACore
import SideAProtocol

/// A paired iPhone. Only the token's hash is kept, never the token.
struct RemoteDevice: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var model: String
    var system: String
    var app: String
    var build: Int
    let hash: Data
    /// base64url SHA-256 of the phone's relay secret, registered with the relay; the secret stays on the phone.
    let secretHash: String
    /// The push key and its id, from pairing or the last rekey (relay-and-release, Key exchange).
    var pushKey: Data?
    var pushKeyID: Data?
    /// The phone's Secure Enclave keys (X9.63): one behind Face ID, one usable only while unlocked. Nil for a pairing
    /// made before they existed, which may then do only what a locked phone may.
    var confirmKey: String?
    var unlockKey: String?
    /// What the phone last reported in `POST /v1/devices/push`.
    var push: PushRegistration?
    /// The phone's latest `hello` listed `rotation`. Kept here because pushes go out while its socket is closed.
    var rotationPushes: Bool?
    /// The relay's last word on this device: ok, gone, retry, rejected, unverified.
    var pushResult: String?
    let created: Double
    var lastSeen: Double?
}

/// The paired devices, kept in one Keychain item. If that item exists but can't be read, nothing is accepted and the
/// item is never replaced silently.
@MainActor @Observable
final class DeviceStore {
    private(set) var devices: [RemoteDevice] = []
    /// Set when the Keychain item couldn't be read: Remote then accepts no device.
    private(set) var unreadable: String?
    @ObservationIgnored private let keychain: RemoteKeychain
    @ObservationIgnored private var lastWrite = Date.distantPast
    @ObservationIgnored private var seenDirty = false

    init(keychain: RemoteKeychain) {
        self.keychain = keychain
        load()
    }

    func load() {
        do {
            devices = try keychain.readDevices().map { try JSONDecoder().decode([RemoteDevice].self, from: $0) } ?? []
            unreadable = nil
        } catch {
            devices = []
            unreadable = "Paired devices couldn't be read. Pair again."
        }
    }

    /// For the server: nil while the list can't be read, so no token matches.
    var confirmKeys: [String: ConfirmGate.Keys] {
        Dictionary(devices.map { ($0.id, ConfirmGate.Keys(confirm: $0.confirmKey, unlock: $0.unlockKey)) }, uniquingKeysWith: { a, _ in a })
    }

    var hashes: [(id: String, hash: Data)]? { unreadable == nil ? devices.map { ($0.id, $0.hash) } : nil }

    func add(_ device: RemoteDevice, replacing old: String?) throws {
        var next = devices.filter { $0.id != device.id && $0.id != old }
        next.append(device)
        try save(next)
    }

    func remove(_ id: String) throws { try save(devices.filter { $0.id != id }) }

    /// Changes one device's record; false when it isn't paired.
    @discardableResult
    func update(_ id: String, _ change: (inout RemoteDevice) -> Void) throws -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return false }
        var next = devices
        change(&next[index])
        try save(next)
        return true
    }

    /// Starting over after "Paired devices couldn't be read": the user chose to pair again.
    func reset() throws {
        keychain.deleteDevices()
        unreadable = nil
        try save([])
    }

    /// Kept in memory; written at most every ten minutes, and by `flush` on quit. The first time is written at once: it is
    /// what keeps a new pairing from being swept as an orphan after a relaunch.
    func seen(_ id: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        let first = devices[index].lastSeen == nil
        devices[index].lastSeen = Date().timeIntervalSince1970
        seenDirty = true
        if first || -lastWrite.timeIntervalSinceNow > 600 { flush() }
    }

    /// How long a new pairing has to make its first authenticated request.
    static let claimTime: TimeInterval = 600

    /// Paired, but the phone never used its token: its save failed, or it was killed before saving.
    func orphans(now: Date = Date()) -> [RemoteDevice] {
        devices.filter { $0.lastSeen == nil && now.timeIntervalSince1970 - $0.created > Self.claimTime }
    }

    func flush() {
        guard seenDirty, unreadable == nil else { return }
        try? save(devices)
    }

    private func save(_ next: [RemoteDevice]) throws {
        guard unreadable == nil else { throw RemoteKeychain.Failure(status: errSecInteractionNotAllowed, what: unreadable!) }
        try keychain.writeDevices(try JSONEncoder().encode(next))
        devices = next
        lastWrite = Date()
        seenDirty = false
    }
}
