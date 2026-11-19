import Foundation
@testable import SideACore
import Testing

private let now = 1_800_000_000.0

/// The pool refused a conversation with every account out: it's asked once an account has room, and only once.
@Test func aRefusedSessionIsAskedOnceThePoolHasRoom() {
    var stopped = StoppedSessions()
    stopped.refuse("claude-1", .claude, at: now)
    stopped.refuse("codex-1", .codex, at: now)
    #expect(stopped.due(now: now + 60, idle: ["claude-1", "codex-1"]) { _ in false }.isEmpty)
    #expect(stopped.due(now: now + 120, idle: ["claude-1", "codex-1"]) { $0 == .claude } == ["claude-1"])
    #expect(stopped.due(now: now + 180, idle: ["claude-1", "codex-1"]) { $0 == .claude }.isEmpty)
    #expect(!stopped.isEmpty)
}

/// A session that found an account by itself, is mid-turn, or is gone gets nothing typed into it.
@Test func aSessionThatWentOnIsLeftAlone() {
    var stopped = StoppedSessions()
    stopped.refuse("served", .claude, at: now)
    stopped.refuse("busy", .claude, at: now)
    stopped.refuse("gone", .claude, at: now)
    stopped.served("served")
    #expect(stopped.due(now: now + 60, idle: ["served"], working: ["busy"]) { _ in true }.isEmpty)
    // Still waiting when its turn ends.
    #expect(stopped.due(now: now + 120, idle: ["served", "busy"]) { _ in true } == ["busy"])
}

/// A login trade takes a minute to reach running sessions, and one the user sent on meanwhile isn't asked.
@Test func aMovedSessionWaitsForTheTradeToReachIt() {
    var stopped = StoppedSessions()
    stopped.move(["a", "b"], at: now)
    #expect(stopped.due(now: now + 30, idle: ["a", "b"]) { _ in false }.isEmpty)
    #expect(stopped.due(now: now + 60, idle: ["a"], working: ["b"]) { _ in false }.isEmpty)
    #expect(stopped.due(now: now + StoppedSessions.settle, idle: ["a", "b"]) { _ in false } == ["a"])
    stopped.delivered("a")
    #expect(stopped.isEmpty)
}

/// A session that stops again right away is not asked in a loop, the count starts over after a rest, and a stop
/// from over a week ago is the user's.
@Test func asksAreSpacedCappedAndForgotten() {
    var stopped = StoppedSessions()
    let lifted = { (at: Double) in ["s": at] }
    #expect(stopped.due(now: now, idle: ["s"], lifted: lifted(now - 10)) { _ in false } == ["s"])
    #expect(stopped.due(now: now + 60, idle: ["s"], lifted: lifted(now + 30)) { _ in false }.isEmpty)
    #expect(stopped.due(now: now + StoppedSessions.again, idle: ["s"], lifted: lifted(now + 30)) { _ in false } == ["s"])
    #expect(stopped.due(now: now + 2 * StoppedSessions.again, idle: ["s"], lifted: lifted(now + 1000)) { _ in false } == ["s"])
    #expect(stopped.due(now: now + 3 * StoppedSessions.again, idle: ["s"], lifted: lifted(now + 2000)) { _ in false }.isEmpty)
    let later = now + 2 * StoppedSessions.again + StoppedSessions.rest
    #expect(stopped.due(now: later, idle: ["s"], lifted: lifted(later - 5)) { _ in false } == ["s"])

    var old = StoppedSessions()
    old.refuse("pool", .claude, at: now)
    #expect(old.due(now: now + StoppedSessions.forget, idle: ["pool", "limit"], lifted: ["limit": now]) { _ in true }.isEmpty)
    #expect(old.isEmpty)
}

/// A message that couldn't be delivered leaves the stop in place for the next try; one that was settles it.
@Test func aStopStaysUntilItsMessageArrives() {
    var stopped = StoppedSessions()
    stopped.refuse("s", .claude, at: now)
    #expect(stopped.due(now: now, idle: ["s"]) { _ in true } == ["s"])
    #expect(!stopped.isEmpty && stopped.due(now: now + 60, idle: ["s"]) { _ in true }.isEmpty)
    #expect(stopped.due(now: now + StoppedSessions.again, idle: ["s"]) { _ in true } == ["s"])
    stopped.delivered("s")
    #expect(stopped.isEmpty)
}
