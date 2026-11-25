import SideAProtocol
import XCTest
@testable import SideARemote

@MainActor
final class AnsweredTruthTests: XCTestCase {
    private func answered(_ outcome: RequestOutcome, then delivery: TranscriptStore.Delivery? = nil, macLine: String? = nil) -> TranscriptStore.AnsweredRequest {
        let request = DemoData(now: .now).requests[0]
        let store = TranscriptStore([:])
        store.onRetry = { _ in }
        store.record(outcome, for: request, in: "s")
        if let delivery { store.deliver(request.id, in: "s", delivery, macLine: macLine) }
        return store.answered["s"]?.first ?? TranscriptStore.AnsweredRequest(request: request, outcome: outcome)
    }

    func testADeniedAnswerTheMacAllowedReadsAsTheMacSaysNotDenied() {
        let row = answered(.denied, then: .answeredElsewhere, macLine: "Allowed on Mac")
        XCTAssertTrue(row.line.hasPrefix("Allowed on Mac"), row.line)
        XCTAssertFalse(row.line.contains("Denied"))
    }

    func testAnAnswerThatDidntWinNeverClaimsTheOutcomeTheUserChose() {
        XCTAssertTrue(answered(.denied, then: .answeredElsewhere).line.hasPrefix("Answered elsewhere"))
        XCTAssertTrue(answered(.denied, then: .gone).line.hasPrefix("Answered elsewhere"))
        XCTAssertTrue(answered(.denied, then: .failed("offline")).line.hasPrefix("Not sent"))
        XCTAssertTrue(answered(.denied, then: .delivered).line.hasPrefix("Denied"))
        XCTAssertTrue(answered(.denied, then: .unknown).line.hasPrefix("Denied"))
    }

    func testARequestThisDevicesOwnAnswerResolvedIsDeliveredNotAnsweredElsewhere() {
        let own = RequestResolution(requestID: "r", by: .device, deviceID: "phone", deviceName: "iPhone", answer: .allow, at: 1)
        let other = RequestResolution(requestID: "r", by: .device, deviceID: "ipad", deviceName: "iPad", answer: .allow, at: 1)
        let mac = RequestResolution(requestID: "r", by: .mac, answer: .allow, at: 1)
        XCTAssertEqual(TranscriptStore.Delivery.afterDoubt(own, thisDevice: "phone"), .delivered)
        XCTAssertEqual(TranscriptStore.Delivery.afterDoubt(other, thisDevice: "phone"), .answeredElsewhere)
        XCTAssertEqual(TranscriptStore.Delivery.afterDoubt(mac, thisDevice: "phone"), .answeredElsewhere)
        XCTAssertEqual(TranscriptStore.Delivery.afterDoubt(nil, thisDevice: "phone"), .answeredElsewhere)
    }
}
