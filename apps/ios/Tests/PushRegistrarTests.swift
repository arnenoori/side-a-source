import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import XCTest
@testable import SideARemote

@MainActor
final class PushRegistrarTests: XCTestCase {
    func testDebugBuildRegistersItsOwnTopicOnTheSandbox() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.arnenoori.sidea.remote.dev")
        XCTAssertEqual(PushRegistrar.environment, .sandbox)
    }

    func testPrefsFollowTheSettingsSwitches() {
        let defaults = UserDefaults.standard
        defer { ["notify.health", "notify.limits"].forEach(defaults.removeObject) }
        defaults.set(false, forKey: "notify.health")
        defaults.set(true, forKey: "notify.limits")
        let prefs = NotificationPrefs.stored(for: "studio")
        XCTAssertFalse(prefs.health)
        XCTAssertTrue(prefs.limits)
        XCTAssertTrue(prefs.requests)
    }

    func testAQuietMacIsToldUntilTurnedOff() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PushRegistrarTests.\(UUID())"))
        XCTAssertEqual(NotificationPrefs.stored(for: "studio", in: defaults).macQuiet, true)
        defaults.set(false, forKey: NotificationPrefs.Key.macQuiet.key(mac: "studio"))
        XCTAssertEqual(NotificationPrefs.stored(for: "studio", in: defaults).macQuiet, false)
        XCTAssertEqual(NotificationPrefs.stored(for: "laptop", in: defaults).macQuiet, true)
    }

    func testAQuietMacsPushOpensThatMac() {
        func mac(_ install: String) -> PairedMac {
            PairedMac(endpoint: Endpoint(macID: "m-\(install)", baseURL: URL(string: "https://100.64.0.1:47800")!, serverKeyHash: "k", name: install),
                      deviceID: "d", deviceName: "iPhone", relayInstallID: install, relayURL: "https://relay.example")
        }
        let macs = [mac("i-r1"), mac("i-r2")]
        let named = RelayDevice.activityMacID(install: "i-r2")
        XCTAssertEqual(AppDelegate.quietLink(["q": named], macs: macs)?.absoluteString, "sidea-remote://mac/m-i-r2")
        XCTAssertNil(AppDelegate.quietLink(["q": "unknown"], macs: macs))
        XCTAssertNil(AppDelegate.quietLink([:], macs: macs))
    }

    func testEachMacHasItsOwnSwitches() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PushRegistrarTests.\(UUID())"))
        defaults.set(false, forKey: "notify.finished")
        defaults.set(true, forKey: NotificationPrefs.Key.finished.key(mac: "studio"))
        defaults.set(false, forKey: NotificationPrefs.Key.liveActivity.key(mac: "laptop"))
        XCTAssertTrue(NotificationPrefs.stored(for: "studio", in: defaults).finished)
        XCTAssertFalse(NotificationPrefs.stored(for: "laptop", in: defaults).finished)
        XCTAssertTrue(NotificationPrefs.stored(for: "studio", in: defaults).liveActivity)
        XCTAssertFalse(NotificationPrefs.stored(for: "laptop", in: defaults).liveActivity)
        NotificationPrefs.forget(macID: "studio", in: defaults)
        XCTAssertFalse(NotificationPrefs.stored(for: "studio", in: defaults).finished)
    }

    func testATokenTheRelayHasNotHeardIsReportedUntilItHas() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PushRegistrarTests.\(UUID())"))
        let calls = Calls()
        let registrar = PushRegistrar(defaults: defaults, retryWait: .milliseconds(5)) { _ in await calls.next() >= 3 }
        registrar.received(Data([0xab, 0xcd]))
        for _ in 0..<400 where defaults.bool(forKey: "push.relayOwed") { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(defaults.bool(forKey: "push.relayOwed"))
        let count = await calls.count
        XCTAssertEqual(count, 3)
        registrar.reportOwed()
        try await Task.sleep(for: .milliseconds(30))
        let after = await calls.count
        XCTAssertEqual(after, 3)
    }

    func testAVerifyPushForAnotherDeviceIsLeftAlone() async {
        let answered = await RelayDevice.answer(["verify": ["install": "someone-else", "device": "x", "challenge": "c"]])
        XCTAssertFalse(answered)
        let plain = await RelayDevice.answer(["aps": ["content-available": 1]])
        XCTAssertFalse(plain)
    }
}

private actor Calls {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}
