import SideAProtocol
import SwiftUI
import XCTest
@testable import SideARemote

@MainActor
final class QuitSessionTests: XCTestCase {
    private func session(_ id: String) -> RemoteSession {
        RemoteSession(id: id, agent: .claude, title: id, project: "side-a", status: .idle, statusAt: 1_000)
    }

    /// A destructive swipe action makes UIKit drop the row itself; a quit that asks first, or fails, leaves the row in
    /// the data, and the list's next update aborts on "invalid number of items in section".
    func testASwipeQuitIsNeverDestructiveButTheMenuOneIs() {
        XCTAssertNil(QuitButton.role(swipe: true))
        XCTAssertEqual(QuitButton.role(swipe: false), .destructive)
    }

    func testAQuitSessionIsRecordedSoItsPageCanPop() {
        let store = SessionsStore([session("a"), session("b")])
        XCTAssertTrue(store.ended.isEmpty)
        store.markEnded(["a"])
        XCTAssertEqual(store.ended, ["a"])
        store.markEnded(["b", "a"])
        XCTAssertEqual(store.ended, ["a", "b"])
    }

    func testThePathIsCutAtTheQuitSessionAndEverythingPushedOverIt() {
        let step = Route.turnDiff("a", turn: "t1")
        let path: [Route] = [.session("a", mac: "m"), step]
        XCTAssertEqual(GoneSessions.firstEnded(in: path) { id, _ in id == "a" }, 0)
        XCTAssertNil(GoneSessions.firstEnded(in: path) { _, _ in false })
        let two: [Route] = [.session("b", mac: "m"), .session("a", mac: "m"), step]
        XCTAssertEqual(GoneSessions.firstEnded(in: two) { id, _ in id == "a" }, 1)
        XCTAssertNil(GoneSessions.firstEnded(in: [.waiting(mac: "m")]) { _, _ in true })
    }

    func testAPushedPageOfAQuitSessionIsCutEvenWhenItsOwnPageIsNotInThePath() {
        let path: [Route] = [.account("x", mac: "m"), .turnDiff("a", turn: "t")]
        XCTAssertEqual(GoneSessions.firstEnded(in: path) { id, _ in id == "a" }, 1)
    }
}
