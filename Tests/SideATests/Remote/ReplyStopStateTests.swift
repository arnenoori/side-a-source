import Foundation
@testable import SideA
import SideAProtocol
import Testing

private typealias S = ReplyReceipts.StopState

// Every state × event of a watched reply's part in a Stop. Nil: the event leaves it as it was.
@MainActor @Test func everyEventFromEveryStopState() {
    let states: [S] = [.none, .stopping(letGo: nil), .stopping(letGo: 5), .carried(since: 3)]
    let at = 9.0
    let table: [S: [S.Event: S]] = [
        .none: [.stopBegins: .stopping(letGo: nil), .carry: .carried(since: at)],
        .stopping(letGo: nil): [.letGo: .stopping(letGo: at), .stopEnds: .none],
        .stopping(letGo: 5): [.letGo: .stopping(letGo: at), .stopEnds: .none],
        .carried(since: 3): [.carry: .carried(since: at), .joined: .none],
    ]
    for state in states {
        for event in S.Event.allCases {
            #expect(state.next(event, at: at) == table[state]?[event], "\(state) \(event)")
        }
    }
}

// Resend without send isn't something the Mac's routes ask for.
@MainActor @Test func whatFollowsACodexInterrupt() {
    typealias F = CodexTerminals.Interrupt.Follows
    let table: [(send: Bool, resend: Bool, F, holds: Bool)] = [
        (false, false, .nothing, false), (false, true, .nothing, false), (true, false, .reply, true), (true, true, .resend, true),
    ]
    for (send, resend, follows, holds) in table {
        let stop = CodexTerminals.Interrupt(ids: ["a"], follows: F(send: send, resend: resend))
        #expect(stop.follows == follows && stop.holds == holds, "\(send) \(resend)")
    }
}

// Every state × event of Send Now's queued reply on the Mac. Missing: the event doesn't apply.
@MainActor @Test func everyEventFromEveryPromotionState() {
    typealias P = SessionCommands.Promotion
    let table: [P: [P.Event: (P, Bool)]] = [
        .takenOut: [.planRefused: (.putBack, true), .planDelivered: (.delivered, false), .planTypes: (.waiting, false)],
        .waiting: [.sendBegins: (.sending, false), .patienceRanOut: (.putBack, true)],
        .sending: [.sendFailed: (.putBack, true), .sendSucceeded: (.delivered, false)],
        .delivered: [:],
        .putBack: [.sendBegins: (.refused, false)],
        .refused: [:],
    ]
    for (state, row) in table {
        for event in P.Event.allCases {
            let next = state.next(event)
            #expect(next?.state == row[event]?.0 && next?.putBack == row[event]?.1, "\(state) \(event)")
        }
    }
}

// Every state × event of a watched reply's receipt. Missing: the event leaves it as it was.
@MainActor @Test func everyEventFromEveryFollowingState() {
    typealias F = ReplyReceipts.Following
    let stages: [ReplyReceipt.Stage] = [.typed, .held, .read, .unsent]
    let events = stages.map(F.Event.stage) + [.expire]
    let table: [F: [F.Event: F]] = [
        .open(.typed): [.stage(.held): .open(.held), .stage(.read): .settled(.read), .stage(.unsent): .settled(.unsent), .expire: .expired(.typed)],
        .open(.held): [.stage(.typed): .open(.typed), .stage(.read): .settled(.read), .stage(.unsent): .settled(.unsent), .expire: .expired(.held)],
        .settled(.read): [:],
        .settled(.unsent): [.stage(.held): .open(.held), .stage(.read): .settled(.read)],
        .expired(.typed): [:],
        .expired(.held): [:],
    ]
    for (state, row) in table {
        for event in events { #expect(state.next(event) == row[event], "\(state) \(event)") }
    }
}
