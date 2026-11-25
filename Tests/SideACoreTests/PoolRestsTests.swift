import Foundation
@testable import SideACore
import Testing

private let now = 1_800_000_000.0

private func usage(five: Double? = nil, week: Double, weekReset: Double = now + 3 * 86_400) -> AccountUsage {
    var windows = [UsageWindow(id: "seven_day", label: "Weekly", percent: week, resetsAt: weekReset)]
    if let five { windows.append(UsageWindow(id: "five_hour", label: "5-hour", percent: five, resetsAt: now + 3600)) }
    return AccountUsage(windows: windows)
}

@Test func aWeeklyLimitEmptiedDaysBeforeItsResetIsAnEarlyReset() {
    #expect(Planner.resetEarly(before: usage(week: 100), after: usage(week: 0, weekReset: now + 7 * 86_400), now: now) == ["seven_day"])
    #expect(Planner.resetEarly(before: usage(five: 100, week: 50), after: usage(five: 2, week: 50), now: now) == ["five_hour"])
}

@Test func ordinaryChangesAreNotEarlyResets() {
    #expect(Planner.resetEarly(before: usage(week: 60), after: usage(week: 0), now: now).isEmpty)
    #expect(Planner.resetEarly(before: usage(week: 100), after: usage(week: 90), now: now).isEmpty)
    #expect(Planner.resetEarly(before: usage(week: 100, weekReset: now - 10), after: usage(week: 0), now: now).isEmpty)
    #expect(Planner.resetEarly(before: usage(week: 100, weekReset: now + 300), after: usage(week: 0), now: now).isEmpty)
    #expect(Planner.resetEarly(before: nil, after: usage(week: 0), now: now).isEmpty)
}

@Test func onlyAReadingTakenAfterALimitRestBeganEndsIt() {
    var rests = PoolRests()
    rests.rest("backoff", until: now + 600, at: now)
    let r0 = rests.end("backoff", readAt: now + 5, now: now + 10)
    #expect(!r0)
    rests.rest("a", until: now + 86_400, at: now, limit: true)
    let r1 = rests.end("a", readAt: now - 5, now: now + 10)
    #expect(!r1)
    #expect(rests["a"] == now + 86_400)
    let r2 = rests.end("a", readAt: now + 5, now: now + 10)
    #expect(r2)
    #expect(rests["a"] == nil && rests.since["a"] == nil)
    let r3 = rests.end("a", readAt: now + 20, now: now + 30)
    #expect(!r3)
}

@Test func aProbeTriesTheSoonestLongRestOnceAPeriodAndOneAccountAMinute() {
    var rests = PoolRests()
    rests.rest("short", until: now + 600, at: now - 120)
    let freeAt = ["short": now + 600, "week": now + 3 * 86_400, "day": now + 86_400]
    let r4 = rests.probe(freeAt, now: now)
    #expect(r4 == "day")
    let r5 = rests.probe(freeAt, now: now + 30)
    #expect(r5 == nil)
    let r6 = rests.probe(freeAt, now: now + 61)
    #expect(r6 == "week")
    let r7 = rests.probe(freeAt, now: now + 130)
    #expect(r7 == nil)
    let r8 = rests.probe(freeAt, now: now + PoolRests.probeEvery + 1)
    #expect(r8 == "day")
}

@Test func aRestJustSetIsNotProbedAtOnce() {
    var rests = PoolRests()
    rests.rest("a", until: now + 86_400, at: now)
    let r9 = rests.probe(["a": now + 86_400], now: now + 10)
    #expect(r9 == nil)
    let r10 = rests.probe(["a": now + 86_400], now: now + 61)
    #expect(r10 == "a")
}
