import SideAProtocol
import XCTest
@testable import SideARemote

@MainActor
final class PushRegistrarTests: XCTestCase {
    func testDebugBuildRegistersItsOwnTopicOnTheSandbox() {
        // Tests run inside the Debug app, so this is what a development build sends.
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

    /// Each Mac keeps its own switches; one never set reads the switch from before there was one per Mac.
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

    func testAVerifyPushForAnotherDeviceIsLeftAlone() async {
        let answered = await RelayDevice.answer(["verify": ["install": "someone-else", "device": "x", "challenge": "c"]])
        XCTAssertFalse(answered)
        let plain = await RelayDevice.answer(["aps": ["content-available": 1]])
        XCTAssertFalse(plain)
    }
}
