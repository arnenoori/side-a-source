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
        let prefs = NotificationPrefs.stored
        XCTAssertFalse(prefs.health)
        XCTAssertTrue(prefs.limits)
        XCTAssertTrue(prefs.requests)
    }

    func testAVerifyPushForAnotherDeviceIsLeftAlone() async {
        let answered = await RelayDevice.answer(["verify": ["install": "someone-else", "device": "x", "challenge": "c"]])
        XCTAssertFalse(answered)
        let plain = await RelayDevice.answer(["aps": ["content-available": 1]])
        XCTAssertFalse(plain)
    }
}
