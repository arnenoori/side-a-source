import CryptoKit
import Foundation
@testable import SideACore
import SideAProtocol
import Testing

/// The install from SideAProtocol's push vector, which the relay's tests use too.
private let privateKey = "ozneKnknU3Gqnk_1_S6IgkrKoYuvEXARV9x_igvr8lY"
private let installID = "XsFDif2r-oebU07VsxiVgA"

@Test func theInstallIDAndSignatureAreTheRelays() throws {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: try #require(Data(base64URL: privateKey)))
    #expect(RelaySignature.installID(key.publicKey.rawRepresentation) == installID)

    let body = Data(#"{"publicKey":"x"}"#.utf8)
    let signed = RelaySignature.signedString(method: "POST", path: "/v1/installs", ts: 1_792_200_000, nonce: "AAECAwQFBgcICQoLDA0ODw", body: body)
    #expect(String(decoding: signed, as: UTF8.self) == "SideA-Sig-v1\nPOST\n/v1/installs\n1792200000\nAAECAwQFBgcICQoLDA0ODw\n"
        + SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())

    let header = try RelaySignature.authorization(key, method: "POST", path: "/v1/installs", body: body, ts: 1_792_200_000, nonce: "AAECAwQFBgcICQoLDA0ODw")
    let prefix = "SideA-Sig v=1, install=\(installID), ts=1792200000, nonce=AAECAwQFBgcICQoLDA0ODw, sig="
    #expect(header.hasPrefix(prefix))
    let signature = try #require(Data(base64URL: String(header.dropFirst(prefix.count))))
    #expect(signature.count == 64 && key.publicKey.isValidSignature(signature, for: signed))
    // A random nonce is 16 bytes, as the relay's id pattern wants.
    let random = try RelaySignature.authorization(key, method: "GET", path: "/v1/x", body: Data(), ts: 1)
    let nonce = try #require(random.split(separator: ",").first { $0.contains("nonce=") }?.split(separator: "=").last)
    #expect(nonce.count == 22)
}
