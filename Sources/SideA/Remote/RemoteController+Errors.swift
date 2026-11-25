import CryptoKit
import Foundation

/// What a message in `RemoteController.error` is about, so the same thing working later takes it down. A message set
/// without one (paired devices that couldn't be read, say) stays until it is dismissed or its own fix clears it.
enum RemoteErrorSource { case key, pairing, devices }

extension RemoteController {
    /// For what acts on the key (pairing, the relay, the tunnel): a failed read says so in Remote settings until a later one works.
    func readInstallKey() -> Curve25519.Signing.PrivateKey? {
        do {
            let key = try keychain.installKey()
            resolve(.key)
            return key
        } catch {
            report(error.localizedDescription, from: .key)
            return nil
        }
    }

    func report(_ message: String, from source: RemoteErrorSource) {
        error = message
        errorSource = source
    }

    func resolve(_ source: RemoteErrorSource) {
        guard error != nil, errorSource == source else { return }
        error = nil
    }
}
