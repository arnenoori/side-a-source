import Crypto
import Foundation
import NIOSSL
import SideAProtocol
import SwiftASN1
import X509

/// The daemon's TLS identity: a P-256 key and a self-signed certificate made in this process. The phone pins the key,
/// not the certificate (docs/remote/mac-server.md), so the certificate carries nothing beyond what TLS needs and the
/// Mac's `/usr/bin/openssl` plus Keychain import are not needed.
public struct DaemonIdentity: Sendable {
    public let certificate: [UInt8]
    public let privateKey: [UInt8]
    /// base64url of the SPKI SHA-256: the QR code's `fp`, and what a client pins.
    public let spkiHash: String
    /// `Hello.keyID`: the first 8 bytes of that hash, in hex.
    public let keyID: String

    public init(certificate: [UInt8], privateKey: [UInt8], spkiHash: String) {
        self.certificate = certificate; self.privateKey = privateKey; self.spkiHash = spkiHash
        keyID = SPKI.keyID(spkiHash) ?? ""
    }

    /// A new key and a ten-year certificate for it. Keeping the key (a 0600 file, or the Secret Service) is the caller's.
    public static func generate(name: String = "Side A", now: Date = Date()) throws -> DaemonIdentity {
        let key = P256.Signing.PrivateKey()
        let subject = try DistinguishedName { CommonName(name) }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(10 * 365 * 24 * 3600),
            issuer: subject, subject: subject, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: .init(key))
        var serializer = DER.Serializer()
        try certificate.serialize(into: &serializer)
        return DaemonIdentity(certificate: serializer.serializedBytes, privateKey: Array(key.derRepresentation), spkiHash: SPKI.hash(key.publicKey))
    }

    /// TLS 1.3 only, HTTP/1.1: the same floor the Mac's listener sets.
    func serverConfiguration() throws -> TLSConfiguration {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: certificate, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: privateKey, format: .der)))
        configuration.minimumTLSVersion = .tlsv13
        configuration.applicationProtocols = ["http/1.1"]
        return configuration
    }
}
