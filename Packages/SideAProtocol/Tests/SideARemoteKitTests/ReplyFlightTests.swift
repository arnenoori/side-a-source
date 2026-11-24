import SideAProtocol
import SideARemoteKit
import Testing

@Test func aRetryReportsUnderTheKeyItRetries() {
    let table = [("k", "k"), ("k:r1", "k"), ("k:r1:r2", "k"), ("k:r12:r3:r4", "k"), ("k:r", "k:r"), ("k:r1x", "k:r1x"),
                 ("k:r1:x", "k:r1:x"), ("a:allow:a3", "a:allow:a3"), ("", "")]
    for (key, family) in table { #expect(ReplyReceipt.family(key) == family, "\(key)") }
    #expect(!ReplyReceipt.types("k:r2", typed: ["k"]) && ReplyReceipt.types("k:r2", typed: ["k:r1"]) && ReplyReceipt.types("j", typed: ["k"]))
}

@Test func aHeldReplyHasMovedOnUnlessTheTurnItSawIsStillOne() {
    func flight(_ since: String?) -> ReplyFlight {
        ReplyFlight(session: "s", turn: "t", body: RemoteReply(text: "x"), at: 0, phase: .waiting, since: since)
    }
    #expect(flight(nil).movedOn(["t1"]) && flight(nil).movedOn([]))
    #expect(!flight("t1").movedOn(["t1", "f1"]))
    #expect(!flight("f1").movedOn(["t1", "f1"]))
    #expect(flight("t1").movedOn(["t2"]) && flight("t1").movedOn([]))
    #expect(!flight("status 7.0").movedOn(["status 7.0"]) && flight("status 7.0").movedOn(["status 8.0"]))
}

@Test func everyEventFromEveryFlightPhase() {
    typealias P = ReplyFlight.Phase
    let states: [P] = [.signing, .resigning, .queued(resigned: false), .queued(resigned: true), .unsent(reason: "Old."), .waiting]
    let events: [ReplyFlight.Event] = [.signed, .deferred, .unsent(reason: "No."), .resign, .unanswered, .send,
                                       .restored(inQueue: true), .restored(inQueue: false)]
    let lost = P.unsent(reason: "The Mac may not have it."), unconfirmed = P.unsent(reason: "Not confirmed."), no = P.unsent(reason: "No.")
    let table: [(P, [ReplyFlight.Event: P])] = [
        (.signing, [.signed: .queued(resigned: false), .deferred: .waiting, .unsent(reason: "No."): no,
                    .restored(inQueue: true): .queued(resigned: false), .restored(inQueue: false): unconfirmed]),
        (.resigning, [.signed: .queued(resigned: true), .unsent(reason: "No."): no,
                      .restored(inQueue: true): .queued(resigned: true), .restored(inQueue: false): unconfirmed]),
        (.queued(resigned: false), [.deferred: .waiting, .unsent(reason: "No."): no, .resign: .resigning, .unanswered: .waiting, .send: .signing,
                                    .restored(inQueue: true): .queued(resigned: false), .restored(inQueue: false): lost]),
        (.queued(resigned: true), [.unsent(reason: "No."): no, .unanswered: .waiting, .send: .signing,
                                   .restored(inQueue: true): .queued(resigned: true), .restored(inQueue: false): lost]),
        (.unsent(reason: "Old."), [.unsent(reason: "No."): no, .send: .signing,
                                   .restored(inQueue: true): .unsent(reason: "Old."), .restored(inQueue: false): .unsent(reason: "Old.")]),
        (.waiting, [.unsent(reason: "No."): no, .send: .signing, .restored(inQueue: true): .waiting, .restored(inQueue: false): .waiting]),
    ]
    #expect(table.map(\.0) == states)
    for (state, row) in table {
        for event in events { #expect(state.next(event) == row[event], "\(state) \(event)") }
    }
}
