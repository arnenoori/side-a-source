import Foundation
@testable import SideACore
import Testing

@Test func answeredGoesOnlyToPhonesThatShowedTheRequest() {
    var dismissals = PushDismissals()
    dismissals.sent("r1", to: ["a", "b"])
    #expect(dismissals.settled("r1", answeredBy: nil) == ["a", "b"])
    #expect(dismissals.settled("r1", answeredBy: nil).isEmpty)

    dismissals.sent("r2", to: ["a", "b"])
    #expect(dismissals.settled("r2", answeredBy: "a") == ["b"])

    #expect(dismissals.settled("r3", answeredBy: nil).isEmpty)
}

@Test func dismissalsKeepABoundedRecord() {
    var dismissals = PushDismissals()
    for n in 0...PushDismissals.kept { dismissals.sent("r\(n)", to: ["a"]) }
    #expect(dismissals.settled("r0", answeredBy: nil).isEmpty)
    #expect(dismissals.settled("r\(PushDismissals.kept)", answeredBy: nil) == ["a"])
}
