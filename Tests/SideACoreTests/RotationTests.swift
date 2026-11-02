import Foundation
@testable import SideACore
import SideAProtocol
import Testing

private let now = 1_800_000_000.0
private let day = 86_400.0

private func account(_ name: String, priority: AccountPriority? = nil, auto: Bool = true) -> Account {
    Account(id: name, name: name, email: "\(name)@example.com", ready: true, allowAuto: auto, priority: priority)
}

private func usage(five: Double? = nil, week: Double? = nil, fable: Double? = nil, capacity: Double? = nil, stale: Bool = false, weekResets: Double = now + 3 * day) -> AccountUsage {
    var windows: [UsageWindow] = []
    if let five { windows.append(UsageWindow(id: "five_hour", label: "5-hour", percent: five, resetsAt: now + 3600)) }
    if let week { windows.append(UsageWindow(id: "seven_day", label: "Weekly", percent: week, resetsAt: weekResets)) }
    if let fable { windows.append(UsageWindow(id: "model:fable", label: "Weekly Fable", percent: fable, resetsAt: now + 2 * day)) }
    return AccountUsage(windows: windows, stale: stale, capacity: capacity)
}

/// Thirty days of the same activity every hour: the week's share is its share of the clock.
private let flat = WeekRhythm((0..<30).map { offset in
    ActivitySpan(date: Date(timeIntervalSince1970: now - Double(offset) * day).formatted(.iso8601.year().month().day()), hours: Array(repeating: 10, count: 24))
})!

@Test func limitedTakesBothTheMoveAtAndARealLimit() {
    // A low Move at leaves an account Autopilot skips, but it isn't limited yet.
    #expect(!Planner.isLimited(usage(five: 85), now: now, full: 80))
    // A high Move at keeps using it at 98, so Limited would be a lie there too.
    #expect(!Planner.isLimited(usage(five: 98), now: now, full: 99))
    #expect(Planner.isLimited(usage(five: 99), now: now, full: 99))
    #expect(Planner.isLimited(usage(week: 100), now: now, full: 95))
    // A window that already reset holds nothing.
    let spent = AccountUsage(windows: [UsageWindow(id: "five_hour", label: "5-hour", percent: 100, resetsAt: now - 1)])
    #expect(!Planner.isLimited(spent, now: now, full: 95))
}

@Test func aFableCapAloneIsFableOutNeverLimited() {
    let out = usage(five: 10, week: 20, fable: 100, capacity: 5)
    #expect(!Planner.isLimited(out, now: now, full: 95))
    #expect(Planner.isFableOut(out, now: now, full: 95))
    #expect(Planner.backAt(out, now: now, full: 95) == now + 2 * day)
    // A plan without a Fable cap bills it as extra usage instead.
    #expect(!Planner.isFableOut(usage(five: 10, week: 20, capacity: 1), now: now, full: 95))
    // Limited outright says only that.
    let both = usage(five: 100, week: 20, fable: 100, capacity: 5)
    #expect(Planner.isLimited(both, now: now, full: 95) && !Planner.isFableOut(both, now: now, full: 95))
    #expect(Planner.backAt(both, now: now, full: 95) == now + 3600)
    #expect(Planner.backAt(usage(five: 10), now: now, full: 95) == nil)
}

@Test func nextSkipsItselfBusyAccountsAndTheOnesAutopilotCantUse() {
    let work = account("Work"), personal = account("Personal"), off = account("Off", auto: false), busy = account("Busy"), last = account("Last", priority: .last)
    let values = ["Work": usage(five: 50), "Personal": usage(five: 10), "Off": usage(five: 1), "Busy": usage(five: 1), "Last": usage(five: 1)]
    let everyone = [work, personal, off, busy, last]
    #expect(Planner.next(after: work, among: everyone, usage: values, busy: ["Busy"], now: now) == "Personal")
    #expect(Planner.next(after: work, among: [work, off], usage: values, busy: [], now: now) == nil)
    #expect(Planner.next(after: work, among: [work, last], usage: values, busy: [], now: now) == "Last")
}

@Test func aMoveSaysWhichLimitWhyPriorityOrPace() {
    let work = account("Work"), personal = account("Personal", priority: .first), spare = account("Spare", priority: .last), other = account("Other")
    #expect(MoveReason.text(from: work, to: personal, usage: usage(five: 96.4), now: now, full: 95) == "5-hour 96%")
    #expect(MoveReason.text(from: work, to: personal, usage: usage(five: 10), now: now, full: 95) == "Personal goes first")
    #expect(MoveReason.text(from: spare, to: work, usage: usage(five: 10), now: now, full: 95) == "Spare goes last")
    #expect(MoveReason.text(from: work, to: other, usage: usage(five: 10), now: now, full: 95) == "Other's week runs out sooner")
}

@Test func combinedRunOutFallsWhereTheHoursSay() throws {
    let a = account("A"), b = account("B")
    // Half a week gone on both: 90 of 100 used on each is 180 a week each, 360 together, so the 20 left lasts about 9 hours.
    let tight = ["A": usage(week: 90, weekResets: now + 3.5 * day), "B": usage(week: 90, weekResets: now + 3.5 * day)]
    let out = try #require(CombinedRunOut.estimate([a, b], usage: tight, rhythm: flat, now: now))
    #expect(abs(out - (now + 20.0 / 360 * 7 * day)) < 3600)

    // A plan's size counts: Max is twenty Pros, so the same percentages on a mixed pair last just as long, not longer.
    let mixed = ["A": usage(week: 90, capacity: 20, weekResets: now + 3.5 * day), "B": usage(week: 90, capacity: 1, weekResets: now + 3.5 * day)]
    let weighted = try #require(CombinedRunOut.estimate([a, b], usage: mixed, rhythm: flat, now: now))
    #expect(abs(weighted - out) < 3600)

    // Slow use never empties them before quota comes back.
    let easy = ["A": usage(week: 30, weekResets: now + 3.5 * day), "B": usage(week: 10, weekResets: now + 3.5 * day)]
    #expect(CombinedRunOut.estimate([a, b], usage: easy, rhythm: flat, now: now) == nil)

    // A reset refills an account: the same burn outlives a pair whose first week ends soon.
    let refilled = ["A": usage(week: 95, weekResets: now + 0.1 * day), "B": usage(week: 60, weekResets: now + 3.5 * day)]
    let later = CombinedRunOut.estimate([a, b], usage: refilled, rhythm: flat, now: now)
    #expect(later.map { $0 > now + 0.1 * day } ?? true)

    // An account whose week hasn't started is all room and adds no pace.
    let fresh = ["A": usage(week: 90, weekResets: now + 3.5 * day), "B": usage()]
    let longer = try #require(CombinedRunOut.estimate([a, b], usage: fresh, rhythm: flat, now: now) ?? Optional(now + 8 * day))
    #expect(longer > out)
}

@Test func combinedRunOutHidesRatherThanGuesses() {
    let a = account("A"), b = account("B")
    let good = ["A": usage(week: 90, weekResets: now + 3.5 * day), "B": usage(week: 90, weekResets: now + 3.5 * day)]
    #expect(CombinedRunOut.estimate([a, b], usage: good, rhythm: flat, now: now) != nil)
    // No rhythm yet, no members, a member never read, a member signed out.
    #expect(CombinedRunOut.estimate([a, b], usage: good, rhythm: nil, now: now) == nil)
    #expect(CombinedRunOut.estimate([], usage: good, rhythm: flat, now: now) == nil)
    #expect(CombinedRunOut.estimate([a, b], usage: ["A": good["A"]!], rhythm: flat, now: now) == nil)
    #expect(CombinedRunOut.estimate([a, b], usage: ["A": good["A"]!, "B": usage(week: 90, stale: true, weekResets: now + 3.5 * day)], rhythm: flat, now: now) == nil)
    // Under a day of any week to read a pace from, and no use at all.
    #expect(CombinedRunOut.estimate([a], usage: ["A": usage(week: 80, weekResets: now + 6.5 * day)], rhythm: flat, now: now) == nil)
    #expect(CombinedRunOut.estimate([a], usage: ["A": usage(week: 0, weekResets: now + 3.5 * day)], rhythm: flat, now: now) == nil)
    // A burst a day into a week doesn't read as that pace for the whole week.
    let burst = CombinedRunOut.estimate([a], usage: ["A": usage(week: 50, weekResets: now + 5.9 * day)], rhythm: flat, now: now)
    #expect(burst.map { $0 > now + 1.5 * day } ?? true)
}

@Test func aRecordHoldsNamesAndFoldersOnly() throws {
    let record = RotationRecord(at: now, kind: .moved, from: "Work", to: "Personal", reason: "5-hour 96%", sessions: [.init(id: "s1", project: "side-a")])
    let text = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    #expect(try JSONDecoder().decode(RotationRecord.self, from: Data(text.utf8)) == record)
    #expect(!text.contains("title") && !text.contains("prompt"))
}

@Test func aRotationPushCarriesAccountsAndNumbersAndFitsTheBudget() throws {
    let payload = RemotePushPayload.rotation(title: "All out", body: nil, account: "Work", resetsAt: now, mac: "m", now: now)
    #expect(payload.t == "rotation" && payload.title == "All out" && payload.account == "Work" && payload.resetsAt == now)
    #expect(payload.sid == nil && payload.summary == nil && payload.plan == nil && payload.questions == nil)
    #expect(RemotePushPayload.encoded(payload).count <= PushPayload.budget)
}
