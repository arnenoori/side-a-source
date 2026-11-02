import Foundation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

/// Macs forgotten on this iPhone that haven't yet heard it's gone. A Mac that's asleep or out of reach
/// when the user taps Forget still lists the phone, so the token and secret stay here, copied, and
/// `DELETE /v1/devices/self` goes again at each launch and return to the foreground until the Mac
/// takes it. Out of reach, the relay's `DELETE /device` stops the pushes meanwhile.
enum Revocations {
    struct Pending: Codable, Equatable {
        let mac: PairedMac
        let token: String
        let secret: Data?
        let since: Date
        var relayDone = false
    }

    /// A month of trying is enough: the Mac was most likely set up again or thrown away.
    static let giveUpAfter: TimeInterval = 30 * 86_400

    static func pending(_ keychain: SharedKeychain = .shared) -> [Pending] {
        keychain.data("revoke").flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
    }

    private static func store(_ list: [Pending], _ keychain: SharedKeychain) {
        keychain.set(list.isEmpty ? nil : try? JSONEncoder().encode(list), for: "revoke")
    }

    /// From Forget: the credentials it needs are copied now, so pairing the same Mac again can't be revoked by it.
    static func add(_ mac: PairedMac, keychain: SharedKeychain = .shared) {
        let id = mac.endpoint.macID
        guard let token = keychain.data("token.\(id)").flatMap({ String(data: $0, encoding: .utf8) }) else {
            drop(mac, keychain: keychain)
            return
        }
        var list = pending(keychain).filter { $0.mac.endpoint.macID != id }
        list.append(Pending(mac: mac, token: token, secret: keychain.data("secret.\(id)"), since: .now))
        store(list, keychain)
    }

    /// Paired again before the old pairing was revoked: the Mac replaces that one itself.
    static func cancel(_ macID: String, keychain: SharedKeychain = .shared) {
        store(pending(keychain).filter { $0.mac.endpoint.macID != macID }, keychain)
    }

    /// Tries each one once; what doesn't get through waits for the next call.
    static func run(keychain: SharedKeychain = .shared) async {
        for entry in pending(keychain) {
            switch await revoke(entry) {
            case .done:
                settle(entry, keychain: keychain)
            case .later(let relayDone):
                if Date.now.timeIntervalSince(entry.since) > giveUpAfter {
                    settle(entry, keychain: keychain)
                } else if relayDone && !entry.relayDone {
                    var list = pending(keychain)
                    if let index = list.firstIndex(of: entry) { list[index].relayDone = true }
                    store(list, keychain)
                }
            }
        }
    }

    private enum Outcome { case done, later(relayDone: Bool) }

    private static func revoke(_ entry: Pending) async -> Outcome {
        let client = RemoteClient(endpoint: entry.mac.endpoint, credentials: Copied(entry: entry))
        do {
            try await client.forget()
            RemoteLog.log(.pairing, "revoked on \(entry.mac.endpoint.name)")
            return .done
        } catch let failure as RemoteFailure where [401, 404].contains(failure.status) {
            // The Mac already doesn't list this phone.
            return .done
        } catch is RelayRefused {
            return .done
        } catch {
            RemoteLog.log(.pairing, "revoke waits: \(KitLog.describe(error))")
            return .later(relayDone: entry.relayDone ? true : await relayForget(entry))
        }
    }

    /// The relay forgets the device, so no more pushes come while the Mac is out of reach.
    private static func relayForget(_ entry: Pending) async -> Bool {
        guard let install = entry.mac.relayInstallID, let relay = entry.mac.relayURL, let secret = entry.secret,
              let url = URL(string: "\(relay)/v1/device") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let encoded = secret.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        request.setValue("Bearer d1.\(install).\(entry.mac.deviceID).\(encoded)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        RemoteLog.log(.pairing, "relay forget → \(status)")
        return (200..<300).contains(status) || status == 401 || status == 404
    }

    /// Gone from the Mac: its credentials go too, unless the same Mac was paired again meanwhile.
    private static func settle(_ entry: Pending, keychain: SharedKeychain) {
        store(pending(keychain).filter { $0 != entry }, keychain)
        if PairedMac.load(entry.mac.endpoint.macID, keychain: keychain) == nil { drop(entry.mac, keychain: keychain) }
    }

    private static func drop(_ mac: PairedMac, keychain: SharedKeychain) {
        mac.dropCredentials(keychain: keychain)
        Paths.forget(macID: mac.endpoint.macID)
    }

    /// The forgotten pairing's own token and secret, never what's in the keychain now.
    private struct Copied: CredentialStore {
        let entry: Pending
        func token(for macID: String) async throws -> String? { entry.token }
        func setToken(_ token: String?, for macID: String) async throws {}
        func relaySecret(for macID: String) async throws -> Data? { entry.secret }
    }
}
