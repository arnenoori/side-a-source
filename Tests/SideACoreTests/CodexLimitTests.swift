import Foundation
@testable import SideACore
import SideAProtocol
import Testing

private let now = 1_800_000_000.0

private func usage(fiveHour: Double, weekly: Double = 20, stale: Bool = false) -> AccountUsage {
    AccountUsage(windows: [UsageWindow(id: "five_hour", label: "5-hour", percent: fiveHour, resetsAt: now + 3600),
                           UsageWindow(id: "seven_day", label: "Weekly", percent: weekly, resetsAt: now + 86_400)], stale: stale)
}

@Test func codexsLimitErrorIsToldFromOtherErrors() {
    #expect(CodexLimit.stopped("You've hit your usage limit. Upgrade to Pro, or try again at 3:40 PM."))
    #expect(CodexLimit.stopped("usage_limit_reached"))
    #expect(!CodexLimit.stopped("stream disconnected before completion"))
    #expect(!CodexLimit.stopped("Rate limit reached for requests per minute"))
}

@Test func aCodexSessionWaitsForTheWindowItsAccountIsOutOf() {
    let limit = CodexLimit.limit(account: "a", usage: usage(fiveHour: 100), read: now, stoppedAt: now - 60, now: now)
    #expect(limit == SessionLimit(window: "five_hour", accountID: "a", until: now + 3600))
    let weekly = CodexLimit.limit(account: "a", usage: usage(fiveHour: 40, weekly: 100), read: now, stoppedAt: now - 60, now: now)
    #expect(weekly?.window == "seven_day")
    #expect(weekly?.until == now + 86_400)
}

@Test func aCodexSessionGoesOnOnceAReadingSinceItStoppedShowsRoom() {
    #expect(CodexLimit.limit(account: "a", usage: usage(fiveHour: 12), read: now, stoppedAt: now - 60, now: now) == nil)
    // The window it ran out of has reset, whatever the reading says it held.
    #expect(CodexLimit.limit(account: "a", usage: usage(fiveHour: 100), read: now, stoppedAt: now - 60, now: now + 3601) == nil)
}

@Test func aReadingFromBeforeTheStopIsNotTakenAsRoom() {
    let old = CodexLimit.limit(account: "a", usage: usage(fiveHour: 80), read: now - 600, stoppedAt: now - 60, now: now)
    #expect(old == SessionLimit(window: "five_hour", accountID: "a", until: now - 60 + 5 * 3600, worstCase: true))
    let none = CodexLimit.limit(account: "a", usage: nil, read: nil, stoppedAt: now - 60, now: now)
    #expect(none?.worstCase == true)
    let stale = CodexLimit.limit(account: "a", usage: usage(fiveHour: 10, stale: true), read: now, stoppedAt: now - 60, now: now)
    #expect(stale?.worstCase == true)
    // An old reading that already shows the account out names the real reset.
    let known = CodexLimit.limit(account: "a", usage: usage(fiveHour: 99), read: now - 600, stoppedAt: now - 60, now: now)
    #expect(known == SessionLimit(window: "five_hour", accountID: "a", until: now + 3600))
    #expect(CodexLimit.limit(account: "a", usage: nil, read: nil, stoppedAt: now - 6 * 3600, now: now) == nil)
    // A reading that names no window says nothing about room.
    #expect(CodexLimit.limit(account: "a", usage: AccountUsage(windows: []), read: now, stoppedAt: now - 60, now: now)?.worstCase == true)
}

@Test func aHeldSessionIsNotSentOnUntilItIsLetGo() {
    var stopped = StoppedSessions()
    stopped.hold("a", true)
    #expect(stopped.holds("a"))
    #expect(stopped.due(now: now, idle: ["a", "b"], lifted: ["a": now - 60, "b": now - 60]) { _ in true } == ["b"])
    stopped.hold("a", false)
    #expect(stopped.due(now: now + 1, idle: ["a", "b"], lifted: ["a": now - 60]) { _ in true } == ["a"])
}

@Test func aHoldEndsWhenTheSessionGoesOnOrGoes() throws {
    var stopped = StoppedSessions()
    stopped.hold("a", true)
    stopped.hold("gone", true)
    stopped.keepHolds(among: ["a", "other"])
    #expect(stopped.holds("a"))
    #expect(!stopped.holds("gone"))
    // Asking who is due, with nothing listed yet, forgets no hold.
    _ = stopped.due(now: now, idle: [], lifted: [:]) { _ in true }
    #expect(stopped.holds("a"))
    stopped.keepHolds(among: [])
    #expect(!stopped.holds("a"))
    // A file from before the choice existed still reads.
    let old = try JSONDecoder().decode(StoppedSessions.self, from: Data(#"{"refused":{},"moved":{},"asked":{}}"#.utf8))
    #expect(!old.holds("a"))
}
