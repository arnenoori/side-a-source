import CryptoKit
import Foundation
@testable import SideA
import SideACore
import Testing

private let spki = Data(repeating: 7, count: 32)

private func request(_ code: String, saw key: Data = spki, phone: Curve25519.KeyAgreement.PrivateKey = .init()) -> PairRequest {
    PairRequest(code: code, device: DeviceInfo(name: "Arne’s iPhone", model: "iPhone18,1", system: "iOS 27.0", app: "1.0", build: 1, capabilities: []),
                deviceID: Secret.base64url(Data(Secret.bytes(16))), devicePublicKey: Secret.base64url(phone.publicKey.rawRepresentation),
                deviceSecretHash: Secret.base64url(Data(count: 32)), serverKeyHash: Secret.base64url(key))
}

@MainActor @Test func aRightCodeWaitsForPairAndBothSidesShareTheDigitsAndThePushKey() async throws {
    let session = PairingSession(installID: "XsFDif2r-oebU07VsxiVgA")
    defer { session.end() }
    #expect(throws: PairingSession.Refusal.wrong) { try session.submit(request("AAAAAAAA"), spki: spki).get() }
    let phone = Curve25519.KeyAgreement.PrivateKey()
    let code = session.code.code
    let pending = try session.submit(request(code, phone: phone), spki: spki).get()
    let attempt = try #require(session.attempt)
    // The phone computes the same six digits from what the Mac sent it.
    let macKey = try #require(Secret.base64url(pending.macPublicKey))
    #expect(try PairingTranscript.display(PairingTranscript.comparisonCode(code: code.lowercased(), nonce: pending.nonce, macPublicKey: pending.macPublicKey,
                                                                            devicePublicKey: phone.publicKey.rawRepresentation.base64URL,
                                                                            serverKeyHash: spki.base64URL)) == attempt.comparison)
    #expect(attempt.keyMatches && session.knows(pending.attemptID))

    async let decision = session.wait(pending.attemptID)
    try await Task.sleep(for: .milliseconds(50))
    session.decide(.pair)
    #expect(await decision == .pair)
    // The sheet says Paired only once the phone has its token.
    #expect(session.phase == .pairing(attempt))
    session.decide(.mismatch)
    #expect(session.phase == .pairing(attempt))
    session.finished("someone-else", saved: true)
    #expect(session.phase == .pairing(attempt))
    session.finished(pending.attemptID, saved: true)
    #expect(session.phase == .paired("Arne’s iPhone"))
    let (approved, key) = try #require(session.takeApproved(pending.attemptID))
    let phoneSide = try PushKey.derive(phone, peer: Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey), macPublicKey: macKey,
                                       devicePublicKey: phone.publicKey.rawRepresentation, installID: "XsFDif2r-oebU07VsxiVgA",
                                       deviceID: attempt.request.deviceID)
    #expect(approved.id == pending.attemptID && key == phoneSide)
    #expect(session.takeApproved(pending.attemptID) == nil)
    // Single use.
    #expect(throws: PairingSession.Refusal.expired) { try session.submit(request(code), spki: spki).get() }
}

@MainActor @Test func eachEndingSaysWhyAndADeviceThatWasntSavedIsntCalledPaired() throws {
    let session = PairingSession()
    defer { session.end() }
    var pending = try session.submit(request(session.code.code), spki: spki).get()
    session.decide(.pair)
    session.finished(pending.attemptID, saved: false)
    #expect(session.phase == .stopped(.unsaved))

    session.restart()
    _ = try session.submit(request(session.code.code), spki: spki).get()
    session.decide(.mismatch)
    #expect(session.phase == .stopped(.mismatch))

    session.restart()
    pending = try session.submit(request(session.code.code), spki: spki).get()
    session.tick(now: Date().addingTimeInterval(PairingSession.confirmTime + 1))
    #expect(session.phase == .stopped(.timeout) && session.knows(pending.attemptID))
    // A stopped sheet's later ticks change nothing.
    session.tick(now: Date().addingTimeInterval(10_000))
    #expect(session.phase == .stopped(.timeout))
}

@MainActor @Test func aSecondPhoneOnTheSameCodeVoidsBoth() async throws {
    let session = PairingSession()
    defer { session.end() }
    let first = try session.submit(request(session.code.code), spki: spki).get()
    async let decision = session.wait(first.attemptID)
    try await Task.sleep(for: .milliseconds(50))
    #expect(throws: PairingSession.Refusal.busy) { try session.submit(request(session.code.code), spki: spki).get() }
    #expect(await decision == .cancel)
    #expect(session.phase == .stopped(.twoDevices))
}

@MainActor @Test func aSubstitutedKeyNeverOffersPairAndSilenceTimesOut() async throws {
    let session = PairingSession()
    defer { session.end() }
    let other = try session.submit(request(session.code.code, saw: Data(count: 32)), spki: spki).get()
    #expect(session.attempt?.keyMatches == false)
    #expect(await session.wait(other.attemptID) == .mismatch)
    session.decide(.pair)
    #expect(session.takeApproved(other.attemptID) == nil)

    let late = PairingSession()
    defer { late.end() }
    let pending = try late.submit(request(late.code.code), spki: spki).get()
    async let decision = late.wait(pending.attemptID)
    try await Task.sleep(for: .milliseconds(50))
    late.tick(now: Date().addingTimeInterval(61))
    #expect(await decision == .timeout)
}

@MainActor @Test func thePairingLinkCarriesTheAddressesKeyAndCode() {
    #expect(PairingSession.link(address: "100.1.2.3:47800", lan: [], spki: spki, mac: MacInfo(id: "ab", name: "Arne’s Mac"), tailnetName: "t", code: "K7Q29XMD")
            == "https://getsidea.com/pair#v=2&a=100.1.2.3:47800&fp=\(Secret.base64url(spki))&n=Arne%E2%80%99s%20Mac&m=ab&t=t&c=K7Q29XMD")
    #expect(PairingSession.link(address: "192.168.1.20:47800", lan: ["192.168.1.20:47800", "10.0.0.7:47800"], spki: spki,
                                mac: MacInfo(id: "ab", name: "Mac"), tailnetName: nil, code: "K7Q29XMD")
            == "https://getsidea.com/pair#v=2&a=192.168.1.20:47800&l=192.168.1.20:47800,10.0.0.7:47800&fp=\(Secret.base64url(spki))&n=Mac&m=ab&c=K7Q29XMD")
}

@MainActor @Test func anUnusedCodeRenewsSixTimesThenStops() {
    let session = PairingSession()
    defer { session.end() }
    var codes: Set<String> = [session.code.code]
    var now = Date()
    for _ in 0..<6 {
        now = now.addingTimeInterval(301)
        session.tick(now: now)
        codes.insert(session.code.code)
    }
    #expect(session.renewed == 6 && codes.count == 7 && session.phase == .code)
    session.tick(now: now.addingTimeInterval(301))
    #expect(session.phase == .stopped(.expired))
    // Start Again keeps renewing.
    session.restart()
    #expect(session.renewing && session.renewed == 0 && session.phase == .code)
}

@MainActor @Test func thePhonesCancelOrAVanishedWaitPutsANewCodeUp() async throws {
    let session = PairingSession()
    defer { session.end() }
    // Long enough that a loaded machine still polls again within it.
    session.dropGrace = .milliseconds(600)
    let first = session.code.code
    let pending = try session.submit(request(first), spki: spki).get()
    async let decision = session.wait(pending.attemptID, connection: 1)
    try await Task.sleep(for: .milliseconds(50))
    session.cancel("someone-else")
    #expect(session.attempt != nil)
    session.cancel(pending.attemptID)
    #expect(await decision == .cancel)
    #expect(session.phase == .code && session.code.code != first)
    #expect(throws: PairingSession.Refusal.wrong) { try session.submit(request(first), spki: spki).get() }

    // A dropped connection that polls again in time keeps the attempt.
    let second = try session.submit(request(session.code.code), spki: spki).get()
    async let dropped = session.wait(second.attemptID, connection: 2)
    try await Task.sleep(for: .milliseconds(50))
    session.dropped(connection: 2)
    #expect(await dropped == .cancel)
    async let again = session.wait(second.attemptID, connection: 3)
    try await Task.sleep(for: .milliseconds(200))
    #expect(session.attempt?.id == second.attemptID)
    // One that doesn't loses it.
    session.dropped(connection: 3)
    #expect(await again == .cancel)
    try await Task.sleep(for: .milliseconds(900))
    #expect(session.attempt == nil && session.phase == .code)
}
