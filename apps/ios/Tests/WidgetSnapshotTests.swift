import SideARemoteShared
import XCTest
@testable import SideARemote

@MainActor
final class WidgetSnapshotTests: XCTestCase {
    func testDemoSnapshotPutsNeedsYouFirstAndKeepsTheLimits() throws {
        let model = AppModel.demo()
        let snapshot = WidgetSnapshot(model, macID: "demo")
        XCTAssertEqual(snapshot.waiting, model.sessions.rows(.needsYou).count)
        XCTAssertEqual(snapshot.working, model.sessions.rows(.working).count)
        XCTAssertLessThanOrEqual(snapshot.sessions.count, 7)
        let phases = snapshot.sessions.map(\.phase)
        XCTAssertEqual(phases, phases.sorted { $0 == .needsYou && $1 == .working })
        XCTAssertLessThanOrEqual(snapshot.accounts.count, 4)
        XCTAssertNotNil(snapshot.tightest)
        XCTAssertEqual(snapshot.sessionURL("s1"), URL(string: "sidea-remote://session/demo/s1"))
    }

}
