import Foundation
@testable import SideACore
import Testing

@Test func codesUseCrockfordAndReadMisreadLetters() {
    let code = PairingCode.make(now: 0)
    #expect(code.code.count == 8 && code.code.allSatisfy { PairingCode.alphabet.contains($0) })
    #expect(!PairingCode.alphabet.contains { "ILOU".contains($0) })
    #expect(PairingCode(code: "K7Q29XMD", now: 0).display == "K7Q2-9XMD")
    #expect(PairingCode.normalize("k7q2-9xmd") == "K7Q29XMD" && PairingCode.normalize("0O1Il ") == "00111")
    let all = PairingCode.make(now: 0) { Array(0..<UInt8($0)).map { $0 + 31 } }
    #expect(all.code.first == "Z" && all.code.dropFirst().first == "0")
}

@Test func aCodeLastsFiveMinutesAndFiveTries() {
    var code = PairingCode(code: "K7Q29XMD", now: 0)
    #expect(code.submit("K7Q2-9XMA", now: 1) == .wrong(triesLeft: 4))
    for left in [3, 2, 1] { #expect(code.submit("AAAAAAAA", now: 1) == .wrong(triesLeft: left)) }
    // The fifth wrong try burns it; the right code is no use after.
    #expect(code.submit("AAAAAAAA", now: 1) == .expired)
    #expect(code.submit("K7Q29XMD", now: 1) == .expired)
    var late = PairingCode(code: "K7Q29XMD", now: 0)
    #expect(late.submit("K7Q29XMD", now: 300) == .expired)
}

@Test func aRightCodeOpensOneAttemptAndARaceVoidsIt() {
    var code = PairingCode(code: "K7Q29XMD", now: 0)
    #expect(code.submit("k7q29xmd", now: 1) { "a1" } == .accepted(attempt: "a1"))
    #expect(code.state == .pending(attempt: "a1"))
    #expect(code.submit("K7Q29XMD", now: 2) { "a2" } == .busy)
    #expect(code.state == .void && code.submit("K7Q29XMD", now: 3) == .expired)
    var used = PairingCode(code: "K7Q29XMD", now: 0)
    _ = used.submit("K7Q29XMD", now: 1)
    used.finish()
    #expect(used.submit("K7Q29XMD", now: 2) == .expired)
}

@Test func tokensAreHashedAndMatchedInFull() {
    let token = DeviceToken.make()
    #expect(token.hasPrefix("sa1_") && token.count == 47 && !token.contains("="))
    let hashes = [DeviceToken.hash("sa1_other"), DeviceToken.hash(token), DeviceToken.hash(token)]
    #expect(DeviceToken.match(token, in: hashes) == 1)
    #expect(DeviceToken.match(String(token.dropLast()) + (token.last == "A" ? "B" : "A"), in: hashes) == nil)
    #expect(DeviceToken.match(token, in: []) == nil)
    #expect(Secret.base64url(Secret.base64url(Data([0xFB, 0xFF, 0x01]))) == Data([0xFB, 0xFF, 0x01]))
}

@Test func oneAddressGuessingCantEndThePairing() {
    var code = PairingCode(code: "K7Q29XMD", now: 0)
    for left in [4, 3, 2, 1] { #expect(code.submit("AAAAAAAA", now: 1, source: "10.0.0.9") == .wrong(triesLeft: left)) }
    #expect(code.submit("AAAAAAAA", now: 1, source: "10.0.0.9") == .expired)
    // That address is done, right code or not; the phone on another still pairs.
    #expect(code.submit("K7Q29XMD", now: 1, source: "10.0.0.9") == .expired && !code.burned)
    #expect(code.triesLeft("100.64.0.7") == 5)
    #expect(code.submit("K7Q29XMD", now: 2, source: "100.64.0.7") { "a1" } == .accepted(attempt: "a1"))
    // Twenty wrong in all, from however many addresses, void it.
    var many = PairingCode(code: "K7Q29XMD", now: 0)
    for index in 0..<19 { _ = many.submit("AAAAAAAA", now: 1, source: "10.0.\(index / 4).\(index % 4)") }
    #expect(!many.burned && many.submit("AAAAAAAA", now: 1, source: "10.9.9.9") == .expired && many.burned)
    #expect(many.submit("K7Q29XMD", now: 1, source: "100.64.0.7") == .expired)
}
