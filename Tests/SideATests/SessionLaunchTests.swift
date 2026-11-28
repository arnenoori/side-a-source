import Foundation
@testable import SideA
import SideAProtocol
import Testing

private func live(_ pid: Int, hosted: String?, id: String?) -> LiveSession {
    var session = LiveSession(pid: pid, sessionID: id, name: nil, title: nil, cost: nil, cwd: "/r/app", status: "busy", waitingFor: nil, since: nil)
    session.hosted = hosted
    return session
}

@Test func aStartingRowIsNamedForItsPromptOrItsFolder() {
    #expect(Launch.title(prompt: "Fix the login bug\nand add a test", folder: "/r/app") == "Fix the login bug")
    #expect(Launch.title(prompt: "  \n", folder: "/r/app") == "app")
    #expect(Launch.title(prompt: nil, folder: "/r/side-a") == "side-a")
    let long = String(repeating: "word ", count: 40)
    #expect(Launch.title(prompt: long, folder: "/r/app").count == 80 && Launch.title(prompt: long, folder: "/r/app").hasSuffix("…"))
}

@Test func aLaunchIsItsSessionOnceTheMacListsItWithAConversation() {
    var launch = Launch(id: UUID(), request: StartHosted(cwd: "/r/app", agent: .claude), key: "k", terminal: false, at: .now)
    // Before the launcher answers there is no name to match, whatever runs.
    #expect(launch.listed(in: [live(1, hosted: "sa-app-1a2b", id: "c1")]) == nil)
    launch.hosted = "sa-app-1a2b"
    #expect(launch.listed(in: [live(1, hosted: "sa-other-9z", id: "c9")]) == nil)
    // Listed, but the agent hasn't a conversation yet: still starting.
    #expect(launch.listed(in: [live(1, hosted: "sa-app-1a2b", id: nil)]) == nil)
    #expect(launch.listed(in: [live(2, hosted: "sa-other-9z", id: "c9"), live(1, hosted: "sa-app-1a2b", id: "c1")]) == "c1")
}

@Test func theGraceRunsFromTheLaunchersAnswerAndEndsOnce() {
    let now = Date()
    var launch = Launch(id: UUID(), request: StartHosted(cwd: "/r/app", agent: .claude), key: "k", terminal: false, at: now.addingTimeInterval(-500))
    // A launcher that is slow to answer is not a session that failed to appear.
    #expect(!launch.expired(at: now))
    launch.bootedAt = now.addingTimeInterval(-(Launch.grace - 1))
    #expect(!launch.expired(at: now))
    launch.bootedAt = now.addingTimeInterval(-Launch.grace)
    #expect(launch.expired(at: now))
    launch.state = .failed("It hasn't started.")
    #expect(!launch.expired(at: now) && launch.settled && launch.failure == "It hasn't started.")
    #expect(Launch.look(after: .seconds(1)) < Launch.look(after: .seconds(60)))
}

@MainActor @Test func startShowsTheSessionBeforeAnythingHasStarted() async {
    let store = AccountStore(demo: true)
    let sessions = store.sessions
    sessions.selectedID = "earlier"
    sessions.launch(StartHosted(cwd: "/r/app", agent: .claude, prompt: "Fix the login bug"), terminal: false)
    // Synchronously, before the launcher has been asked: the row exists and the window shows it.
    #expect(sessions.desk.launches.count == 1)
    let launch = sessions.desk.launches[0]
    #expect(launch.state == .launching && launch.hosted == nil && launch.title == "Fix the login bug")
    #expect(sessions.desk.selectedLaunch == launch.id && sessions.selectedID == nil && sessions.desk.selected?.id == launch.id)
    #expect(sessions.desk.shownLaunches(live: sessions.live).map(\.id) == [launch.id])
    #expect(await eventually { sessions.desk.launches.first?.state == .booting && sessions.desk.launches.first?.hosted != nil })
    sessions.dismiss(launch.id)
    #expect(sessions.desk.launches.isEmpty && sessions.desk.selectedLaunch == nil)
}

@MainActor @Test func theWindowFollowsAStartingSessionIntoItsConversation() async throws {
    let store = AccountStore(demo: true)
    let sessions = store.sessions
    sessions.launch(StartHosted(cwd: "/r/app", agent: .claude), terminal: false)
    let id = try #require(sessions.desk.launches.first?.id)
    #expect(await eventually { sessions.desk.launches.first?.hosted != nil })
    let name = try #require(sessions.desk.launches.first?.hosted)
    sessions.desk.held[id] = "and then run the tests"
    // The Mac lists it without a conversation first: the launch stays, and stays the only row for it.
    sessions.live.append(live(4242, hosted: name, id: nil))
    #expect(sessions.desk.shownLaunches(live: sessions.live).count == 1)
    sessions.live = sessions.live.filter { $0.pid != 4242 } + [live(4242, hosted: name, id: "conversation-1")]
    // From that moment the list shows the session's own row, not both.
    #expect(sessions.desk.shownLaunches(live: sessions.live).isEmpty)
    #expect(await eventually { sessions.desk.launches.isEmpty })
    #expect(sessions.selectedID == "conversation-1" && sessions.desk.selectedLaunch == nil)
    // What was typed while it started is waiting in its message field.
    #expect(sessions.drafts["conversation-1"] == "and then run the tests" && sessions.desk.held.isEmpty)
}

@MainActor @Test func aSessionThatStartsWhileAnotherIsOpenDoesNotTakeTheWindow() async throws {
    let store = AccountStore(demo: true)
    let sessions = store.sessions
    sessions.launch(StartHosted(cwd: "/r/app", agent: .claude), terminal: false)
    #expect(await eventually { sessions.desk.launches.first?.hosted != nil })
    let name = try #require(sessions.desk.launches.first?.hosted)
    // The user went elsewhere while it booted.
    sessions.desk.selectedLaunch = nil
    sessions.selectedID = "elsewhere"
    sessions.live.append(live(4243, hosted: name, id: "conversation-2"))
    #expect(await eventually { sessions.desk.launches.isEmpty })
    #expect(sessions.selectedID == "elsewhere")
}

@MainActor @Test func aFailedStartKeepsItsRowAndGoesBackToTheSheetToBeEdited() {
    let store = AccountStore(demo: true)
    let sessions = store.sessions
    let request = StartHosted(cwd: "/r/app", agent: .codex, model: "gpt-5", prompt: "Try this")
    sessions.desk.launches = [Launch(id: UUID(), request: request, key: "k", terminal: false, state: .failed("That folder no longer exists."), at: .now)]
    let id = sessions.desk.launches[0].id
    #expect(sessions.desk.shownLaunches(live: []).first?.failure == "That folder no longer exists.")
    sessions.edit(id)
    #expect(sessions.desk.launches.isEmpty && sessions.creating && sessions.desk.seed == request)
}

@MainActor @Test func aTrustQuestionReachesTheStartingRowWithRemoteOff() async throws {
    let store = AccountStore(demo: true)
    let sessions = store.sessions
    sessions.launch(StartHosted(cwd: "/r/app", agent: .claude), terminal: false)
    let id = try #require(sessions.desk.launches.first?.id)
    #expect(await eventually { sessions.desk.launches.first?.hosted != nil })
    let name = try #require(sessions.desk.launches.first?.hosted)
    // Remote never started in this store, so the window's own listener is the only one.
    #expect(store.hosted.attentionListeners.keys.sorted() == [SessionStore.attentionListener])
    store.hosted.onAttention?(name, .init(kind: "trust", text: "Do you trust the files in this folder?"))
    #expect(sessions.desk.launches.first?.state == .attention(kind: "trust", text: "Do you trust the files in this folder?"))
    // A reply that may not have gone in is about a running session, not a start.
    store.hosted.onAttention?(name, .init(kind: "unsent", text: "It may not have been sent."))
    #expect(sessions.desk.launches.first?.state == .attention(kind: "trust", text: "Do you trust the files in this folder?"))
    // Remote's listener joins the window's; it does not replace it.
    store.hosted.onAttention = { _, _ in }
    #expect(store.hosted.attentionListeners.count == 2)
    sessions.dismiss(id)
}
