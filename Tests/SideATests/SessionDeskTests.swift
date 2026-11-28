import Foundation
@testable import SideA
import SideAProtocol
import Testing

@Test func backAndForwardWalkTheConversationsOpened() {
    var trail = Trail()
    #expect(trail.back() == nil && trail.forward() == nil && !trail.canGoBack)
    for id in ["a", "b", "c"] { trail.visit(id) }
    #expect(trail.current == "c" && trail.previous == "b" && trail.canGoBack && !trail.canGoForward)
    #expect(trail.back() == "b" && trail.back() == "a" && trail.back() == nil)
    #expect(trail.forward() == "b" && trail.canGoForward)
    // Opening one from the middle of the history drops what was ahead, as a browser does.
    trail.visit("d")
    #expect(trail.ids == ["a", "b", "d"] && trail.forward() == nil && trail.previous == "b")
    // Opening the one already open is not a visit.
    trail.visit("d")
    #expect(trail.ids == ["a", "b", "d"] && trail.previous == "b")
}

@Test func theLastSessionTogglesBetweenTwo() {
    var trail = Trail()
    trail.visit("a")
    trail.visit("b")
    #expect(trail.previous == "a")
    trail.visit("a")
    #expect(trail.previous == "b")
    // Back changes what "last" is too, so it always names the one just left.
    #expect(trail.back() == "b" && trail.previous == "a")
}

@Test func aConversationThatIsGoneLeavesTheHistory() {
    var trail = Trail()
    for id in ["a", "b", "c", "b"] { trail.visit(id) }
    trail.forget("b")
    #expect(trail.ids == ["a", "c"] && trail.previous == "c")
    #expect(trail.current == "c" && trail.back() == "a")
    trail.forget("missing")
    #expect(trail.ids == ["a", "c"])
}

@Test func theHistoryKeepsOnlyTheLastFifty() {
    var trail = Trail()
    for index in 0..<(Trail.kept + 10) { trail.visit("s\(index)") }
    #expect(trail.ids.count == Trail.kept && trail.ids.first == "s10" && trail.current == "s\(Trail.kept + 9)")
}

@Test func theNextSessionThatNeedsYouWrapsAndSkipsNothing() {
    #expect(SessionStore.next(after: nil, in: []) == nil)
    #expect(SessionStore.next(after: nil, in: ["a", "b"]) == "a")
    #expect(SessionStore.next(after: "a", in: ["a", "b"]) == "b")
    #expect(SessionStore.next(after: "b", in: ["a", "b"]) == "a")
    // The open one isn't among them: start at the top.
    #expect(SessionStore.next(after: "z", in: ["a", "b"]) == "a")
    // It is the only one: there is nowhere else to go.
    #expect(SessionStore.next(after: "a", in: ["a"]) == nil)
    #expect(SessionStore.unique(["a", "b", "a", "c", "b"]) == ["a", "b", "c"])
}

@Test func aNewSessionStartsWhereTheLastOneDid() {
    var saved = SessionPrefs.Start()
    #expect(SessionPrefs.Start.folder(saved, open: nil, among: ["/r/one", "/r/two"]) == "/r/one")
    saved.record(StartHosted(cwd: "/r/two", agent: .codex, model: "gpt-5", effort: "high", worktree: true, accountID: "work"), at: 5)
    #expect(saved.folder == "/r/two" && saved.agent == "codex")
    #expect(saved.agents["codex"] == .init(model: "gpt-5", effort: "high", account: "work"))
    #expect(saved.folders["/r/two"] == .init(agent: "codex", worktree: true, used: 5))
    #expect(SessionPrefs.Start.folder(saved, open: nil, among: ["/r/one", "/r/two"]) == "/r/two")
    // The conversation that is open decides, when its folder is one that can be started in.
    #expect(SessionPrefs.Start.folder(saved, open: "/r/one", among: ["/r/one", "/r/two"]) == "/r/one")
    #expect(SessionPrefs.Start.folder(saved, open: "/r/gone", among: ["/r/one", "/r/two"]) == "/r/two")
    // A folder that has since gone falls back to the most recent, and to nothing when there are none.
    #expect(SessionPrefs.Start.folder(saved, open: nil, among: ["/r/one"]) == "/r/one")
    #expect(SessionPrefs.Start.folder(saved, open: nil, among: []).isEmpty)
    // Each agent keeps its own model: going back to Claude does not bring Codex's.
    saved.record(StartHosted(cwd: "/r/one", agent: .claude, model: "opus"))
    #expect(saved.agents["codex"]?.model == "gpt-5" && saved.agents["claude"]?.model == "opus" && saved.agents["claude"]?.effort.isEmpty == true)
}

@Test func rememberedFoldersStayBounded() {
    var saved = SessionPrefs.Start()
    // Recorded in an order that is not alphabetical, so only age can explain which ones go.
    let count = SessionPrefs.Start.foldersKept + 5
    for index in 0..<count { saved.record(StartHosted(cwd: "/r/\(count - index)", agent: .claude), at: Double(index)) }
    #expect(saved.folders.count == SessionPrefs.Start.foldersKept)
    #expect(saved.folders["/r/1"] != nil && saved.folders["/r/\(count)"] == nil && saved.folders["/r/\(count - 4)"] == nil && saved.folders["/r/\(count - 5)"] != nil)
}

@Test func theWindowsChoicesSurviveARestart() {
    let defaults = temporaryDefaults()
    let prefs = SessionPrefs(defaults: defaults)
    #expect(prefs.sidebarWidth == SessionPrefs.sidebarDefault && !prefs.sidebarHidden && prefs.start == .init())
    prefs.sidebarWidth = 400
    prefs.sidebarHidden = true
    var start = prefs.start
    start.record(StartHosted(cwd: "/r/app", agent: .claude, model: "opus"))
    prefs.start = start
    let again = SessionPrefs(defaults: defaults)
    #expect(again.sidebarWidth == 400 && again.sidebarHidden && again.start.folder == "/r/app")
    // A width from a build with other limits is brought back inside them.
    defaults.set(9_000.0, forKey: SessionPrefs.sidebarWidthKey)
    #expect(again.sidebarWidth == SessionPrefs.sidebarRange.upperBound)
}

@MainActor @Test func theDeskRemembersTheSidebarItWasGiven() {
    let defaults = temporaryDefaults()
    let desk = SessionDesk(prefs: SessionPrefs(defaults: defaults))
    desk.sidebarWidth = 280
    desk.sidebarHidden = true
    #expect(SessionPrefs(defaults: defaults).sidebarWidth == 280 && SessionPrefs(defaults: defaults).sidebarHidden)
    desk.visited("a")
    desk.visited(nil)
    desk.visited("b")
    #expect(desk.previous == "a" && desk.canGoBack && desk.back() == "a" && desk.canGoForward)
}
