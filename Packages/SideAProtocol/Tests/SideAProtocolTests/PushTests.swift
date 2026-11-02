import CryptoKit
import Foundation
import SideAProtocol
import SideAProtocolFixtures
import Testing

/// A known-answer vector for the push key and one envelope, computed outside Swift.
struct PushVector: Codable {
    let macPrivateKey, devicePrivateKey, macPublicKey, devicePublicKey, deviceID: String
    /// The relay install's Ed25519 key, and its id: base64url(SHA-256(public key)[0..<16]).
    let installPrivateKey, installPublicKey, installID: String
    let key, keyID, category, collapseID, nonce, payload, envelope, macID: String
}

private func vector(_ name: String = "PushVector.request") throws -> PushVector {
    try JSONDecoder().decode(PushVector.self, from: Fixtures.data(name))
}

private func bytes(_ text: String) throws -> Data { try #require(Data(base64URL: text)) }

@Test func bothSidesDeriveTheKnownPushKey() throws {
    let v = try vector()
    let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(v.macPrivateKey))
    let device = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(v.devicePrivateKey))
    #expect(mac.publicKey.rawRepresentation.base64URL == v.macPublicKey && device.publicKey.rawRepresentation.base64URL == v.devicePublicKey)
    let onMac = try PushKey.derive(mac, peer: device.publicKey, macPublicKey: bytes(v.macPublicKey), devicePublicKey: bytes(v.devicePublicKey),
                                   installID: v.installID, deviceID: v.deviceID)
    let onPhone = try PushKey.derive(device, peer: mac.publicKey, macPublicKey: bytes(v.macPublicKey), devicePublicKey: bytes(v.devicePublicKey),
                                     installID: v.installID, deviceID: v.deviceID)
    #expect(onMac == onPhone && onMac.data.base64URL == v.key && onMac.keyID.base64URL == v.keyID)
}

@Test func theKnownEnvelopeOpensAndSealsTheSame() throws {
    let v = try vector("PushVector.request-v2")
    let key = PushKey(key: SymmetricKey(data: try bytes(v.key)), keyID: try bytes(v.keyID))
    let category = PushCategory(rawValue: v.category)
    let plaintext = try Fixtures.data(v.payload)
    #expect(try PushEnvelope.open(v.envelope, with: key, category: category, collapseID: v.collapseID, deviceID: v.deviceID) == plaintext)
    #expect(try Fixtures.binary("Envelope.request-v2").base64URL == v.envelope)
    let nonce = try ChaChaPoly.Nonce(data: bytes(v.nonce))
    #expect(try PushEnvelope.seal(plaintext, with: key, category: category, collapseID: v.collapseID, deviceID: v.deviceID, nonce: nonce) == v.envelope)

    // The relay can't move it to another category, request or device.
    #expect(throws: (any Error).self) { try PushEnvelope.open(v.envelope, with: key, category: .finished, collapseID: v.collapseID, deviceID: v.deviceID) }
    #expect(throws: (any Error).self) { try PushEnvelope.open(v.envelope, with: key, category: category, collapseID: "other", deviceID: v.deviceID) }
    #expect(throws: (any Error).self) { try PushEnvelope.open(v.envelope, with: key, category: category, collapseID: v.collapseID, deviceID: "other") }
    let other = PushKey(key: SymmetricKey(size: .bits256), keyID: Data([9, 9, 9, 9]))
    #expect(throws: PushEnvelope.Failure.key) { try PushEnvelope.open(v.envelope, with: other, category: category, collapseID: v.collapseID, deviceID: v.deviceID) }
}

@Test func aVersion1EnvelopeNoLongerOpens() throws {
    let v = try vector()
    let key = PushKey(key: SymmetricKey(data: try bytes(v.key)), keyID: try bytes(v.keyID))
    #expect(throws: PushEnvelope.Failure.version) {
        try PushEnvelope.open(v.envelope, with: key, category: PushCategory(rawValue: v.category), collapseID: v.collapseID, deviceID: v.deviceID)
    }
}

@Test func bytesCantMoveBetweenFields() throws {
    let key = PushKey(key: SymmetricKey(size: .bits256), keyID: Data([1, 2, 3, 4]))
    // Joined bare, these two AADs were the same bytes.
    let sealed = try PushEnvelope.seal(Data("x".utf8), with: key, category: PushCategory(rawValue: "REQUEST"), collapseID: "ab", deviceID: "dev")
    #expect(throws: (any Error).self) {
        try PushEnvelope.open(sealed, with: key, category: PushCategory(rawValue: "REQUES"), collapseID: "Tab", deviceID: "dev")
    }
    #expect(throws: (any Error).self) {
        try PushEnvelope.open(sealed, with: key, category: PushCategory(rawValue: "REQUEST"), collapseID: "abd", deviceID: "ev")
    }
}

private func push(_ t: String, gate: AllowGate? = nil, full: Bool? = nil) -> PushPayload {
    PushPayload(t: t, mac: "m1", sent: 0, rid: "r1", title: "Allow Bash", body: "npm test", gate: gate, full: full)
}

/// Only a lock-screen request loosens to the safe category; one cut to fit offers Open only.
@Test(arguments: [
    (PushCategory.request, push("request", gate: .lockScreen), PushCategory.requestSafe),
    (.request, push("request", gate: .unlock), .request),
    (.requestDestructive, push("request", gate: .lockScreen), .requestDestructive),
    (.request, push("request", gate: .lockScreen, full: false), .open),
    (.request, push("request", gate: .unlock, full: false), .open),
    (.request, push("request", gate: .biometric, full: false), .open),
    (.requestDestructive, push("request", gate: .lockScreen, full: false), .open),
    (.requestDestructive, push("request", gate: .biometric, full: false), .open),
    (.question, push("question", full: false), .question),
])
func aPushShowsTheActionsItsGateAllows(_ category: PushCategory, _ payload: PushPayload, _ local: PushCategory) {
    #expect(category.local(for: payload) == local)
}

@Test func theActivityCountsTimeFrom2001() {
    #expect(ActivityContentState(working: 0, waiting: 0, soonestResetAt: 978_307_200 + 10).soonestReset == 10)
}
