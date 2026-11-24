import Foundation
@testable import SideACore
import Testing

private let now = 1_800_000_000.0

@Test func aRefusedSessionIsAskedOnceThePoolHasRoom() {
    var stopped = StoppedSessions()
    stopped.refuse("claude-1", .claude, at: now)
    stopped.refuse("codex-1", .codex, at: now)
    #expect(stopped.due(now: now + 60, idle: ["claude-1", "codex-1"]) { _ in false }.isEmpty)
    #expect(stopped.due(now: now + 120, idle: ["claude-1", "codex-1"]) { $0 == .claude } == ["claude-1"])
    #expect(stopped.due(now: now + 180, idle: ["claude-1", "codex-1"]) { $0 == .claude }.isEmpty)
    #expect(!stopped.isEmpty)
}

@Test func aSessionThatWentOnIsLeftAlone() {
    var stopped = StoppedSessions()
    stopped.refuse("served", .claude, at: now)
    stopped.refuse("busy", .claude, at: now)
    stopped.refuse("gone", .claude, at: now)
    stopped.served("served")
    #expect(stopped.due(now: now + 60, idle: ["served"], working: ["busy"]) { _ in true }.isEmpty)
    #expect(stopped.due(now: now + 120, idle: ["served", "busy"]) { _ in true } == ["busy"])
}

@Test func aMovedSessionWaitsForTheTradeToReachIt() {
    var stopped = StoppedSessions()
    stopped.move(["a", "b"], at: now)
    #expect(stopped.due(now: now + 30, idle: ["a", "b"]) { _ in false }.isEmpty)
    #expect(stopped.due(now: now + 60, idle: ["a"], working: ["b"]) { _ in false }.isEmpty)
    #expect(stopped.due(now: now + StoppedSessions.settle, idle: ["a", "b"]) { _ in false } == ["a"])
    stopped.delivered("a")
    #expect(stopped.isEmpty)
}

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

@Test func aStopStaysUntilItsMessageArrives() {
    var stopped = StoppedSessions()
    stopped.refuse("s", .claude, at: now)
    #expect(stopped.due(now: now, idle: ["s"]) { _ in true } == ["s"])
    #expect(!stopped.isEmpty && stopped.due(now: now + 60, idle: ["s"]) { _ in true }.isEmpty)
    #expect(stopped.due(now: now + StoppedSessions.again, idle: ["s"]) { _ in true } == ["s"])
    stopped.delivered("s")
    #expect(stopped.isEmpty)
}

@Test func aSessionThatNeverGetsPastItsStopIsNotAskedForEver() {
    var stopped = StoppedSessions()
    var asks = 0, at = now
    for _ in 0..<40 {
        asks += stopped.due(now: at, idle: ["s"], lifted: ["s": at - 5]) { _ in true }.count
        at += StoppedSessions.again
        if asks.isMultiple(of: StoppedSessions.attempts) { at += StoppedSessions.rest }
    }
    #expect(asks == StoppedSessions.ceiling, "\(asks)")
    #expect(stopped.counting)
    #expect(stopped.due(now: at, idle: ["s"]) { _ in true }.isEmpty)
    #expect(stopped.due(now: at + 60, idle: ["s"], lifted: ["s": at + 30]) { _ in true } == ["s"])
}
