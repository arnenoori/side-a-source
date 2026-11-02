import SideAProtocol
import XCTest
@testable import SideARemote

/// The unlock key's signature checks out the way the Mac checks it (`ConfirmSignature.verify`). The Face ID key
/// needs a person, so only its creation is covered here.
final class DeviceKeysTests: XCTestCase {
    private let mac = "test-mac-\(UUID().uuidString.prefix(8))"

    override func tearDown() { DeviceKeys.delete(for: mac) }

    func testAnUnlockSignatureVerifies() async throws {
        guard let keys = DeviceKeys.create(for: mac) else { throw XCTSkip("no keys on this simulator") }
        DeviceKeys.promote(for: mac)
        XCTAssertTrue(DeviceKeys.has(.unlock, for: mac))
        let subject = try XCTUnwrap(ConfirmMessage.subject(requestID: "r1", answer: .allow(confirmDestructive: false)))
        let signed = await DeviceKeys.header(.unlock, macID: mac, deviceID: "d1", purpose: .allow, subject: subject)
        let header = try XCTUnwrap(signed)
        let signature = try XCTUnwrap(ConfirmSignature(header: header))
        XCTAssertEqual(signature.signer, .unlock)
        XCTAssertTrue(signature.verify(publicKey: keys.unlock, macID: mac, deviceID: "d1", purpose: .allow, subject: subject,
                                       now: Date.now.timeIntervalSince1970))
        // The same signature doesn't stand for another request or another key.
        XCTAssertFalse(signature.verify(publicKey: keys.unlock, macID: mac, deviceID: "d1", purpose: .allow, subject: "r2:allow",
                                        now: Date.now.timeIntervalSince1970))
        XCTAssertFalse(signature.verify(publicKey: keys.confirm, macID: mac, deviceID: "d1", purpose: .allow, subject: subject,
                                        now: Date.now.timeIntervalSince1970))
    }

    /// Pair Again makes keys before the Mac has taken them: until the new pairing is saved, the old one's still sign.
    func testNewKeysSignOnlyOnceTheirPairingIsKept() async throws {
        guard let old = DeviceKeys.create(for: mac) else { throw XCTSkip("no keys on this simulator") }
        XCTAssertFalse(DeviceKeys.has(.unlock, for: mac))
        DeviceKeys.promote(for: mac)
        let new = try XCTUnwrap(DeviceKeys.create(for: mac))
        let subject = try XCTUnwrap(ConfirmMessage.subject(requestID: "r1", answer: .allow(confirmDestructive: false)))
        func signedBy(_ key: String) async throws -> Bool {
            let signed = await DeviceKeys.header(.unlock, macID: mac, deviceID: "d1", purpose: .allow, subject: subject)
            let header = try XCTUnwrap(signed)
            return try XCTUnwrap(ConfirmSignature(header: header)).verify(publicKey: key, macID: mac, deviceID: "d1", purpose: .allow,
                                                                         subject: subject, now: Date.now.timeIntervalSince1970)
        }
        let before = try await signedBy(old.unlock)
        XCTAssertTrue(before)
        DeviceKeys.promote(for: mac)
        let after = try await signedBy(new.unlock)
        XCTAssertTrue(after)
    }

    func testForgettingTheMacDeletesItsKeys() throws {
        guard DeviceKeys.create(for: mac) != nil else { throw XCTSkip("no keys on this simulator") }
        DeviceKeys.promote(for: mac)
        _ = DeviceKeys.create(for: mac)
        DeviceKeys.delete(for: mac)
        // Keys a Pair Again left waiting go too.
        DeviceKeys.promote(for: mac)
        XCTAssertFalse(DeviceKeys.has(.unlock, for: mac))
        XCTAssertFalse(DeviceKeys.has(.confirm, for: mac))
    }
}
