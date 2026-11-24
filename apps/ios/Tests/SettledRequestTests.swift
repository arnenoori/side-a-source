import SideAProtocol
import XCTest
@testable import SideARemote

@MainActor
final class SettledRequestTests: XCTestCase {
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

    func testRequestNotificationsTheMacNoLongerHasOpenAreCleared() {
        let asked = Date(timeIntervalSince1970: 100)
        let delivered = [
            note("open", "REQUEST"),
            note("gone", "REQUEST_SAFE"),
            note("question", "QUESTION", t: "question"),
            note("plan", "PLAN", t: "plan"),
            note("new", "REQUEST", at: 200),
            note("other", "REQUEST", mac: "m2"),
            note("done", "FINISHED", t: "finished"),
            note("answered", "ANSWERED", t: nil),
            note("blind", "OPEN", mac: nil),
        ]
        XCTAssertEqual(DeliveredRequests.stale(delivered, mac: "m1", open: ["open"], asked: asked, onlyMac: true),
                       ["gone", "question", "plan", "blind"])
        XCTAssertEqual(DeliveredRequests.stale(delivered, mac: "m1", open: ["open"], asked: asked, onlyMac: false),
                       ["gone", "question", "plan"])
    }

    func testTheApprovalSheetNeverSwapsInAnotherRequest() {
        let requests = (1...3).map { n in
            RemoteRequest(id: "r\(n)", agent: .claude, tool: "Bash", action: .command("echo \(n)"), risk: .normal, answers: [.allow, .deny],
                          title: "side-a", arrivedAt: Double(n))
        }
        XCTAssertNil(ApprovalSheet.shown(requests[0].id, in: Array(requests.dropFirst())))
        XCTAssertEqual(ApprovalSheet.shown(requests[1].id, in: requests)?.id, requests[1].id)
        XCTAssertEqual(ApprovalSheet.next(after: requests[0].id, in: requests), requests[1].id)
        XCTAssertEqual(ApprovalSheet.next(after: requests[2].id, in: requests), requests[1].id)
        XCTAssertNil(ApprovalSheet.next(after: requests[0].id, in: [requests[0]]))
    }
}
