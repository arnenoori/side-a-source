import Foundation
@testable import SideA
import SideAProtocol
import Testing

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("side-a-drafts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor @Test func unsentMessagesComeBackAfterAQuit() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let drafts = SessionDrafts(root: root)
    #expect(drafts.load().isEmpty)
    drafts.write(["c1": "half a thought", "c2": "another"], now: 1_000)
    let file = root.appendingPathComponent(SessionDrafts.file)
    // Private to the user, as everything Side A keeps is.
    let mode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue & 0o077 == 0)
    #expect(SessionDrafts(root: root).load(now: 2_000) == ["c1": "half a thought", "c2": "another"])
    // One left for a month belongs to a conversation long finished.
    #expect(SessionDrafts(root: root).load(now: 1_000 + SessionDrafts.kept + 1).isEmpty)
    // Sent or cleared, nothing is left on disk.
    drafts.write([:])
    #expect(!FileManager.default.fileExists(atPath: file.path) && SessionDrafts(root: root).load().isEmpty)
    #expect(SessionDrafts.worthKeeping(["a": "  \n", "b": "", "c": "x"]) == ["c": "x"])
}

@MainActor @Test func typingIsWrittenOnceItStops() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let drafts = SessionDrafts(root: root)
    for text in ["h", "he", "hello"] { drafts.changed(["c1": text]) }
    #expect(await eventually { SessionDrafts(root: root).load()["c1"] == "hello" })
    drafts.changed(["c1": "   "])
    #expect(await eventually { SessionDrafts(root: root).load().isEmpty })
}

@MainActor @Test func typingToAnEndedConversationResumesItAsAStartingSession() throws {
    let store = AccountStore(demo: true)
    let sessions = store.sessions
    let json = #"{"id":"past-1","agent":"claude","title":"Old work","cwd":"/r/app"}"#
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let past = try decoder.decode(SessionInfo.self, from: Data(json.utf8))
    #expect(sessions.canContinue(past))
    sessions.drafts["past-1"] = "  pick this back up  "
    sessions.continueSession(past, with: sessions.drafts["past-1"] ?? "")
    let launch = try #require(sessions.desk.launches.first)
    #expect(launch.request.resume == "past-1" && launch.request.prompt == "pick this back up" && launch.request.cwd == "/r/app" && launch.request.agent == .claude)
    #expect(sessions.drafts["past-1"] == "" && sessions.desk.selectedLaunch == launch.id)
    // Nothing to send is nothing to resume.
    sessions.continueSession(past, with: "   ")
    #expect(sessions.desk.launches.count == 1)
    // One that is running is replied to, not resumed.
    var running = LiveSession(pid: 5, sessionID: "past-1", name: nil, title: nil, cost: nil, cwd: "/r/app", status: "busy", waitingFor: nil, since: nil)
    running.agent = "claude"
    sessions.live = [running]
    #expect(!sessions.canContinue(past))
    sessions.dismiss(launch.id)
}

@MainActor @Test func aBackgroundStartLeavesTheWindowWhereItWas() async {
    let store = AccountStore(demo: true)
    let sessions = store.sessions
    sessions.selectedID = "reading-this"
    sessions.launch(StartHosted(cwd: "/r/app", agent: .claude, prompt: "one"), terminal: false, select: false)
    sessions.launch(StartHosted(cwd: "/r/app", agent: .codex, prompt: "two"), terminal: false, select: false)
    #expect(sessions.desk.launches.map(\.title) == ["two", "one"] && sessions.desk.selectedLaunch == nil && sessions.selectedID == "reading-this")
    #expect(await eventually { sessions.desk.launches.allSatisfy { $0.hosted != nil } })
    // Each start has its own retry key, so one can be tried again without touching the other.
    #expect(Set(sessions.desk.launches.map(\.key)).count == 2)
    sessions.desk.launches.map(\.id).forEach(sessions.dismiss)
}

@MainActor @Test func sendingStraightAfterTypingLeavesNoDraftBehind() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let drafts = SessionDrafts(root: root)
    drafts.changed(["c1": "yes"])
    // Sent before the write went out: the write of the old words must not go.
    drafts.changed(["c1": ""])
    drafts.changed(["c2": "kept"])
    #expect(await eventually { SessionDrafts(root: root).load() == ["c2": "kept"] })
}
