import Foundation
import SideAProtocol
import SideARemoteKit
import Testing

private let outcomes: [OutboxOutcome] = [.delivered(Data()), .answeredElsewhere(nil), .unknown, .notDelivered,
                                         .failed(APIError(code: .notFound, message: "Gone.")),
                                         .failed(APIError(code: .confirmInvalid, message: "No."))]

@Test func everyAnswerToATakeBack() {
    let events: [ReplyProgress.Event] = [.takenBack, .keptBack, .keptBack, .keptBack, .tooLate, .keptBack]
    for (outcome, event) in zip(outcomes, events) { #expect(ReplyProgress.Event.takeBack(answered: outcome) == event, "\(outcome)") }
    for outcome in outcomes { #expect(ReplyProgress(.takingBack).next(.takeBack(answered: outcome)) != nil) }
}

@Test func everyAnswerToAStop() {
    let answers: [InterruptAnswer] = [.stopped, .stopped, .unreachable, .unreachable, .refused("Gone."), .refused("No.")]
    for (outcome, answer) in zip(outcomes, answers) { #expect(InterruptAnswer(outcome) == answer, "\(outcome)") }
    #expect(InterruptAnswer.stopped.notice == nil)
    #expect(InterruptAnswer.refused("No.").notice == "Couldn't stop it. No.")
    #expect(InterruptAnswer.unreachable.notice == "Couldn't reach the Mac to stop it.")
}

// Every state × event of a note watched in its session's mail.
@Test func everyEventFromEveryNoteMailState() {
    typealias M = NoteMail
    let events: [M.Event] = [.delivered, .noteGone, .mailShown, .mailAbsent(age: 5), .mailAbsent(age: 31)]
    let table: [(M, [(M, Bool)])] = [
        (.unwatched, [(.unseen, false), (.unwatched, false), (.unwatched, false), (.unwatched, false), (.unwatched, false)]),
        (.unseen, [(.unseen, false), (.unwatched, false), (.seen, false), (.unseen, false), (.unwatched, true)]),
        (.seen, [(.seen, false), (.unwatched, false), (.seen, false), (.unwatched, true), (.unwatched, true)]),
    ]
    #expect(table.map(\.0) == M.allCases)
    for (state, row) in table {
        for (event, expected) in zip(events, row) {
            let next = state.next(event)
            #expect(next.state == expected.0 && next.read == expected.1, "\(state) \(event)")
        }
    }
}

// Every state × event of the held replies' delivery.
@Test func everyEventFromEveryHeldDeliveryState() {
    typealias H = HeldDelivery
    let events: [H.Event] = [.asked(caughtUp: false), .asked(caughtUp: true), .done]
    let table: [(H, [(H, [H.Effect])])] = [
        (.idle, [(.catchingUp, [.restartTimer]), (.delivering, [.cancelTimer, .deliver]), (.idle, [])]),
        (.catchingUp, [(.catchingUp, [.restartTimer]), (.delivering, [.cancelTimer, .deliver]), (.catchingUp, [])]),
        (.delivering, [(.delivering, []), (.delivering, []), (.idle, [])]),
    ]
    #expect(table.map(\.0) == H.allCases)
    for (state, row) in table {
        for (event, expected) in zip(events, row) {
            let next = state.next(event)
            #expect(next.state == expected.0 && next.effects == expected.1, "\(state) \(event)")
        }
    }
}
