import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

private let conversation = "a06442e2-3f6b-4a35-931a-a4599bfa8acd"
private let hasTmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }

/// How the session ran before the move: on a pinned account, a model and an effort, in a mode that doesn't ask.
private let asItRan = "['--resume', '\(conversation)', '--model', 'opus', '--effort', 'high', '--permission-mode', 'bypassPermissions']"

@MainActor
private func pinnedSession(_ laptop: Computer) async throws -> LiveSession {
    laptop.model = "opus"
    laptop.effort = "high"
    laptop.moves.seat = { _ in Moves.Seat(pin: "work") }
    return try await laptop.startSession()
}

@MainActor
private func journal(_ computer: Computer) -> URL { computer.moves.folder.appendingPathComponent("journal.json") }

/// The app quit with the move at `step`: what it wrote then is what the next launch reads.
@MainActor
private func relaunch(_ computer: Computer, from saved: Data?, at step: MoveJournal.Step) throws -> Moves {
    let saved = try #require(saved)
    #expect(try JSONDecoder().decode(MoveJournal.self, from: saved).all.first?.step == step)
    try saved.write(to: journal(computer))
    return computer.makeMoves()
}

@MainActor @Test(.enabled(if: hasTmux))
func aMoveUndoneAfterTheSessionWasHeldStartsItAsItRanAndSoDoesTheNextLaunch() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let session = try await pinnedSession(laptop)
        var held: Data?
        peer.duringPart = { if held == nil { held = FileManager.default.contents(atPath: journal(laptop).path) } }
        peer.lose = .stageAnswer
        await #expect(throws: MoveFailure.self) { _ = try await laptop.moves.send(session, to: peer) }
        #expect(await eventually { laptop.agentAlive && laptop.arguments == asItRan })
        #expect(laptop.pin == "work")

        // The app quit while the session was stopped for the move; started again, it finds that in the journal.
        try await laptop.hosted.end(try #require(laptop.live().first?.hosted))
        #expect(await eventually { !laptop.agentAlive })
        try FileManager.default.removeItem(at: laptop.fixture.submitted.appendingPathExtension("args"))
        let relaunched = try relaunch(laptop, from: held, at: .held)
        await relaunched.settle()
        #expect(await eventually { laptop.agentAlive && laptop.arguments != nil })
        #expect(laptop.arguments == asItRan)
        #expect(laptop.pin == "work")
        #expect(relaunched.ownership(of: conversation) == .here)
        #expect(!mini.agentAlive)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aMoveTheNextLaunchUndoesAfterTheOtherComputerHeldTheFilesStartsTheSessionAsItRan() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let (here, _) = accounts(laptop, mini)
        let session = try await pinnedSession(laptop)
        var sent: Data?
        // The login is taken out of use only once the other computer holds the rest: the journal says `sent` by then.
        here.onHold = { sent = FileManager.default.contents(atPath: journal(laptop).path) }
        peer.lose = .commitRequest
        await #expect(throws: MoveFailure.unknown(peer: "Mac mini")) { _ = try await laptop.moves.send(session, to: peer) }
        #expect(!laptop.agentAlive && !mini.agentAlive)

        // The app quit before it asked the mini to start it.
        let relaunched = try relaunch(laptop, from: sent, at: .sent)
        relaunched.logins = here
        peer.lose = nil
        relaunched.peer = { _ in peer }
        await relaunched.settle()
        #expect(await eventually { laptop.agentAlive })
        #expect(laptop.arguments == asItRan)
        #expect(laptop.pin == "work")
        #expect(here.events == ["hold", "restore"])
        #expect(relaunched.ownership(of: conversation) == .here)
        // The copy the mini held is gone, and nothing of it runs there.
        #expect(!mini.agentAlive && mini.transcripts().isEmpty)
        #expect(mini.moves.state(try #require(relaunched.journal.all.first?.id)).status == .discarded)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

/// The pure half: what a source entry says comes back, and what was never recorded starts on the defaults.
@MainActor @Test func aRestartUsesOnlyWhatThisComputerRecordedOfTheSession() {
    let settings = MoveJournal.Restart(pin: nil, codexAccount: "acct-1", model: "gpt-5", effort: "high", permissionMode: "dangerFullAccess")
    let codex = Moves.restart("t1", as: settings, agent: .codex, cwd: "/code/app")
    #expect(codex.mode == .resume("t1", model: "gpt-5") && codex.codexAccount == "acct-1" && codex.pin == nil)
    #expect(codex.effort == "high" && codex.permissionMode == "dangerFullAccess" && codex.origin == "move")
    // A mode the agent can't start in is left out rather than refused.
    #expect(Moves.restart("t1", as: MoveJournal.Restart(permissionMode: "plan"), agent: .codex, cwd: "/code/app").permissionMode == nil)
    let bare = Moves.restart("c1", as: nil, agent: .claude, cwd: "/code/app")
    #expect(bare.mode == .resume("c1") && bare.pin == nil && bare.effort == nil && bare.permissionMode == nil)

    var row = LiveSession(pid: 1, sessionID: "c1", name: nil, title: nil, cost: nil, cwd: "/code/app", status: "idle", waitingFor: nil, since: nil)
    row.model = "--dangerous"; row.effort = "max"; row.mode = "auto"
    let read = Moves.restart(of: row, seat: Moves.Seat(pin: "studio"))
    #expect(read == MoveJournal.Restart(pin: "studio", model: nil, effort: "max", permissionMode: "auto"))
}

@MainActor @Test(.enabled(if: hasTmux))
func aLoginTheOtherComputerCannotConfirmIsNotStoredThereAndComesBackHere() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let (here, there) = accounts(laptop, mini)
        there.refuses = "That login belongs to another account."
        let session = try await laptop.startSession()
        // Another account there can run it, as the laptop was told: the session moves, and the login stays here.
        let state = try await laptop.moves.send(session, to: peer)
        #expect(state.status == .live && state.account == nil)
        #expect(here.events == ["hold", "restore"])
        #expect(there.stored.isEmpty)
        #expect(await eventually { mini.agentAlive })
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aLoginThatCantBeConfirmedWhereNothingElseCanRunItKeepsTheSessionHere() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let (here, there) = accounts(laptop, mini)
        there.any = false
        there.refuses = "Side A couldn't confirm that the login that came is Work's, so it wasn't stored."
        let session = try await laptop.startSession()
        await #expect(throws: MoveFailure.self) { _ = try await laptop.moves.send(session, to: peer) }
        #expect(here.events == ["hold", "restore"])
        #expect(there.stored.isEmpty)
        #expect(await eventually { laptop.agentAlive })
        #expect(!mini.agentAlive)
        #expect(laptop.moves.ownership(of: conversation) == .here && mini.moves.ownership(of: conversation) == .here)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}
