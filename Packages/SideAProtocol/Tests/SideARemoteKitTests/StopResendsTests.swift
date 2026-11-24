import Foundation
import SideARemoteKit
import Testing

private enum Event: CaseIterable { case press, cancel, answered, answeredForAnEarlierPress, gaveBack, gaveBackLate }

// Each state (idle, pressed) × each event: the state after it, and whether replies go again.
@Test func everyEventFromEveryStateOfAResendAfterAStop() {
    let pressedAt = Date(timeIntervalSince1970: 1_000)
    let table: [(pressed: Bool, Event, after: Bool, resends: Bool)] = [
        (false, .press, true, false), (true, .press, true, false),
        (false, .cancel, false, false), (true, .cancel, false, false),
        (false, .answered, false, false), (true, .answered, false, false),
        (false, .answeredForAnEarlierPress, false, false), (true, .answeredForAnEarlierPress, true, false),
        (false, .gaveBack, false, false), (true, .gaveBack, false, true),
        (false, .gaveBackLate, false, false), (true, .gaveBackLate, false, false),
    ]
    #expect(Set(table.map { "\($0.pressed) \($0.1)" }).count == 2 * Event.allCases.count)
    for (pressed, event, after, resends) in table {
        var resend = StopResends()
        if pressed { resend.press("s", at: pressedAt) }
        var went = false
        switch event {
        case .press: resend.press("s", at: pressedAt)
        case .cancel: resend.cancel("s")
        case .answered: resend.answered("s", pressedAt: pressedAt)
        case .answeredForAnEarlierPress: resend.answered("s", pressedAt: pressedAt - 1)
        case .gaveBack: went = resend.gaveBack("s", now: pressedAt + StopResends.within - 1)
        case .gaveBackLate: went = resend.gaveBack("s", now: pressedAt + StopResends.within)
        }
        #expect(resend.isPressed("s") == after && went == resends, "\(pressed) \(event)")
        #expect(!resend.isPressed("other"))
    }
}
