import SideAProtocol
import SideARemoteKit
import XCTest
@testable import SideARemote

@MainActor
final class MacNicknameTests: XCTestCase {
    /// Defaults of the test's own, gone after it.
    private func scratchDefaults() -> UserDefaults {
        let suite = "MacNicknameTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testANicknameWinsOverTheMacsNameAndOutlivesItsHellos() {
        let defaults = scratchDefaults()
        let mac = MacConnection(name: "Arne's MacBook Pro", state: .live, lastSeen: .now)
        mac.rename("  Studio  ", macID: "m1", in: defaults)
        XCTAssertEqual(mac.name, "Studio")
        // The Mac renamed itself: the phone's name for it stays.
        mac.apply(RemoteState(), name: "MacBook Pro (2)")
        XCTAssertEqual(mac.reportedName, "MacBook Pro (2)")
        XCTAssertEqual(mac.name, "Studio")
        // Another launch reads it back, for this Mac only.
        XCTAssertEqual(MacNicknames.nickname(for: "m1", in: defaults), "Studio")
        XCTAssertNil(MacNicknames.nickname(for: "m2", in: defaults))
        XCTAssertEqual(MacNicknames.name("Mac mini", macID: "m2", in: defaults), "Mac mini")
    }

    func testClearingGoesBackToTheMacsOwnName() {
        let defaults = scratchDefaults()
        let mac = MacConnection(name: "MacBook Pro", state: .live, lastSeen: .now)
        mac.rename("Studio", macID: "m1", in: defaults)
        mac.rename("   ", macID: "m1", in: defaults)
        XCTAssertNil(mac.nickname)
        XCTAssertEqual(mac.name, "MacBook Pro")
        XCTAssertNil(MacNicknames.nickname(for: "m1", in: defaults))
        mac.rename("Studio", macID: "m1", in: defaults)
        mac.rename(nil, macID: "m1", in: defaults)
        XCTAssertEqual(mac.name, "MacBook Pro")
    }

    /// Back in front, a drop seen only while away gets the minute of "Reconnecting…", so Send isn't held off; an
    /// ended pairing doesn't.
    func testComingBackReconnectsRatherThanStayingOffline() {
        let mac = MacConnection(name: "Mac", state: .offline(.macUnreachable), lastSeen: .now)
        mac.foregrounded()
        guard case .reconnecting = mac.state else { return XCTFail("\(mac.state)") }
        XCTAssertFalse(mac.isOffline)
        let revoked = MacConnection(name: "Mac", state: .offline(.revoked), lastSeen: .now)
        revoked.foregrounded()
        XCTAssertEqual(revoked.state, .offline(.revoked))
    }
}
