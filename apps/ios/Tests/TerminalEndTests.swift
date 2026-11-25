import XCTest
@testable import SideARemote

@MainActor
final class TerminalEndTests: XCTestCase {
    /// A refused unlock or a closed-by-the-Mac code is not a process exit, so it can't be titled "Process Exited".
    func testOnlyAnExitIsTitledProcessExited() {
        XCTAssertEqual(TerminalEnd.exited(killed: false).title, "Process Exited")
        for end in [TerminalEnd.notUnlocked, .unpaired, .outdated, .tooManyScreens] {
            XCTAssertNotEqual(end.title, "Process Exited", "\(end)")
        }
    }

    func testCloseCodesMapToTheirOwnReason() {
        XCTAssertEqual(TerminalEnd(closeCode: 4410), .exited(killed: false))
        XCTAssertEqual(TerminalEnd(closeCode: 4404), .exited(killed: false))
        XCTAssertEqual(TerminalEnd(closeCode: 4401), .unpaired)
        XCTAssertEqual(TerminalEnd(closeCode: 4426), .outdated)
        XCTAssertEqual(TerminalEnd(closeCode: 4409), .tooManyScreens)
        XCTAssertNil(TerminalEnd(closeCode: 1006))
    }

    func testOnlyAFixableRefusalOffersTryAgain() {
        XCTAssertTrue(TerminalEnd.notUnlocked.canRetry)
        XCTAssertTrue(TerminalEnd.tooManyScreens.canRetry)
        XCTAssertFalse(TerminalEnd.exited(killed: true).canRetry)
        XCTAssertFalse(TerminalEnd.unpaired.canRetry)
        XCTAssertFalse(TerminalEnd.outdated.canRetry)
    }
}
