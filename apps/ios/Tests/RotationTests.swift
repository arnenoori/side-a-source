import SideAProtocol
import XCTest
@testable import SideARemote

@MainActor
final class RotationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var t: Double { now.timeIntervalSince1970 }

    private func account(_ windows: [UsageWindow], capacity: Double? = nil, provider: AgentProvider = .claude, limited: Bool? = nil,
                         fableOut: Bool? = nil, backAt: Double? = nil, issue: AccountIssue? = nil) -> RemoteAccount {
        RemoteAccount(id: "a", name: "Work", provider: provider, ready: true, usage: AccountUsage(windows: windows, capacity: capacity),
                      limited: limited, fableOut: fableOut, backAt: backAt, issue: issue)
    }

    private func window(_ id: String, _ percent: Double) -> UsageWindow { UsageWindow(id: id, label: id, percent: percent, resetsAt: t + 3600) }

    func testWaitingSaysWhoIsBackAndWhen() {
        let back = Date(timeIntervalSince1970: t + 600)
        let time = back.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(RotationText.waiting(count: 3, summary: WaitingSummary(account: "Work", at: t + 600), now: now), "3 waiting · Work back \(time)")
        XCTAssertEqual(RotationText.waiting(count: 1, summary: WaitingSummary(account: "Work", at: t + 600, worstCase: true), now: now), "1 waiting · Work back by \(time)")
        XCTAssertEqual(RotationText.waiting(count: 2, summary: nil, now: now), "2 waiting")
        XCTAssertEqual(RotationText.waiting(count: 2, summary: WaitingSummary(account: "Work", at: t - 1), now: now), "2 waiting")
    }

    func testNextIsAnEstimateAndNamesTheLoginWhenThereAreSeveral() {
        XCTAssertEqual(RotationText.next(NextMove(id: "a", from: "Work", to: "Personal", atPercent: 95, minutes: 40), several: false), "Next: Personal · at 95% · ~40m")
        XCTAssertEqual(RotationText.next(NextMove(id: "a", from: "Work", to: "Personal", atPercent: 95), several: false), "Next: Personal · at 95%")
        XCTAssertEqual(RotationText.next(NextMove(id: "a", from: "Work", to: "Personal", atPercent: 95, minutes: 80), several: true), "Work → Personal · at 95% · ~1h 20m")
        XCTAssertEqual(RotationText.next(NextMove(id: "a", from: "Work", to: nil, atPercent: 95, minutes: 40), several: false), "Next: none free")
        XCTAssertEqual(RotationText.next(NextMove(id: "a", from: "Work", to: "Personal", atPercent: 95, held: true), several: false), "Next: Personal · after a pause")
    }

    func testRoomLeavesOutADateItDoesNotHave() {
        let room = UsageOutlook.Room(provider: .claude, accounts: 2, weeklyLeft: 41, runsOut: t + 3 * 86_400)
        let day = Date(timeIntervalSince1970: t + 3 * 86_400).formatted(.dateTime.weekday(.abbreviated))
        XCTAssertEqual(RotationText.room(room, named: false, now: now), "41% left · runs out \(day)")
        XCTAssertEqual(RotationText.room(room, named: true, now: now), "\(AgentProvider.claude.title) 41% left · runs out \(day)")
        XCTAssertEqual(RotationText.room(.init(provider: .claude, accounts: 2, weeklyLeft: 41), named: false, now: now), "41% left")
        XCTAssertEqual(RotationText.room(.init(provider: .claude, accounts: 2, weeklyLeft: 0, runsOut: t - 1), named: false, now: now), "0% left")
    }

    func testPlanBadgeIsForAPlanBiggerThanProAndNeverCodex() {
        XCTAssertEqual(RotationText.plan(account([], capacity: 5)), "5x")
        XCTAssertEqual(RotationText.plan(account([], capacity: 20)), "20x")
        XCTAssertNil(RotationText.plan(account([], capacity: 1)))
        XCTAssertNil(RotationText.plan(account([])))
        XCTAssertNil(RotationText.plan(account([], capacity: 5, provider: .codex)))
    }

    /// With a Mac that serves `limited`, a Fable cap alone isn't "Limited", and neither is a 98% window Autopilot still uses.
    func testLimitedFollowsTheMacsPlanner() {
        let capped = account([window("five_hour", 10), window("model:fable", 100)], limited: false, fableOut: true, backAt: t + 3600)
        XCTAssertFalse(capped.limited(at: now))
        XCTAssertTrue(capped.fableOut(at: now))
        XCTAssertEqual(capped.binding(at: now)?.id, "five_hour")
        XCTAssertFalse(capped.needsAttention(at: now))
        XCTAssertTrue(capped.needsAttention(at: now, fableMode: true))

        XCTAssertFalse(account([window("five_hour", 98)], limited: false).limited(at: now))
        XCTAssertTrue(account([window("five_hour", 100)], limited: true, backAt: t + 60).limited(at: now))
        // Past the moment the Mac said it ends, the phone stops saying so, connected or not.
        XCTAssertFalse(account([window("five_hour", 100)], limited: true, backAt: t - 60).limited(at: now))
        XCTAssertFalse(account([window("model:fable", 100)], limited: false, fableOut: true, backAt: t - 60).fableOut(at: now))
    }

    /// An older Mac serves no verdict, so the phone reads the percentages as it always did.
    func testAnOlderMacKeepsTheOldReading() {
        let old = account([window("five_hour", 10), window("model:fable", 100)])
        XCTAssertTrue(old.limited(at: now))
        XCTAssertEqual(old.binding(at: now)?.id, "model:fable")
        XCTAssertTrue(old.needsAttention(at: now))
        XCTAssertFalse(old.fableOut(at: now))
    }

    func testIssuesSayWhatsWrongInAFewWords() throws {
        let ends = Date(timeIntervalSince1970: t + 2 * 86_400)
        let day = ends.formatted(.dateTime.weekday(.abbreviated))
        let soon = try XCTUnwrap(RotationText.issue(AccountIssue(kind: .signInEnds, endsAt: ends.timeIntervalSince1970), now: now))
        XCTAssertEqual(soon.text, "Sign-in ends \(day)")
        XCTAssertFalse(soon.alarm)
        XCTAssertEqual(RotationText.issue(AccountIssue(kind: .signInEnds, endsAt: t - 1), now: now)?.text, "Sign-in ended")
        XCTAssertEqual(RotationText.issue(AccountIssue(kind: .signIn), now: now)?.alarm, true)
        XCTAssertEqual(RotationText.issue(AccountIssue(kind: .replaced, replacedBy: "Other"), now: now)?.text, "Login replaced by Other")
        XCTAssertEqual(RotationText.issue(AccountIssue(kind: .signedOut), now: now)?.text, "Signed out")
        XCTAssertNil(RotationText.issue(AccountIssue(kind: .init(rawValue: "future")), now: now))
        XCTAssertTrue(account([], issue: AccountIssue(kind: .signIn)).needsAttention(at: now))
    }

    func testAWaitingSessionStopsWaitingAtItsReset() {
        var session = RemoteSession(id: "s", agent: .claude, title: "t", project: "p", status: .idle)
        XCTAssertFalse(session.waitingOnLimit(at: now))
        session.limit = SessionLimit(window: "five_hour", accountID: "a", until: t + 60)
        XCTAssertTrue(session.waitingOnLimit(at: now))
        session.limit = SessionLimit(window: "five_hour", accountID: "a", until: t - 60)
        XCTAssertFalse(session.waitingOnLimit(at: now))
        session.limit = SessionLimit(window: "five_hour", accountID: "a")
        XCTAssertTrue(session.waitingOnLimit(at: now))
    }

    func testARotationPushNamesWhatHappened() {
        let moved = PushPayload(t: "rotation", mac: "m", sent: 1, title: "Now on Personal", body: "5-hour 96%")
        XCTAssertEqual(PushOpener.body(moved), "5-hour 96%")
        let out = PushPayload(t: "rotation", mac: "m", sent: 1, title: "All out", account: "Work", resetsAt: t)
        XCTAssertEqual(PushOpener.body(out), "Work back \(now.formatted(date: .omitted, time: .shortened))")
    }

    func testADemoChangeWorksWithoutAMac() async throws {
        let tools = MacTools(.demo(.init(options: OptionsList(agents: []), projects: [], autopilot: AutopilotState(enabled: true, swapAt: 95, followFable: true))))
        XCTAssertTrue(tools.can(.rotation))
        try await tools.setSwapAt(90)
        try await tools.setFollowFable(false)
        XCTAssertEqual(tools.autopilot?.swapAt, 90)
        XCTAssertEqual(tools.autopilot?.followFable, false)
        XCTAssertFalse(MacTools().can(.rotation))
    }

    func testPrefsCarryTheRotationToggleOffByDefault() {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: "notify.rotation") }
        defaults.removeObject(forKey: "notify.rotation")
        XCTAssertEqual(NotificationPrefs.stored(for: "studio").rotation, false)
        defaults.set(true, forKey: "notify.rotation")
        XCTAssertEqual(NotificationPrefs.stored(for: "studio").rotation, true)
    }
}
