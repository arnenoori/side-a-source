import SideAProtocol
import XCTest
@testable import SideARemote

/// A request settled somewhere else leaves every surface here, and a stale answer never lands on the wrong request.
@MainActor
final class SettledRequestTests: XCTestCase {
    /// A Live Activity button whose answer the Mac refused (a gate that changed, a signature it wanted) must not drop the
    /// request from the activity or clear its notification: it's still waiting on the Mac.
    func testOnlyAnAnswerTheMacTakesSettlesTheActivity() {
        XCTAssertTrue(NotificationAnswer.Result.sent.settles)
        XCTAssertTrue(NotificationAnswer.Result.answeredElsewhere.settles)
        XCTAssertTrue(NotificationAnswer.Result.queued(mac: "MacBook Pro").settles)
        XCTAssertFalse(NotificationAnswer.Result.failed("Unlock your iPhone to allow this.").settles)
        XCTAssertFalse(NotificationAnswer.Result.noMac.settles)
    }

    private func note(_ id: String, _ category: String, t: String? = "request", mac: String? = "m1", at seconds: Double = 10) -> DeliveredRequests.Delivered {
        let payload = t.map { PushPayload(t: $0, mac: mac ?? "", sent: 0, rid: id) }
        return .init(id: id, category: category, payload: mac == nil ? nil : payload, date: Date(timeIntervalSince1970: seconds))
    }

    /// A notification whose "Answered" never came (relay down, phone off, the Mac quit with it waiting) still offers
    /// Allow and Deny; once the phone reads the open list, it goes.
    func testRequestNotificationsTheMacNoLongerHasOpenAreCleared() {
        let asked = Date(timeIntervalSince1970: 100)
        let delivered = [
            note("open", "REQUEST"),
            note("gone", "REQUEST_SAFE"),
            note("question", "QUESTION", t: "question"),
            note("plan", "PLAN", t: "plan"),
            // Arrived after the list was read: maybe too new to be in it.
            note("new", "REQUEST", at: 200),
            // Another Mac's.
            note("other", "REQUEST", mac: "m2"),
            // Not requests.
            note("done", "FINISHED", t: "finished"),
            note("answered", "ANSWERED", t: nil),
            // Open only: no payload to name its Mac.
            note("blind", "OPEN", mac: nil),
        ]
        XCTAssertEqual(DeliveredRequests.stale(delivered, mac: "m1", open: ["open"], asked: asked, onlyMac: true),
                       ["gone", "question", "plan", "blind"])
        XCTAssertEqual(DeliveredRequests.stale(delivered, mac: "m1", open: ["open"], asked: asked, onlyMac: false),
                       ["gone", "question", "plan"])
    }

    /// The approval sheet open on r1 while r1 is answered on the Mac: it shows r1 answered, never r2 in its place under
    /// a thumb already on Allow.
    func testTheApprovalSheetNeverSwapsInAnotherRequest() {
        let requests = (1...3).map { n in
            RemoteRequest(id: "r\(n)", agent: .claude, tool: "Bash", action: .command("echo \(n)"), risk: .normal, answers: [.allow, .deny],
                          title: "side-a", arrivedAt: Double(n))
        }
        XCTAssertNil(ApprovalSheet.shown(requests[0].id, in: Array(requests.dropFirst())))
        XCTAssertEqual(ApprovalSheet.shown(requests[1].id, in: requests)?.id, requests[1].id)
        // Answered here, it moves on: to the next, else the one before.
        XCTAssertEqual(ApprovalSheet.next(after: requests[0].id, in: requests), requests[1].id)
        XCTAssertEqual(ApprovalSheet.next(after: requests[2].id, in: requests), requests[1].id)
        XCTAssertNil(ApprovalSheet.next(after: requests[0].id, in: [requests[0]]))
    }
}
