import Crypto
import Foundation
import SideAProtocol

extension DaemonIdentity {
    private struct Saved: Codable {
        let certificate: Data
        let privateKey: Data
    }

    /// The identity kept in `store`, or a new one saved there. The pin a phone holds is this key's, so it must survive
    /// restarts: a new key would make every paired phone refuse the daemon.
    public static func loadOrCreate(in store: any SecretStore, name: String = "Side A") throws -> DaemonIdentity {
        let record = JSONRecord<Saved?>(store: store, name: "tls.json")
        if let saved = try record.load(default: nil),
           let key = try? P256.Signing.PrivateKey(derRepresentation: saved.privateKey) {
            return DaemonIdentity(certificate: Array(saved.certificate), privateKey: Array(saved.privateKey), spkiHash: SPKI.hash(key.publicKey))
        }
        let fresh = try generate(name: name)
        try record.save(Saved(certificate: Data(fresh.certificate), privateKey: Data(fresh.privateKey)))
        return fresh
    }
}
