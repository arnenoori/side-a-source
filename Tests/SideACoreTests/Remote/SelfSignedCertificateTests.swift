import CryptoKit
import Foundation
import Security
@testable import SideACore
import Testing

@Test func theCertificateParsesAndCarriesTheKeyItPins() throws {
    let key = P256.Signing.PrivateKey()
    let point = key.publicKey.x963Representation
    let tbs = SelfSignedCertificate.tbs(publicKey: point, serial: Data([0x80, 1, 2]), name: "Side A",
                                        from: Date(timeIntervalSince1970: 1_791_000_000), until: Date(timeIntervalSince1970: 2_600_000_000))
    let der = SelfSignedCertificate.certificate(tbs: tbs, signature: try key.signature(for: tbs).derRepresentation)
    let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
    #expect(SecCertificateCopySubjectSummary(certificate) as String? == "Side A")
    let copied = try #require(SecCertificateCopyKey(certificate))
    #expect(SecKeyCopyExternalRepresentation(copied, nil) as Data? == point)
    // CryptoKit's own SPKI encoding is the reference for the pin.
    #expect(SelfSignedCertificate.spki(publicKey: point) == key.publicKey.derRepresentation)
    #expect(SelfSignedCertificate.spkiHash(publicKey: point) == Data(SHA256.hash(data: key.publicKey.derRepresentation)))
    #expect(SelfSignedCertificate.integer(Data([0, 0, 5])) == Data([2, 1, 5]))
    #expect(SelfSignedCertificate.time(Date(timeIntervalSince1970: 2_600_000_000)).first == 0x18)
}
