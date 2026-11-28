import AppKit
import Foundation
@testable import SideA
import SideAProtocol
import SideASessionKit
import Testing

private func entry(_ id: String, _ kind: Switcher.Entry.Kind, _ title: String, fields: [String?] = []) -> Switcher.Entry {
    Switcher.Entry(id: id, kind: kind, title: title, fields: fields)
}

@Test func theSwitcherOpensOnWhatNeedsYouThenFiltersByAnythingKnown() {
    let running = [entry("w", .working, "Refactor billing", fields: ["shop"]), entry("n", .needsYou, "Fix login", fields: ["side-a", "Work"]),
                   entry("i", .idle, "Docs"), entry("r", .ready, "Ship it")]
    let past = (0..<20).map { entry("p\($0)", .past, "Old \($0)", fields: ["side-a"]) } + [entry("n", .past, "Fix login")]
    let actions = [entry("stop", .action, "Stop"), entry("pin", .action, "Pin")]
    // Empty: ⌘K ↩ goes to the next thing that needs you.
    let empty = Switcher.entries("", running: running, past: past, actions: actions)
    #expect(empty.prefix(4).map(\.id) == ["n", "r", "w", "i"] && empty.count == 4 + Switcher.recentShown && !empty.dropFirst(4).contains { $0.id == "n" })
    // Every word must be found, in the title or anything else known; then a way into full-text search.
    #expect(Switcher.entries("side login", running: running, past: past, actions: actions).map(\.id) == ["n", "search"])
    #expect(Switcher.entries("shop", running: running, past: past, actions: actions).map(\.id) == ["w", "search"])
    #expect(Switcher.entries("zzz", running: running, past: past, actions: actions).map(\.kind) == [.search])
    // ">" lists what can be done to the open session.
    #expect(Switcher.entries(">", running: running, past: past, actions: actions).map(\.id) == ["stop", "pin"])
    #expect(Switcher.entries("> pi", running: running, past: past, actions: actions).map(\.id) == ["pin"])
    #expect(Switcher.next(0, by: -1, count: 3) == 2 && Switcher.next(2, by: 1, count: 3) == 0 && Switcher.next(0, by: 1, count: 0) == 0)
}

@Test func commandAndShiftClicksPickSeveralRows() {
    let order = ["a", "b", "c", "d", "e"]
    func pick(_ picked: Set<String>, _ id: String, command: Bool = false, shift: Bool = false, open: String? = "b") -> Set<String> {
        SessionStore.picked(picked, clicking: id, command: command, shift: shift, open: open, order: order)
    }
    // A plain click lets the others go.
    #expect(pick(["a", "c"], "d").isEmpty)
    // ⌘ starts from the open conversation, adds and takes away.
    #expect(pick([], "d", command: true) == ["b", "d"])
    #expect(pick(["b", "d"], "e", command: true) == ["b", "d", "e"])
    #expect(pick(["b", "d", "e"], "d", command: true) == ["b", "e"])
    // Back down to only the open one is no selection at all.
    #expect(pick(["b", "d"], "d", command: true).isEmpty && pick([], "b", command: true).isEmpty)
    // ⇧ takes the run between the open one and the click, either way.
    #expect(pick([], "e", shift: true) == ["b", "c", "d", "e"] && pick([], "a", shift: true) == ["a", "b"])
    #expect(pick([], "e", shift: true, open: nil).isEmpty)
}

@Test func aConversationSettlesAfterAWeekAndAForkStaysWithItsTree() {
    let now = 100 * 86_400.0
    let day = 86_400.0
    #expect(Settled.isSettled(lastMessage: now - 8 * day, pinned: false, running: false, now: now))
    #expect(!Settled.isSettled(lastMessage: now - 6 * day, pinned: false, running: false, now: now))
    #expect(!Settled.isSettled(lastMessage: now - 30 * day, pinned: true, running: false, now: now))
    #expect(!Settled.isSettled(lastMessage: now - 30 * day, pinned: false, running: true, now: now))
    #expect(Settled.isSettled(lastMessage: now, pullRequestDone: true, pinned: false, running: false, now: now))
    #expect(!Settled.isSettled(lastMessage: nil, pinned: false, running: false, now: now))
    // An old conversation with a fresh fork is current; one whose whole tree is old has settled.
    let rows: [(id: String, last: Double?, depth: Int)] = [("old", now - 20 * day, 0), ("fork", now - day, 1), ("stale", now - 9 * day, 0),
                                                           ("stale-fork", now - 8 * day, 1), ("new", now, 0)]
    #expect(SessionStore.settle(rows, now: now) == ["stale", "stale-fork"])
}

@Test func snoozeChoicesEndWhenThePhonesDo() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = Date(timeIntervalSince1970: 1_800_000_000) // 01:20 UTC
    #expect(SessionSnooze.Choice.hour.until(from: now, calendar: calendar) == now.addingTimeInterval(3600))
    #expect(SessionSnooze.Choice.threeHours.until(from: now, calendar: calendar) == now.addingTimeInterval(10_800))
    let morning = try #require(SessionSnooze.Choice.morning.until(from: now, calendar: calendar))
    #expect(calendar.component(.hour, from: morning) == 9 && calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: morning).day == 1)
    #expect(SessionSnooze.Choice.needsMe.until(from: now, calendar: calendar) == nil)
    #expect(SessionSearch.matches("side fix", fields: ["Fix the login", nil, "side-a"]) && !SessionSearch.matches("side zzz", fields: ["Fix", "side-a"]))
}

private func idle(_ pid: Int, id: String, status: String = "idle") -> LiveSession {
    LiveSession(pid: pid, sessionID: id, name: nil, title: "Quiet", cost: nil, cwd: "/r/app", status: status, waitingFor: nil, since: nil)
}

@MainActor @Test func anIdleSessionsQuitWaitsOutItsUndoAndChecksAgain() async {
    let sessions = AccountStore(demo: true).sessions
    var quit: [Int] = []
    sessions.desk.quitNow = { session, _ in quit.append(session.pid) }
    // Undone: nothing is quit.
    sessions.live = [idle(1, id: "a"), idle(2, id: "b"), idle(3, id: "c")]
    sessions.requestQuit(sessions.live[0])
    #expect(sessions.desk.undo?.text == "Quitting “Quiet”" && sessions.quitting == nil)
    sessions.desk.takeBack()
    #expect(sessions.desk.quits[1] == nil && sessions.desk.undo == nil)
    // Started working while the undo ran: it is left alone.
    sessions.requestQuit(sessions.live[1])
    let busy = idle(2, id: "b", status: "busy")
    sessions.live = [idle(1, id: "a"), busy, idle(3, id: "c")]
    // Still idle when the time is up: it goes.
    sessions.requestQuit(sessions.live[2])
    #expect(await eventually { quit == [3] && sessions.desk.quits.isEmpty })
    // One that is working asks first, as before, with no undo.
    sessions.desk.undo = nil
    sessions.requestQuit(busy)
    #expect(sessions.quitting?.pid == 2 && sessions.desk.undo == nil)
    #expect(!SessionStore.quitsQuietly(busy) && SessionStore.quitsQuietly(idle(9, id: "z")))
}

@MainActor @Test func archiveAndUnpinCanBeTakenBack() {
    let sessions = AccountStore(demo: true).sessions
    let was = sessions.isArchived("x1")
    sessions.archive("x1")
    #expect(sessions.isArchived("x1") != was && sessions.desk.undo?.undo != nil)
    sessions.desk.takeBack()
    #expect(sessions.isArchived("x1") == was && sessions.desk.undo == nil)
    sessions.setPinned("x2", true)
    sessions.pin("x2")
    #expect(!sessions.isPinned("x2"))
    sessions.desk.takeBack()
    #expect(sessions.isPinned("x2"))
    sessions.setPinned("x2", false)
}

@MainActor @Test func aSnoozedSessionLeavesWorkingUntilItIsWoken() {
    let store = AccountStore(demo: true)
    let sessions = store.sessions
    sessions.listenForSnoozes()
    sessions.live = [idle(41, id: "s1", status: "busy"), idle(42, id: "s2")]
    let before = sessions.sidebar
    #expect(before.asleep.isEmpty)
    sessions.snooze(sessions.live[0], .needsMe)
    let after = sessions.sidebar
    #expect(after.asleep.map(\.pid) == [41] && !after.listed.working.contains { $0.pid == 41 } && sessions.desk.undo?.text == "Snoozed “Quiet”")
    #expect(sessions.snooze(of: sessions.live[0])?.choice == .needsMe && sessions.snooze(of: sessions.live[1]) == nil)
    // Undo wakes it.
    sessions.desk.takeBack()
    #expect(sessions.sidebar.asleep.isEmpty && sessions.snooze(of: sessions.live[0]) == nil)
    // Several at once, then all back.
    sessions.desk.picked = ["s1", "s2"]
    sessions.snoozePicked(.hour)
    #expect(sessions.sidebar.asleep.count == 2 && sessions.desk.picked.isEmpty)
    sessions.desk.takeBack()
    #expect(sessions.sidebar.asleep.isEmpty)
}
