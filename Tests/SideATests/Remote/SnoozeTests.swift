import Foundation
@testable import SideA
import SideACore
import Testing

private func row(_ status: SessionStatus = .working, requests: [RequestID] = [], turn: String? = "t1", flag: SessionFlag? = nil,
                 failure: SessionFailure? = nil) -> RemoteSession {
    var row = RemoteSession(id: "s1", agent: .claude, title: "Fix", project: "app", status: status, flag: flag, openRequests: requests, turnID: turn)
    row.failure = failure
    return row
}

@MainActor private func snoozes() -> Snoozes {
    Snoozes(url: FileManager.default.temporaryDirectory.appendingPathComponent("snoozes-\(UUID().uuidString).json"))
}

@MainActor
@Test func aSnoozeHidesNothingThatNeedsThePerson() {
    let store = snoozes()
    #expect(store.snooze(row(.waiting, requests: ["r1"]), .hour, until: Date().timeIntervalSince1970 + 3600) == nil)
    #expect(store.entries.isEmpty)

    let now = Date()
    let snoozed = row()
    #expect(store.snooze(snoozed, .threeHours, until: now.timeIntervalSince1970 + 3 * 3600, now: now) != nil)
    #expect(store.current(snoozed, now: now)?.choice == .threeHours)
    #expect(store.current(row(.idle), now: now) != nil && store.quiets("s1"))
    #expect(store.current(row(.waiting, requests: ["r1"]), now: now) == nil, "an open request wakes it")
    #expect(store.entries.isEmpty)
}

@MainActor
@Test(arguments: ["failure", "stuck", "time", "message"])
func eachEarlyWakeBringsItBack(_ cause: String) {
    let store = snoozes(), now = Date()
    store.snooze(row(), .morning, until: now.timeIntervalSince1970 + 3600, now: now)
    let woken: RemoteSession
    var at = now
    switch cause {
    case "failure": woken = row(failure: SessionFailure(kind: .contextFull, message: "Too long", retryable: false))
    case "stuck": woken = row(flag: SessionFlag(kind: .stuck, text: "No progress for 20 min"))
    case "time": woken = row(); at = now.addingTimeInterval(3601)
    default: woken = row(.working, turn: "t2")
    }
    #expect(store.current(woken, now: at) == nil)
    #expect(store.current(row(), now: at) == nil, "it stays awake")
}

@MainActor
@Test func untilItNeedsMeWakesWhenItFinishes() {
    let store = snoozes()
    store.snooze(row(), .needsMe, until: 123)
    #expect(store.current(row())?.until == nil && !store.quiets("s1"))
    #expect(store.current(row(.idle)) == nil)

    store.snooze(row(.idle), .needsMe, until: nil)
    #expect(store.current(row(.idle)) != nil)
    store.wake("s1")
    #expect(store.current(row(.idle)) == nil)
}

@MainActor
@Test func snoozesOutliveARestart() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("snoozes-\(UUID().uuidString).json")
    Snoozes(url: url).snooze(row(), .hour, until: Date().timeIntervalSince1970 + 3600)
    #expect(Snoozes(url: url).current(row())?.choice == .hour)
    try? FileManager.default.removeItem(at: url)
}
