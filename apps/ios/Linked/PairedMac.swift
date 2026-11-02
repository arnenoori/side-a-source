import Foundation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

/// The paired Mac as the phone keeps it. It lives in the shared keychain beside the token, so the
/// notification extensions can answer without the app.
struct PairedMac: Codable, Hashable {
    var endpoint: Endpoint
    var deviceID: String
    /// What the Mac calls this iPhone, for "Paired as Arne's iPhone".
    var deviceName: String
    var relayInstallID: String?
    /// The push relay the Mac registered this iPhone with, only ever from the Mac; nil means no relay, so no pushes.
    var relayURL: String?
    /// The Mac's tailnet from its code (`t=`), for the different-tailnet warning when pairing another Mac.
    var tailnet: String?

    /// Keychain accounts: `macs`, every paired Mac in the order they were paired, then `token.`, `secret.`
    /// and `pushKey.` with each Mac's id. A phone paired before multi-Mac kept its one Mac under `mac`.
    static func all(_ keychain: SharedKeychain = .shared) -> [PairedMac] {
        if let data = keychain.data("macs") {
            return ((try? JSONDecoder().decode([PairedMac].self, from: data)) ?? []).map(\.withRelay)
        }
        guard let old = keychain.data("mac"), let mac = try? JSONDecoder().decode(PairedMac.self, from: old) else { return [] }
        if store([mac], keychain) { keychain.set(nil, for: "mac") }
        return [mac.withRelay]
    }

    static func load(_ macID: String, keychain: SharedKeychain = .shared) -> PairedMac? {
        all(keychain).first { $0.endpoint.macID == macID }
    }

    /// The pairing a code is for: the same Mac paired before, which Pair Again replaces on the Mac.
    static func matching(_ invitation: PairingClient.Invitation, keychain: SharedKeychain = .shared) -> PairedMac? {
        invitation.macID.flatMap { load($0, keychain: keychain) }
    }

    /// Why a code may not be from the Mac it says it is: it names a paired Mac with a key other than the pinned one, or
    /// another Mac under a paired Mac's name. Either can be a Mac reset on purpose, so the user decides.
    static func identityWarning(_ invitation: PairingClient.Invitation, keychain: SharedKeychain = .shared) -> String? {
        let macs = all(keychain)
        if let same = macs.first(where: { $0.endpoint.macID == invitation.macID }) {
            guard same.endpoint.serverKeyHash != invitation.fp else { return nil }
            return "This code's security key isn't the one \(RequestText.visible(same.endpoint.name)) paired with. Pair only if you reset Side A on that Mac."
        }
        func folded(_ name: String) -> String {
            name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = invitation.macName, let twin = macs.first(where: { folded($0.endpoint.name) == folded(name) }) else { return nil }
        return "\(RequestText.visible(twin.endpoint.name)) is already paired, and this code is from a different Mac with the same name. Pair only if you meant to add another Mac."
    }

    /// The paired Mac on another tailnet than the code's, when neither has the relay to reach across.
    static func otherTailnet(_ invitation: PairingClient.Invitation, keychain: SharedKeychain = .shared) -> PairedMac? {
        guard let tailnet = invitation.tailnet, invitation.relay == nil else { return nil }
        return all(keychain).first { mac in
            mac.endpoint.macID != invitation.macID && mac.endpoint.relay == nil && mac.tailnet.map { $0 != tailnet } == true
        }
    }

    @discardableResult
    private static func store(_ macs: [PairedMac], _ keychain: SharedKeychain) -> Bool {
        guard let data = try? JSONEncoder().encode(macs) else { return false }
        return keychain.set(data, for: "macs")
    }

    /// Adds the Mac, or replaces its entry when it was paired before.
    @discardableResult
    private static func upsert(_ mac: PairedMac, _ keychain: SharedKeychain) -> Bool {
        var macs = all(keychain)
        if let index = macs.firstIndex(where: { $0.endpoint.macID == mac.endpoint.macID }) { macs[index] = mac } else { macs.append(mac) }
        return store(macs, keychain)
    }

    /// The endpoint names the relay tunnel, so every client of it can fall back to the relay. Records saved before
    /// the tunnel existed get it from the relay fields they already had.
    var withRelay: PairedMac {
        guard endpoint.relay == nil, let relayURL, let url = URL(string: relayURL), let relayInstallID else { return self }
        var mac = self
        let old = endpoint
        mac.endpoint = Endpoint(macID: old.macID, baseURL: old.baseURL, alternates: old.alternates, serverKeyHash: old.serverKeyHash, name: old.name,
                                relay: RelayRoute(url: url, installID: relayInstallID, deviceID: deviceID))
        return mac
    }

    struct NotSaved: Error {}

    /// Every credential, then the record that says they're there; throws when the keychain refused any.
    static func save(_ paired: PairingClient.Paired, deviceName: String, tailnet: String? = nil,
                     keychain: SharedKeychain = .shared) throws -> PairedMac {
        let mac = PairedMac(endpoint: paired.endpoint, deviceID: paired.response.deviceID, deviceName: deviceName,
                            relayInstallID: paired.response.relay?.installID, relayURL: paired.response.relay?.url, tailnet: tailnet).withRelay
        let id = mac.endpoint.macID
        // The 4-byte key id, then the key.
        let pushKey = paired.pushKey.map { $0.keyID + $0.key.withUnsafeBytes { Data($0) } }
        guard keychain.set(Data(paired.response.token.utf8), for: "token.\(id)"),
              keychain.set(paired.deviceSecret, for: "secret.\(id)"),
              keychain.set(pushKey, for: "pushKey.\(id)"),
              upsert(mac, keychain) else { throw NotSaved() }
        Revocations.cancel(id, keychain: keychain)
        return mac
    }

    /// The Mac changed its addresses: keep the new alternates for next launch.
    func updating(_ endpoints: Endpoints, keychain: SharedKeychain = .shared) -> PairedMac {
        var mac = self
        mac.endpoint = endpoint.updated(with: endpoints)
        if mac != self, PairedMac.load(endpoint.macID, keychain: keychain) != nil { PairedMac.upsert(mac, keychain) }
        return mac
    }

    /// The token, secret, push key and device keys, but not the Mac's entry, which may already be a new pairing's.
    func dropCredentials(keychain: SharedKeychain = .shared) {
        for account in ["token.", "secret.", "pushKey."] { keychain.set(nil, for: account + endpoint.macID) }
        DeviceKeys.delete(for: endpoint.macID)
    }

    /// Removes this Mac only. Its credentials stay until the Mac has heard the phone is gone (`Revocations`).
    func forget(keychain: SharedKeychain = .shared) {
        PairedMac.store(PairedMac.all(keychain).filter { $0.endpoint.macID != endpoint.macID }, keychain)
        keychain.set(nil, for: "pushKey.\(endpoint.macID)")
        Revocations.add(self, keychain: keychain)
    }
}

/// The token for `RemoteClient`, from the shared keychain.
struct KeychainCredentials: CredentialStore {
    func token(for macID: String) async throws -> String? {
        SharedKeychain.shared.data("token.\(macID)").flatMap { String(data: $0, encoding: .utf8) }
    }

    func setToken(_ token: String?, for macID: String) async throws {
        SharedKeychain.shared.set(token.map { Data($0.utf8) }, for: "token.\(macID)")
    }

    func relaySecret(for macID: String) async throws -> Data? {
        SharedKeychain.shared.data("secret.\(macID)")
    }
}
