import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

private let conversation = Computer.conversationID
private let hasTmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }

/// The mini knows a login as the account the fake calls it by once it holds it.
extension FakeLogins {
    func account(_ id: String) -> MoveAccount? { running?.id == id ? running?.wire : nil }
}

/// The laptop's session moved to the mini and runs there.
@MainActor
private func arrived(_ laptop: Computer, _ mini: Computer, _ peer: LocalPeer) async throws -> LiveSession {
    _ = try await laptop.moves.send(try await laptop.startSession(), to: peer)
    #expect(await eventually { mini.agentAlive && !mini.live().isEmpty })
    return try #require(mini.live().first)
}

/// The person quits the agent there (or it crashes): its pane ends, and Side A's hosted session with it.
@MainActor
private func agentExits(_ computer: Computer, _ session: LiveSession) async throws {
    try #require(kill(pid_t(session.pid), SIGTERM) == 0)
    #expect(await eventually {
        await computer.hosted.refresh()
        return !computer.agentAlive && computer.hosted.sessions.isEmpty
    })
}

@MainActor
private func journal(_ computer: Computer) -> URL { computer.moves.folder.appendingPathComponent("journal.json") }

@MainActor @Test(.enabled(if: hasTmux))
func aSessionWhoseAgentExitedWhereItArrivedComesBackWithItsLaterWorkAndItsLogin() async throws {
    let (laptop, mini, peer) = try await pair()
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moves-\(UUID().uuidString)")
    do {
        let (here, there) = accounts(laptop, mini)
        let session = try await arrived(laptop, mini, peer)
        // The mini holds the login that came with it now.
        there.running = ("new", MoveAccount(email: "you@example.com", name: "Work"))
        // Work there after it arrived, not committed, and more of the conversation.
        let landed = try #require(session.cwd)
        try "three\n".write(toFile: landed + "/tracked.txt", atomically: true, encoding: .utf8)
        try "{\"type\":\"user\"}\n{\"type\":\"assistant\"}\n".write(toFile: try #require(mini.transcripts().first), atomically: true, encoding: .utf8)
        try await agentExits(mini, session)

        let ended = try #require(await mini.moves.ended(conversation))
        #expect(ended.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == URL(fileURLWithPath: landed).resolvingSymlinksInPath().path)
        #expect(ended.hosted == session.hosted)
        #expect(ended.mode == "default" && ended.status == "idle" && ended.pid == 0)
        #expect(mini.moves.ended(conversation, running: mini.live())?.hosted == session.hosted)
        // The phone's route finds it by its conversation: what is missing is the computer, not the session.
        let store = AccountStore(demo: true, root: folder)
        store.remote.moves = mini.moves
        let path = "v1/sessions/\(conversation)/move/preview"
        let request = HTTPRequest(method: "POST", target: "/" + path, path: path.split(separator: "/").map(String.init), query: [:], headers: HTTPHeaders([]),
                                  body: try JSONEncoder().encode(MoveRequest(computer: "nowhere")))
        let answer = await RemoteRoutes.route(request, RemoteServer.Caller(device: "phone", connection: 1), store.remote)
        let code = (try JSONSerialization.jsonObject(with: answer.body) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["code"] as? String }
        #expect(answer.status == 404 && code == "not_found")

        // The preview stops nothing and starts nothing.
        let home = LocalPeer(laptop)
        let preview = try await mini.moves.preview(ended, to: home)
        #expect(preview.landing?.contains("/app") == true && preview.login == .sent)
        #expect(!mini.agentAlive && !laptop.agentAlive && there.events == ["receive you@example.com"])

        // A move that fails on the way starts nothing on either computer, and the mini still holds it to move.
        home.lose = .stageAnswer
        await #expect(throws: MoveFailure.refused("MacBook couldn't be reached, so the session stayed here.")) { _ = try await mini.moves.send(ended, to: home) }
        await mini.hosted.refresh()
        #expect(!mini.agentAlive && mini.hosted.sessions.isEmpty && !laptop.agentAlive)
        #expect(mini.moves.ownership(of: conversation) == .here && mini.transcripts().count == 1)
        #expect(mini.moves.journal.all.filter { $0.role == .source }.map(\.step) == [.returned])
        #expect(await mini.moves.ended(conversation) != nil)

        // Bring Back.
        home.lose = nil
        let back = try await mini.moves.send(ended, to: home)
        #expect(back.status == .live && back.account == "you@example.com")
        #expect(await eventually { laptop.agentAlive })
        #expect(!mini.agentAlive)
        #expect(laptop.arguments?.hasPrefix("['--resume', '\(conversation)'") == true)
        let landedHome = try #require(laptop.cwd)
        #expect(landedHome.contains("/app/.sidea-worktrees/sa-app-"))
        #expect(try String(contentsOfFile: landedHome + "/tracked.txt", encoding: .utf8) == "three\n")
        #expect(try String(contentsOfFile: landedHome + "/untracked.txt", encoding: .utf8) == "new\n")
        #expect(try String(contentsOfFile: try #require(laptop.transcripts().first), encoding: .utf8).hasSuffix("{\"type\":\"assistant\"}\n"))
        // The login went back with it: out of use and then deleted on the mini, stored on the laptop.
        #expect(there.events == ["receive you@example.com", "hold", "release to MacBook"])
        #expect(here.events == ["hold", "release to Mac mini", "receive you@example.com"])

        // The mini holds nothing it could run, and both journals say where it is.
        #expect(mini.transcripts().isEmpty)
        #expect(await mini.moves.ended(conversation) == nil)
        #expect(mini.moves.ownership(of: conversation) == .away(peer: "MacBook"))
        #expect(mini.moves.journal.all.filter { $0.role == .destination }.map(\.step) == [.gone])
        #expect(mini.moves.journal.all.filter { $0.role == .source }.map(\.step) == [.returned, .away])
        #expect(laptop.moves.ownership(of: conversation) == .here)
        #expect(laptop.moves.journal.all.filter { $0.role == .source }.map(\.step) == [.returned])
        // The preview's offer and the move that failed were dropped there; the last one runs.
        #expect(laptop.moves.journal.all.filter { $0.role == .destination }.map(\.step) == [.discarded, .discarded, .live])
    } catch { Issue.record(error) }
    try? FileManager.default.removeItem(at: folder)
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func anEndedSessionWhoseFolderIsGoneIsRefusedAndNothingChanges() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let (here, there) = accounts(laptop, mini)
        let session = try await arrived(laptop, mini, peer)
        try await agentExits(mini, session)
        try FileManager.default.removeItem(atPath: try #require(session.cwd))
        let ended = try #require(await mini.moves.ended(conversation))
        let before = (mini.moves.journal, laptop.moves.journal)

        let gone = MoveFailure.refused("The folder it ran in on Mac mini is gone, so it can't move.")
        await #expect(throws: gone) { _ = try await mini.moves.preview(ended, to: LocalPeer(laptop)) }
        await #expect(throws: gone) { _ = try await mini.moves.send(ended, to: LocalPeer(laptop)) }
        await #expect(throws: gone) { _ = try await mini.moves.request(ended, to: LocalPeer(laptop), when: .afterTurn) }
        #expect(mini.moves.journal == before.0 && laptop.moves.journal == before.1)
        #expect(mini.moves.claimed.isEmpty && mini.moves.waiting.isEmpty)
        #expect(here.events == ["hold", "release to Mac mini"] && there.events == ["receive you@example.com"])
        #expect(mini.transcripts().count == 1 && !mini.agentAlive && !laptop.agentAlive)
        #expect(mini.moves.ownership(of: conversation) == .here && laptop.moves.ownership(of: conversation) == .away(peer: "Mac mini"))
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func anArrivedSessionThatStillRunsIsStoppedBeforeItMovesOn() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let session = try await arrived(laptop, mini, peer)
        #expect(await mini.moves.ended(conversation) == nil)
        #expect(mini.moves.ended(conversation, running: mini.live()) == nil)
        // Nothing that stands in for it moves it while it runs.
        let standIn = Moves.standIn(conversation, try #require(mini.moves.arrival(of: conversation)?.incoming))
        let home = LocalPeer(laptop)
        await #expect(throws: MoveFailure.refused("That session isn't running on Mac mini.")) { _ = try await mini.moves.prepare(standIn, to: home) }
        #expect(mini.agentAlive)

        let plan = try await mini.moves.prepare(session, to: home)
        #expect(plan.ended == nil && plan.session.pid == session.pid)
        _ = try await mini.moves.run(plan, to: home)
        #expect(await eventually { laptop.agentAlive })
        #expect(!mini.agentAlive)
        #expect(mini.moves.journal.all.first { $0.role == .source }?.ended == nil)
        #expect(mini.moves.ownership(of: conversation) == .away(peer: "MacBook") && laptop.moves.ownership(of: conversation) == .here)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

/// The app quit while it carried an ended session: the next launch undoes the move and starts nothing, because nothing ran.
@MainActor @Test(.enabled(if: hasTmux))
func anEndedSessionsMoveUndoneAfterARelaunchStartsNothing() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let (_, there) = accounts(laptop, mini)
        let session = try await arrived(laptop, mini, peer)
        there.running = ("new", MoveAccount(email: "you@example.com", name: "Work"))
        try await agentExits(mini, session)
        let ended = try #require(await mini.moves.ended(conversation))
        let home = LocalPeer(laptop)
        var held: Data?
        home.duringPart = { if held == nil { held = FileManager.default.contents(atPath: journal(mini).path) } }
        home.lose = .stageAnswer
        await #expect(throws: MoveFailure.self) { _ = try await mini.moves.send(ended, to: home) }

        let saved = try #require(held)
        let entry = try #require(try JSONDecoder().decode(MoveJournal.self, from: saved).all.first { $0.role == .source })
        #expect(entry.step == .held && entry.ended != nil && entry.restart?.pin == "new")
        try saved.write(to: journal(mini))
        mini.moves = mini.makeMoves()
        mini.moves.logins = there
        mini.moves.peer = { _ in home }
        home.lose = nil
        await mini.moves.settle()
        await mini.hosted.refresh()
        #expect(mini.moves.journal[entry.id]?.step == .returned)
        #expect(!mini.agentAlive && mini.hosted.sessions.isEmpty)
        #expect(mini.moves.ownership(of: conversation) == .here && mini.transcripts().count == 1)
        #expect(await mini.moves.ended(conversation) != nil)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}
