import SideAProtocol
import Testing

private typealias A = ReplyAdmission

@Test func aReplyIsAdmittedWhileWhatItSawIsStillWhereTheSessionStands() {
    #expect(A.admits(seen: "t1", marks: ["t1", "f0"], working: true, chained: false))
    #expect(A.admits(seen: "f0", marks: ["t1", "f0"], working: false, chained: false))
    #expect(!A.admits(seen: "t0", marks: ["t1"], working: false, chained: false))
    #expect(A.admits(seen: "t0", marks: ["t1"], working: true, chained: true))
}

@Test func aStatusMarkIsAdmittedOnlyWhileTheSessionIsntWorking() {
    #expect(A.admits(seen: "status 5.0", marks: ["t1"], working: false, chained: false))
    #expect(!A.admits(seen: "status 5.0", marks: ["t1"], working: true, chained: false))
    #expect(!A.admits(seen: "status 5.0", marks: ["status 6.0"], working: true, chained: false))
    #expect(A.admits(seen: "status 5.0", marks: ["status 6.0"], working: false, chained: false))
}

@Test func withNoTurnNamedNowNothingSaysTheReplyMissedOne() {
    #expect(A.admits(seen: "t0", marks: [], working: true, chained: false))
    #expect(A.admits(seen: "t0", marks: ["status 6.0"], working: true, chained: false))
    #expect(!A.admits(seen: "t0", marks: ["status 6.0", "t1"], working: false, chained: false))
}

@Test func theChainIsAskedOnlyWhenTheMarksDontAlreadyAdmit() {
    var asked = 0
    func chained() -> Bool { asked += 1; return false }
    _ = A.admits(seen: "t1", marks: ["t1"], working: false, chained: chained())
    #expect(asked == 0)
    _ = A.admits(seen: "t0", marks: ["t1"], working: false, chained: chained())
    #expect(asked == 1)
}

@Test func theSendersOwnTurnChainsTheirNextReply() {
    let newest = (id: "t2", at: 100.0, text: "fix it")
    let mine = A.Earlier(at: 99, words: "fix it", turn: nil)
    #expect(A.chain([mine], newest: newest, sameWords: ==) == .claims(0))
    #expect(A.chain([mine], newest: (id: "t2", at: 97.0, text: "fix it"), sameWords: ==) == .claims(0))
    #expect(A.chain([mine], newest: (id: "t2", at: 96.9, text: "fix it"), sameWords: ==) == .none)
    #expect(A.chain([A.Earlier(at: 99, words: "fix it", turn: "t2")], newest: newest, sameWords: ==) == .known)
    #expect(A.chain([], newest: newest, sameWords: ==) == .none)
    #expect(A.chain([mine], newest: nil, sameWords: ==) == .none)
}

@Test func anotherTurnInBetweenBreaksTheChain() {
    let mine = A.Earlier(at: 99, words: "fix it", turn: nil)
    #expect(A.chain([mine], newest: (id: "t3", at: 120, text: "typed at the Mac"), sameWords: ==) == .none)
    #expect(A.chain([A.Earlier(at: 99, words: "fix it", turn: "t2")], newest: (id: "t3", at: 120, text: "fix it"), sameWords: ==) == .none)
    let both = [A.Earlier(at: 90, words: "first", turn: nil), A.Earlier(at: 99, words: "fix it", turn: nil)]
    #expect(A.chain(both, newest: (id: "t2", at: 100, text: "first"), sameWords: ==) == .claims(0))
    #expect(A.chain(both + [A.Earlier(at: 99.5, words: "x", turn: "t2")], newest: (id: "t2", at: 100, text: "first"), sameWords: ==) == .known)
}

@Test func anEarlierReplyIsKeptHalfAMinuteUntilItsTurnIsKnownThenAnHour() {
    #expect(A.keeps(age: 29.9, turnKnown: false) && !A.keeps(age: 30, turnKnown: false))
    #expect(A.keeps(age: 3599, turnKnown: true) && !A.keeps(age: 3600, turnKnown: true))
}
