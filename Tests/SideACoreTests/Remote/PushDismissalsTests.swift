import Foundation
@testable import SideACore
import Testing

/// Answered anywhere, a request's notification is cleared only on the phones that showed it, and never by a fresh
/// "Answered" on the phone that answered it or on one that had that kind of notification off.
@Test func answeredGoesOnlyToPhonesThatShowedTheRequest() {
    var dismissals = PushDismissals()
    dismissals.sent("r1", to: ["a", "b"])
    // c has requests off, or was watching the session: it was never sent r1.
    #expect(dismissals.settled("r1", answeredBy: nil) == ["a", "b"])
    // Once only.
    #expect(dismissals.settled("r1", answeredBy: nil).isEmpty)

    dismissals.sent("r2", to: ["a", "b"])
    #expect(dismissals.settled("r2", answeredBy: "a") == ["b"])

    // A request no phone was told about clears nothing.
    #expect(dismissals.settled("r3", answeredBy: nil).isEmpty)
}

@Test func dismissalsKeepABoundedRecord() {
    var dismissals = PushDismissals()
    for n in 0...PushDismissals.kept { dismissals.sent("r\(n)", to: ["a"]) }
    #expect(dismissals.settled("r0", answeredBy: nil).isEmpty)
    #expect(dismissals.settled("r\(PushDismissals.kept)", answeredBy: nil) == ["a"])
}
