import SideAProtocol
import XCTest
@testable import SideARemote

@MainActor
final class TwoWayTests: XCTestCase {
    private let model = AppModel.demoSecond()

    func testCodexInItsSharedServerStopsAndQueues() throws {
        let session = try XCTUnwrap(model.sessions.session("mini-uptime"))
        XCTAssertTrue(Steer.available(for: session).contains(.interruptNow))
        XCTAssertTrue(model.reachesTerminal("mini-uptime"))
        XCTAssertFalse(model.outsideSharedServer("mini-uptime"))
    }

    func testCodexOutsideTheSharedServerSaysRepliesWait() {
        XCTAssertTrue(model.outsideSharedServer("mini-dns"))
        XCTAssertFalse(model.reachesTerminal("mini-dns"))
    }

    func testTheDroppedReplyGoesAgainInFull() {
        let dropped = model.droppedReply("mini-uptime")
        XCTAssertEqual(dropped?.text, "Also page when the TLS check fails")
        XCTAssertEqual(dropped?.complete, true)
        model.retryDropped("mini-uptime")
        XCTAssertEqual(model.transcripts.outgoing["mini-uptime"]?.last?.text, "Also page when the TLS check fails")
    }

    func testClaudeInATerminalHearsRepliesAsNotes() {
        XCTAssertTrue(model.arrivesAsNote("mini-notes"))
        XCTAssertFalse(model.arrivesAsNote("mini-backup"))
    }
}
