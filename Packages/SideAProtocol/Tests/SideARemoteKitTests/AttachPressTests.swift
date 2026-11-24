import CoreGraphics
import SideARemoteKit
import Testing

// Every state × event of the + button's press.
@Test func everyEventFromEveryPressState() {
    typealias P = AttachPress
    let start = CGPoint(x: 10, y: 10), near = CGPoint(x: 15, y: 15), far = CGPoint(x: 40, y: 10)
    let events: [P.Event] = [.moved(start: start, to: near), .moved(start: start, to: far), .heldLong, .gaveUp, .lifted, .lost]
    let table: [(P, [(P, [P.Effect])])] = [
        (.idle, [(.down(start), [.pressBegins]), (.down(start), [.pressBegins]), (.idle, []), (.idle, []),
                 (.idle, [.cancelHold, .pressEnds]), (.idle, [])]),
        (.down(start), [(.down(start), []), (.cancelled, [.cancelHold]), (.held, [.showStrip]), (.cancelled, []),
                        (.idle, [.cancelHold, .pressEnds, .tap]), (.idle, [.cancelHold, .pressEnds])]),
        (.held, [(.held, [.track(near)]), (.held, [.track(far)]), (.held, []), (.cancelled, []),
                 (.idle, [.cancelHold, .pressEnds, .release]), (.idle, [.cancelHold, .stopTracking, .pressEnds])]),
        (.cancelled, [(.cancelled, []), (.cancelled, []), (.cancelled, []), (.cancelled, []),
                      (.idle, [.cancelHold, .pressEnds]), (.idle, [.cancelHold, .pressEnds])]),
    ]
    for (state, row) in table {
        for (event, expected) in zip(events, row) {
            let next = state.next(event)
            #expect(next.state == expected.0 && next.effects == expected.1, "\(state) \(event)")
        }
    }
}
