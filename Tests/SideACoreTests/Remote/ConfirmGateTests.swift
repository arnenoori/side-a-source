import CryptoKit
import Foundation
@testable import SideACore
import SideAProtocol
import Testing

private struct Phone {
    let confirm = P256.Signing.PrivateKey(), unlock = P256.Signing.PrivateKey()
    var keys: ConfirmGate.Keys { .init(confirm: confirm.publicKey.x963Representation.base64URL, unlock: unlock.publicKey.x963Representation.base64URL) }

    func header(_ signer: ConfirmSignature.Signer, purpose: ConfirmPurpose = .allow, subject: String, device: String = "d1", at: Date = Date()) throws -> String {
        let unix = Int(at.timeIntervalSince1970)
        let text = try ConfirmMessage.text(macID: "mac", deviceID: device, purpose: purpose, subject: subject, at: unix)
        let key = signer == .confirm ? confirm : unlock
        return ConfirmSignature(at: unix, signer: signer, signature: try key.signature(for: Data(text.utf8)).derRepresentation).headerValue
    }
}

@Test func aSignatureProvesItsKeysLevelOnceForWhatItSigned() throws {
    let phone = Phone(), replay = ConfirmGate.ReplayCache()
    func verify(_ header: String?, subject: String = "r1:allow", device: String = "d1", keys: ConfirmGate.Keys? = nil, now: Date = Date()) -> Result<ConfirmProof, ConfirmGate.Failure> {
        ConfirmGate.verify(header, macID: "mac", deviceID: device, purpose: .allow, subject: subject, keys: keys ?? phone.keys, replay: replay, now: now)
    }
    let face = try phone.header(.confirm, subject: "r1:allow")
    #expect(verify(face) == .success(.biometric))
    #expect(verify(face) == .failure(.replayed))
    #expect(verify(try phone.header(.unlock, subject: "r1:allow")) == .success(.unlock))
    // Another request, another device, another Mac's key, or too old: none of them count.
    #expect(verify(try phone.header(.confirm, subject: "r2:allow")) == .failure(.invalid))
    #expect(verify(try phone.header(.confirm, subject: "r1:allow", device: "d2")) == .failure(.invalid))
    #expect(verify(try phone.header(.confirm, subject: "r1:allow"), keys: Phone().keys) == .failure(.invalid))
    #expect(verify(try phone.header(.confirm, subject: "r1:allow", at: Date().addingTimeInterval(-600))) == .failure(.invalid))
    #expect(verify(nil) == .failure(.missing))
    #expect(verify("v1.nope") == .failure(.malformed))
    // A keyless pairing proves nothing; a phone without a Face ID key can't claim one.
    #expect(verify(try phone.header(.confirm, subject: "r1:allow"), keys: .init(confirm: nil, unlock: phone.keys.unlock)) == .failure(.missing))
}

@Test func whatAMacGateAsksForIsWhatAProofMustReach() {
    #expect(ConfirmProof(AllowGate.lockScreen) == .none)
    #expect(ConfirmProof(AllowGate.unlock) == .unlock)
    #expect(ConfirmProof(AllowGate.biometric) == .biometric)
    #expect(ConfirmProof(AllowGate(rawValue: "retina")) == .biometric)
}

/// `(r, s)` and `(r, n - s)` both verify, so a captured header can come back with different bytes and the same meaning.
@Test func theSameSignedMessageWithOtherBytesIsAReplay() throws {
    let phone = Phone(), replay = ConfirmGate.ReplayCache()
    let unix = Int(Date().timeIntervalSince1970)
    let text = try ConfirmMessage.text(macID: "mac", deviceID: "d1", purpose: .allow, subject: "r1:allow", at: unix)
    let signed = try phone.confirm.signature(for: Data(text.utf8))
    let raw = [UInt8](signed.rawRepresentation)
    let order: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                          0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51]
    var flipped = [UInt8](repeating: 0, count: 32), borrow = 0
    for index in (0..<32).reversed() {
        let difference = Int(order[index]) - Int(raw[32 + index]) - borrow
        flipped[index] = UInt8(truncatingIfNeeded: difference)
        borrow = difference < 0 ? 1 : 0
    }
    let other = try P256.Signing.ECDSASignature(rawRepresentation: Data(raw[..<32] + flipped))
    #expect(other.derRepresentation != signed.derRepresentation && phone.confirm.publicKey.isValidSignature(other, for: Data(text.utf8)))
    func verify(_ signature: P256.Signing.ECDSASignature) -> Result<ConfirmProof, ConfirmGate.Failure> {
        let header = ConfirmSignature(at: unix, signer: .confirm, signature: signature.derRepresentation).headerValue
        return ConfirmGate.verify(header, macID: "mac", deviceID: "d1", purpose: .allow, subject: "r1:allow", keys: phone.keys, replay: replay)
    }
    #expect(verify(signed) == .success(.biometric))
    #expect(verify(other) == .failure(.replayed))
}
