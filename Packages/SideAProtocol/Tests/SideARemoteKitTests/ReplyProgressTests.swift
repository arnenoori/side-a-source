import Foundation
import SideAProtocol
@testable import SideARemoteKit
import Testing

// Every (state, event) pair of `ReplyProgress`, against the invariants in docs/remote/reply-progress.md.

private typealias P = ReplyProgress

private let states: [P] = P.Stage.allCases.flatMap { stage in
    [false, true].flatMap { overdue in
        (stage == .takingBack ? [P.Stage.note, .queued] : [nil]).map { P(stage, overdue: overdue, before: $0) }
    }
}

/// What a fresh message can come to.
private let reachable: Set<P> = {
    var seen: Set<P> = [P()], frontier = [P()]
    while let state = frontier.popLast() {
        for event in P.Event.allCases {
            guard let next = state.next(event), seen.insert(next).inserted else { continue }
            frontier.append(next)
        }
    }
    return seen
}()

@Test func everyPairIsDecided() {
    var moved = 0
    for state in states { for event in P.Event.allCases where state.next(event) != nil { moved += 1 } }
    #expect(states.count == 20)
    #expect(reachable.isSubset(of: Set(states)))
    #expect(moved > 0)
}

@Test func noStageIsADeadEnd() {
    for state in reachable where !state.settled {
        #expect(P.Event.allCases.contains { state.next($0).map { $0.stage != state.stage } ?? false }, "\(state) has no way out")
    }
}

@Test func everyStateReachesASettledOne() {
    for start in reachable {
        var seen: Set<P> = [start], frontier = [start], settles = start.settled
        while !settles, let state = frontier.popLast() {
            for event in P.Event.allCases {
                guard let next = state.next(event), seen.insert(next).inserted else { continue }
                if next.settled { settles = true }
                frontier.append(next)
            }
        }
        #expect(settles, "\(start) never settles")
    }
}

/// Unsettled, a message either runs out of patience or waits on something the user can change from the bubble.
@Test func nothingWaitsWithoutATimeOrAWayOut() {
    for state in reachable where !state.settled {
        let actions = state.actions(interrupts: true).filter { $0 != .copy }
        #expect(P.patience(state.stage) != nil || !actions.isEmpty, "\(state) waits forever")
        guard state.overdue else { continue }
        // Overdue, the Mac can still end it on its own, or the bubble offers a way out.
        let macEnds = [P.Event.refused, .dropped, .read].contains { state.next($0)?.settled == true }
        #expect(macEnds || !actions.isEmpty, "\(state) is overdue with nothing to do")
    }
    let held = P(.held).next(.overdue)
    #expect(held?.overdue == true && held?.actions(interrupts: true).contains(.interruptAndSend) == true)
    #expect(P(.held).actions(interrupts: true) == [.copy], "Interrupt and Send waits for the message to be overdue")
    // Typed and never taken, Esc has nothing to put back; the Mac's own check gives it back instead.
    #expect(P(.sent).next(.overdue)?.actions(interrupts: true) == [.copy] && P(.sent).next(.dropped)?.stage == .unsent)
}

@Test func aMessageIsNeverDeliveredAndInTheField() {
    for state in states {
        #expect(!(state.delivered && state.textInField))
    }
    // Once read, nothing gives it back or moves it again.
    for event in P.Event.allCases {
        #expect(P(.read).next(event) == nil, "read takes \(event)")
        #expect(P(.withdrawn).next(event) == nil, "withdrawn takes \(event)")
        #expect(P(.read, overdue: true).next(event) == nil)
    }
    for stage in P.Stage.allCases { #expect(!P.moves(.read, to: stage) || stage == .read) }
}

@Test func takeBackIsOfferedOnlyWhereItCanWork() {
    for state in states {
        let offered = !Set(state.actions(interrupts: true)).isDisjoint(with: [.edit, .delete])
        let works = state.next(.takeBack)?.stage == .takingBack
        #expect(offered == works, "\(state): offered \(offered), works \(works)")
        guard works, let taking = state.next(.takeBack) else { continue }
        #expect(taking.next(.takenBack)?.stage == .withdrawn)
        #expect(taking.next(.tooLate)?.stage == .read)
        #expect(taking.next(.keptBack)?.stage == state.stage, "a failed Take Back leaves it where it was")
        #expect(taking.next(.overdue)?.stage == state.stage)
    }
}

@Test func retryIsOnlyForWhatCameBack() {
    for state in states {
        #expect((state.next(.retry) != nil) == (state.stage == .unsent))
        #expect(state.actions(interrupts: true).contains(.retry) == (state.stage == .unsent))
    }
}

@Test func interruptAndSendIsOnlyForWhatTheAgentHoldsUnread() {
    for state in states where state.actions(interrupts: true).contains(.interruptAndSend) {
        #expect(state.stage == .held && state.overdue)
    }
    for state in states { #expect(!state.actions(interrupts: false).contains(.interruptAndSend)) }
}

@Test func theStoreMovesOnlyAlongTheTable() {
    #expect(P.moves(.sending, to: .sent) && P.moves(.sent, to: .held) && P.moves(.held, to: .read))
    #expect(P.moves(.takingBack, to: .queued) && P.moves(.takingBack, to: .note))
    #expect(!P.moves(.held, to: .sent), "a late `typed` answer doesn't undo a receipt")
    #expect(!P.moves(.read, to: .held) && !P.moves(.unsent, to: .read) && !P.moves(.withdrawn, to: .sending))
}

/// The phone, the link and the Mac together: answers can be lost, the user retries what came back, and the Mac types a
/// key only when `ReplyReceipt.types` says. Every interleaving up to eight steps types the message at most once.
@Test func aRetryNeverTypesTwice() {
    struct World: Hashable {
        var phone = P()
        var key = "k"
        var tries = 0
        var typed: Set<String> = []
        var typings = 0
        /// The request reached the Mac; its answer hasn't reached the phone.
        var inFlight = false
    }
    enum Step: CaseIterable { case arrive, answer, lose, retry, receipt }
    var frontier = [World()], seen: Set<World> = [World()]
    for _ in 0..<8 {
        var next: [World] = []
        for world in frontier {
            for step in Step.allCases {
                var w = world
                switch step {
                case .arrive:
                    guard w.phone.stage == .sending, !w.inFlight else { continue }
                    if ReplyReceipt.types(w.key, typed: w.typed) { w.typings += 1; w.typed.insert(ReplyReceipt.family(w.key)) }
                    w.inFlight = true
                case .answer:
                    guard w.inFlight, let moved = w.phone.next(.typed) else { continue }
                    w.phone = moved; w.inFlight = false
                case .lose:
                    guard w.phone.stage == .sending, let moved = w.phone.next(.refused) else { continue }
                    w.phone = moved; w.inFlight = false
                case .retry:
                    guard let moved = w.phone.next(.retry) else { continue }
                    w.tries += 1
                    w.phone = moved; w.key = "k:r\(w.tries)"
                case .receipt:
                    guard w.typed.contains(ReplyReceipt.family(w.key)), let moved = w.phone.next(.held) else { continue }
                    w.phone = moved
                }
                #expect(w.typings <= 1, "typed twice: \(w)")
                if seen.insert(w).inserted { next.append(w) }
            }
        }
        frontier = next
    }
    #expect(seen.contains { $0.tries >= 2 })
    #expect(ReplyReceipt.family("a:r12") == "a" && ReplyReceipt.family("a:allow:a3") == "a:allow:a3")
}
