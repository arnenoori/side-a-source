import CryptoKit
import Foundation
import SideAProtocol

/// How the Mac proves itself to the push relay (relay-and-release, Signed requests): an Ed25519 signature over the
/// method, path, time, a nonce and the body's hash, in one header.
public enum RelaySignature {
    /// base64url of the first 16 bytes of SHA-256 of the raw public key.
    public static func installID(_ publicKey: Data) -> String { Data(SHA256.hash(data: publicKey).prefix(16)).base64URL }

    /// `pathname` is the URL's path, no query.
    public static func signedString(method: String, path: String, ts: Int, nonce: String, body: Data) -> Data {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Data("SideA-Sig-v1\n\(method)\n\(path)\n\(ts)\n\(nonce)\n\(hash)".utf8)
    }

    public static func authorization(_ key: Curve25519.Signing.PrivateKey, method: String, path: String, body: Data, ts: Int,
                                     nonce: String = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64URL) throws -> String {
        let install = installID(key.publicKey.rawRepresentation)
        let signature = try key.signature(for: signedString(method: method, path: path, ts: ts, nonce: nonce, body: body))
        return "SideA-Sig v=1, install=\(install), ts=\(ts), nonce=\(nonce), sig=\(signature.base64URL)"
    }
}
