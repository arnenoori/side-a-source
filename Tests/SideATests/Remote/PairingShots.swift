import AppKit
import CryptoKit
import Foundation
@testable import SideA
import SideACore
import SwiftUI
import Testing

/// Pictures of every pairing phase and of Settings > iPhone around it, light and dark, for a design review:
/// `SIDEA_PAIR_SHOTS=~/scratch/pair-shots/after swift test --filter PairingShots`. Skipped otherwise.
private let shots = ProcessInfo.processInfo.environment["SIDEA_PAIR_SHOTS"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

@MainActor private final class Rig {
    let keychain: TestKeychain
    let store: AccountStore
    let remote: RemoteController

    init(signs: @escaping @Sendable (RemoteKeychain.Identity) -> Bool = { _ in true }) throws {
        keychain = try TestKeychain()
        store = AccountStore(demo: true, root: FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))"))
        remote = RemoteController(store: store, keychain: keychain.store, addresses: ["127.0.0.1"], port: freePort())
        store.remote = remote
        remote.signs = signs
        remote.on = true
        remote.start()
    }

    func stop() { remote.endPairing(); remote.server?.stop() }

    func request(_ code: String, saw key: Data? = nil) -> PairRequest {
        PairRequest(code: code, device: DeviceInfo(name: "Arne’s iPhone", model: "iPhone18,1", system: "iOS 27.0", app: "1.0", build: 13, capabilities: []),
                    deviceID: Secret.base64url(Data(Secret.bytes(16))),
                    devicePublicKey: Secret.base64url(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
                    deviceSecretHash: Secret.base64url(Data(count: 32)), serverKeyHash: Secret.base64url(key ?? remote.spki ?? Data()))
    }
}

@MainActor private func until(_ what: @autoclosure () -> Bool) async throws {
    for _ in 0..<500 where !what() { try await Task.sleep(for: .milliseconds(10)) }
    try #require(what())
}

/// Hosted in an offscreen window so AppKit-backed controls draw as they do in the app.
@MainActor private func shoot(_ view: some View, _ name: String, size: CGSize) async throws {
    guard let shots else { return }
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
    for dark in [false, true] {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(900))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: shots.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        window.orderOut(nil)
    }
}

/// Pair iPhone… is never just greyed out: until a phone could reach the sheet, the row says what's in the way.
@MainActor @Test func pairIPhoneSaysWhatItWaitsFor() async throws {
    let gate = DispatchSemaphore(value: 0)
    let starting = try Rig(signs: { _ in gate.wait(); return true })
    #expect(starting.remote.pairReadiness == .starting)
    gate.signal()
    try await until(starting.remote.pairReadiness == .ready)
    starting.stop()

    let refused = try Rig(signs: { _ in false })
    defer { refused.stop() }
    try await until(refused.remote.pairReadiness == .keyBroken)
    #expect(refused.remote.server == nil)
}

/// Paired shows once the phone has its token, and the device is in the list by then.
@MainActor @Test func theSheetSaysPairedOnlyOnceTheDeviceIsSaved() async throws {
    let rig = try Rig()
    defer { rig.stop() }
    let remote = rig.remote
    try await until(remote.pairReadiness == .ready)
    remote.beginPairing()
    let session = try #require(remote.pairing)
    let pending = try session.submit(rig.request(session.code.code), spki: try #require(remote.spki)).get()
    session.decide(.pair)
    guard case .pairing = session.phase else { Issue.record("expected .pairing, got \(session.phase)"); return }
    #expect(remote.completePairing(pending.attemptID) != nil)
    #expect(session.phase == .paired("Arne’s iPhone") && remote.devices.devices.count == 1)
}

@MainActor @Test(.enabled(if: shots != nil), .timeLimit(.minutes(5))) func pairingShots() async throws {
    let sheet = PairingSheet.size
    let settings = CGSize(width: 520, height: 1180)
    let icon = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../design/SideA.icns")
    NSApplication.shared.applicationIconImage = NSImage(contentsOf: icon)

    let rig = try Rig()
    defer { rig.stop() }
    let remote = rig.remote
    try await until(remote.listening.values.contains(.ready))
    try await shoot(RemoteSettings(store: rig.store), "settings-1-ready", size: settings)

    remote.beginPairing()
    let session = try #require(remote.pairing)
    try await shoot(PairingSheet(remote: remote), "sheet-1-code", size: sheet)

    let pending = try session.submit(rig.request(session.code.code), spki: try #require(remote.spki)).get()
    try await shoot(PairingSheet(remote: remote), "sheet-2-confirm", size: sheet)

    session.decide(.pair)
    try await shoot(PairingSheet(remote: remote), "sheet-3-pairing", size: sheet)
    _ = remote.completePairing(pending.attemptID)
    try await shoot(PairingSheet(remote: remote), "sheet-4-paired", size: sheet)
    remote.endPairing()
    try await shoot(RemoteSettings(store: rig.store), "settings-2-one-phone", size: settings)

    remote.beginPairing()
    let again = try #require(remote.pairing)
    _ = again.submit(rig.request(again.code.code, saw: Data(count: 32)), spki: try #require(remote.spki))
    try await shoot(PairingSheet(remote: remote), "sheet-5-different-key", size: sheet)

    again.restart()
    _ = again.submit(rig.request(again.code.code), spki: try #require(remote.spki))
    _ = again.submit(rig.request(again.code.code), spki: try #require(remote.spki))
    try await shoot(PairingSheet(remote: remote), "sheet-6-two-devices", size: sheet)

    again.restart()
    var now = Date()
    for _ in 0...PairingSession.renewals { now = now.addingTimeInterval(301); again.tick(now: now) }
    try await shoot(PairingSheet(remote: remote), "sheet-7-expired", size: sheet)

    again.restart()
    _ = again.submit(rig.request(again.code.code), spki: try #require(remote.spki))
    again.decide(.mismatch)
    try await shoot(PairingSheet(remote: remote), "sheet-8-mismatch", size: sheet)

    again.restart()
    _ = again.submit(rig.request(again.code.code), spki: try #require(remote.spki))
    again.tick(now: Date().addingTimeInterval(PairingSession.confirmTime + 1))
    try await shoot(PairingSheet(remote: remote), "sheet-9-timeout", size: sheet)
    remote.endPairing()

    let refused = try Rig(signs: { _ in false })
    defer { refused.stop() }
    try await until(refused.remote.error == RemoteController.keyRefused)
    try await shoot(RemoteSettings(store: refused.store), "settings-3-key-refused", size: settings)

    let gate = DispatchSemaphore(value: 0)
    let starting = try Rig(signs: { _ in gate.wait(); return true })
    defer { gate.signal(); starting.stop() }
    try await shoot(RemoteSettings(store: starting.store), "settings-4-starting", size: settings)
}
