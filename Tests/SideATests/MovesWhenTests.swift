import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

private let hasTmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }

/// Notes how it was started, as the idle agent does, and notes an Esc, which stops a working agent's turn.
private let stoppableAgent = """
#!/usr/bin/env python3
import os, sys, tty
out = "__OUT__"
open(out + ".args", "w").write(repr(sys.argv[1:]))
open(out + ".cwd", "w").write(os.getcwd())
open(out + ".pid", "w").write(str(os.getpid()))
tty.setcbreak(0)
sys.stdout.write("working\\n")
sys.stdout.flush()
while True:
    key = os.read(0, 1)
    if not key:
        sys.exit(0)
    if key == b"\\x1b":
        open(out + ".escaped", "w").write("1")
"""

/// Puts the agent that notices Esc where `computer` starts its sessions from; returns the file it writes on one.
@MainActor
private func stoppable(_ computer: Computer) throws -> URL {
    let agent = computer.fixture.base.appendingPathComponent("bin/claude")
    try stoppableAgent.replacingOccurrences(of: "__OUT__", with: computer.fixture.submitted.path).write(to: agent, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
    return computer.fixture.submitted.appendingPathExtension("escaped")
}

/// Two computers, the laptop's session working and its waiting moves looked at often.
@MainActor
private func working() async throws -> (Computer, Computer, LocalPeer) {
    let (laptop, mini, peer) = try await pair()
    laptop.status = { "busy" }
    laptop.moves.peer = { _ in peer }
    laptop.moves.watchEvery = .milliseconds(50)
    return (laptop, mini, peer)
}

private let conversation = Computer.conversationID

@MainActor @Test(.enabled(if: hasTmux))
func aMoveAfterThisTurnWaitsForTheTurnToEndAndThenGoesOnce() async throws {
    let (laptop, mini, peer) = try await working()
    do {
        let session = try await laptop.startSession()
        await #expect(throws: MoveFailure.refused("It's working. Move it when it has finished its turn.")) { _ = try await laptop.moves.send(session, to: peer) }
        // Nothing there can take it yet: refused at once, and nothing is remembered.
        mini.moves.accepts = { false }
        await #expect(throws: MoveFailure.self) { _ = try await laptop.moves.request(session, to: peer, when: .afterTurn) }
        #expect(laptop.moves.waiting.isEmpty)
        mini.moves.accepts = { true }

        let record = try await laptop.moves.request(session, to: peer, when: .afterTurn)
        #expect(record.state == .waiting && record.computerName == "Mac mini" && record.title == "Fix the login redirect" && record.project == "app")
        #expect(laptop.moves.records().map(\.id) == [record.id])
        await #expect(throws: MoveFailure.refused("It's already waiting to move.")) { _ = try await laptop.moves.request(session, to: peer, when: .now) }
        // While it works, passes move nothing and stop nothing.
        await laptop.moves.checkWaiting()
        await laptop.moves.checkWaiting()
        #expect(laptop.agentAlive && laptop.live().first?.pid == session.pid && !mini.agentAlive)
        #expect(laptop.moves.journal.all.isEmpty && laptop.moves.ownership(of: conversation) == .here)

        // The turn ends: it goes by itself, under the id it was given.
        laptop.status = { "idle" }
        #expect(await eventually { laptop.moves.record(record.id)?.state == .away })
        // Away before the copy left here is parked; the request is done once that is too.
        #expect(await eventually { mini.agentAlive && laptop.moves.waiting.isEmpty })
        #expect(!laptop.agentAlive && laptop.moves.ownership(of: conversation) == .away(peer: "Mac mini"))
        #expect(mini.arguments == "['--resume', '\(conversation)', '--permission-mode', 'default']")

        // Once: more passes start nothing more, here or there.
        await laptop.moves.checkWaiting()
        #expect(laptop.moves.journal.all.filter { $0.role == .source }.map(\.id) == [record.id])
        await mini.hosted.refresh()
        #expect(mini.hosted.sessions.count == 1)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aWaitingMoveOutlivesARestartOfTheApp() async throws {
    let (laptop, mini, peer) = try await working()
    do {
        let session = try await laptop.startSession()
        let record = try await laptop.moves.request(session, to: peer, when: .afterTurn)

        // The app quits and starts again on the same folder: the request is read back and still waits.
        laptop.moves.watcher?.cancel()
        laptop.moves = laptop.makeMoves()
        laptop.moves.peer = { _ in peer }
        laptop.moves.watchEvery = .milliseconds(50)
        #expect(laptop.moves.record(record.id)?.state == .waiting && laptop.moves.waitingMove(for: conversation)?.computerName == "Mac mini")
        // As Remote coming up does.
        laptop.moves.watchWaiting()
        await laptop.moves.checkWaiting()
        #expect(laptop.agentAlive && !mini.agentAlive)

        laptop.status = { "idle" }
        #expect(await eventually { laptop.moves.record(record.id)?.state == .away })
        #expect(await eventually { mini.agentAlive })
        #expect(!laptop.agentAlive)
        // Started, it is off the disk: a later start finds nothing waiting.
        #expect(laptop.makeMoves().waiting.isEmpty)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aCancelledMoveNeverGoesEvenAfterARestart() async throws {
    let (laptop, mini, peer) = try await working()
    do {
        let session = try await laptop.startSession()
        let record = try await laptop.moves.request(session, to: peer, when: .afterTurn)
        #expect(laptop.moves.cancel(record.id) == .cancelled)
        #expect(laptop.moves.cancel(record.id) == .none)
        #expect(laptop.moves.records().isEmpty && laptop.moves.waiting.isEmpty)

        laptop.moves.watcher?.cancel()
        laptop.moves = laptop.makeMoves()
        laptop.moves.peer = { _ in peer }
        #expect(laptop.moves.waiting.isEmpty)
        laptop.status = { "idle" }
        await laptop.moves.checkWaiting()
        #expect(laptop.agentAlive && laptop.live().first?.pid == session.pid && !mini.agentAlive)
        #expect(laptop.moves.journal.all.isEmpty && laptop.moves.ownership(of: conversation) == .here)
        // Once it can move again, it can be asked again.
        laptop.status = { "busy" }
        #expect(try await laptop.moves.request(session, to: peer, when: .afterTurn).state == .waiting)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aWaitingMoveThatIsRefusedWhenItsTurnEndsLeavesTheSessionRunningAndSaysWhy() async throws {
    let (laptop, mini, peer) = try await working()
    do {
        var told: [String] = []
        laptop.moves.tell = { told.append($0) }
        let session = try await laptop.startSession()
        let record = try await laptop.moves.request(session, to: peer, when: .afterTurn)
        // Every check is asked again when the turn ends, and this time the other computer says no.
        mini.moves.accepts = { false }
        laptop.status = { "idle" }
        #expect(await eventually { laptop.moves.waiting.isEmpty })
        let failed = try #require(laptop.moves.record(record.id))
        let reason = "Mac mini isn't accepting sessions. Turn that on in its Remote settings."
        #expect(failed.state == .failed && failed.message == reason && failed.title == "Fix the login redirect" && failed.computerName == "Mac mini")
        #expect(told == ["Fix the login redirect stayed here: \(reason)"])
        #expect(laptop.agentAlive && laptop.live().first?.pid == session.pid)
        #expect(!mini.agentAlive && laptop.moves.ownership(of: conversation) == .here && laptop.moves.journal.all.isEmpty)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aWaitingMoveIsDroppedWhenTheLinkGoesOrTheSessionEnds() async throws {
    let (laptop, mini, peer) = try await working()
    do {
        var told: [String] = []
        laptop.moves.tell = { told.append($0) }
        let session = try await laptop.startSession()
        let unlinked = try await laptop.moves.request(session, to: peer, when: .afterTurn)
        laptop.moves.peer = { _ in nil }
        await laptop.moves.checkWaiting()
        #expect(laptop.moves.waiting.isEmpty && laptop.moves.record(unlinked.id)?.message == "Mac mini isn't linked any more, so it stayed here.")
        #expect(told.count == 1 && laptop.agentAlive)

        laptop.moves.peer = { _ in peer }
        let ended = try await laptop.moves.request(session, to: peer, when: .afterTurn)
        try await laptop.hosted.end(try #require(session.hosted))
        #expect(await eventually { !laptop.agentAlive })
        await laptop.moves.checkWaiting()
        #expect(laptop.moves.waiting.isEmpty && laptop.moves.record(ended.id)?.state == .failed)
        // Ended by the person, it needs no message.
        #expect(told.count == 1 && !mini.agentAlive)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aMoveNowStopsTheTurnAndMovesOnceItIsIdle() async throws {
    let (laptop, mini, peer) = try await working()
    do {
        let escaped = try stoppable(laptop)
        // The turn ends when the agent gets its Esc.
        laptop.status = { FileManager.default.fileExists(atPath: escaped.path) ? "idle" : "busy" }
        let session = try await laptop.startSession()
        #expect(session.status == "busy")
        let record = try await laptop.moves.request(session, to: peer, when: .now)
        #expect(record.state == .moving)
        #expect(await eventually { laptop.moves.record(record.id)?.state == .away })
        #expect(FileManager.default.fileExists(atPath: escaped.path))
        #expect(await eventually { mini.agentAlive && laptop.moves.waiting.isEmpty })
        #expect(!laptop.agentAlive && laptop.moves.ownership(of: conversation) == .away(peer: "Mac mini"))
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aMoveNowLeavesASessionThatNeverStopsRunningHere() async throws {
    let (laptop, mini, peer) = try await working()
    do {
        let escaped = try stoppable(laptop)
        laptop.moves.stopsWithin = .milliseconds(500)
        let session = try await laptop.startSession()
        let record = try await laptop.moves.request(session, to: peer, when: .now)
        #expect(await eventually { laptop.moves.waiting.isEmpty })
        // It was asked to stop, and didn't.
        #expect(await eventually { FileManager.default.fileExists(atPath: escaped.path) })
        #expect(laptop.moves.record(record.id)?.message == "It didn't stop working, so it's still running here.")
        #expect(laptop.agentAlive && laptop.live().first?.pid == session.pid)
        #expect(!mini.agentAlive && laptop.moves.journal.all.isEmpty && laptop.moves.ownership(of: conversation) == .here)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func moveAndSleepSleepsOnlyOnceEverySessionHasLeft() async throws {
    let (laptop, mini, peer) = try await working()
    do {
        var slept: [MoveJournal.Ownership] = []
        laptop.moves.sleep = { slept.append(laptop.moves.ownership(of: conversation)) }
        _ = try await laptop.startSession()
        let leaving = Task { await laptop.moves.leaveAndSleep(laptop.live(), to: peer, working: .afterTurn) }
        #expect(await eventually { laptop.moves.waitingMove(for: conversation) != nil })
        #expect(laptop.moves.sleepsAfter == "Mac mini")
        await laptop.moves.checkWaiting()
        #expect(slept.isEmpty && laptop.agentAlive)

        laptop.status = { "idle" }
        let stayed = await leaving.value
        #expect(stayed.isEmpty)
        // Called once, and only after the move had settled.
        #expect(slept == [.away(peer: "Mac mini")])
        #expect(laptop.moves.sleepsAfter == nil && laptop.moves.leftWorking == nil && !laptop.agentAlive)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func moveAndSleepAsksFirstWhenASessionThatStayedIsStillWorking() async throws {
    let (laptop, mini, peer) = try await working()
    do {
        var slept = 0, told: [String] = []
        laptop.moves.sleep = { slept += 1 }
        laptop.moves.tell = { told.append($0) }
        laptop.moves.stopsWithin = .milliseconds(300)
        _ = try await laptop.startSession()
        // Now, and it never stops: it stays here working, and the Mac stays awake until the person says.
        let stayed = await laptop.moves.leaveAndSleep(laptop.live(), to: peer, working: .now)
        #expect(stayed.map(\.reason) == ["It didn't stop working, so it's still running here."])
        #expect(slept == 0 && laptop.moves.leftWorking?.map(\.title) == ["Fix the login redirect"])
        await laptop.moves.sleepAnyway()
        #expect(slept == 1 && laptop.moves.leftWorking == nil)
        #expect(laptop.agentAlive && !mini.agentAlive)

        // One that stayed idle doesn't hold the Mac awake; it is named.
        laptop.status = { "idle" }
        mini.moves.accepts = { false }
        let idle = await laptop.moves.leaveAndSleep(laptop.live(), to: peer, working: .now)
        #expect(idle.count == 1 && slept == 2 && laptop.moves.leftWorking == nil)
        #expect(told == ["Fix the login redirect stayed here: Mac mini isn't accepting sessions. Turn that on in its Remote settings."])

        // Don't Sleep, chosen while they leave: they still go, and the Mac stays awake.
        laptop.status = { "busy" }
        mini.moves.accepts = { true }
        let leaving = Task { await laptop.moves.leaveAndSleep(laptop.live(), to: peer, working: .afterTurn) }
        #expect(await eventually { laptop.moves.waitingMove(for: conversation) != nil })
        laptop.moves.stayAwake()
        laptop.status = { "idle" }
        #expect(await leaving.value.isEmpty)
        #expect(slept == 2 && !laptop.agentAlive && laptop.moves.sleepsAfter == nil)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test func whatAWorkingSessionMayMoveWithDependsOnWhenItGoes() {
    func row(_ status: String, hosted: String? = "sa-app-1a2b") -> LiveSession {
        var row = LiveSession(pid: 1, sessionID: conversation, name: nil, title: nil, cost: nil, cwd: "/code/app", status: status, waitingFor: nil, since: nil)
        row.hosted = hosted
        return row
    }
    #expect(Moves.refusal(row("busy", hosted: nil), when: .afterTurn) == "Only sessions Side A hosts can move. Use Continue on phone first.")
    #expect(Moves.refusal(row("busy"), when: .idle) == "It's working. Move it when it has finished its turn.")
    #expect(Moves.refusal(row("busy"), when: .afterTurn) == nil && Moves.refusal(row("busy"), when: .now) == nil)
    #expect(Moves.refusal(row("waiting"), when: .afterTurn) == nil)
    #expect(Moves.refusal(row("waiting"), when: .now) == "It's waiting for an answer. Answer it first, or move it after this turn.")
    #expect(Moves.refusal(row("unknown"), when: .afterTurn) == "Side A can't tell yet whether it's working. Try again in a moment.")
    #expect(Moves.refusal(row("idle"), when: .now) == nil && Moves.refusal(row("idle"), when: .idle) == nil)
    #expect(Moves.refusal(row("idle"), when: MoveRequest.When(rawValue: "atLunch")) == "Side A on this Mac can't move a session that way. Update it first.")
}

@MainActor @Test func aWaitingMoveIsListedForThePhoneAndCancelledUntilItStarts() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moves-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AccountStore(demo: true, root: folder)
    func call(_ method: String, _ path: String) async -> HTTPResponse {
        let request = HTTPRequest(method: method, target: "/" + path, path: path.split(separator: "/").map(String.init), query: [:], headers: HTTPHeaders([]), body: Data())
        return await RemoteRoutes.route(request, RemoteServer.Caller(device: "phone", connection: 1), store.remote)
    }
    #expect(await call("DELETE", "v1/moves/mv-000000000001").status == 404)
    let moves = store.remote.moves
    let id = "mv-000000000002"
    moves.waiting[id] = Moves.Waiting(id: id, conversation: conversation, agent: .claude, title: "Fix the login redirect", project: "app",
                                      computer: "mini", computerName: "Mac mini", when: .afterTurn, at: 1, until: Date().timeIntervalSince1970 + 60)
    let list = try JSONDecoder().decode(MoveList.self, from: await call("GET", "v1/moves").body)
    #expect(list.moves.map(\.state) == [.waiting] && list.moves.first?.id == id && list.moves.first?.computerName == "Mac mini")
    moves.firing.insert(id)
    #expect(await call("DELETE", "v1/moves/\(id)").status == 409)
    moves.firing.remove(id)
    #expect(await call("DELETE", "v1/moves/\(id)").status == 204)
    #expect(moves.waiting.isEmpty && moves.records().isEmpty)
    #expect(store.remote.capabilities.contains(.movesWhen) == store.hosted.available)
}

@MainActor @Test func sleepingAfterAMoveLetsGoOfWhatHeldTheMacAwakeFirst() {
    let fake = FakeSleep()
    let defaults = temporaryDefaults()
    defaults.set(true, forKey: KeepAwakeController.enabledKey)
    defaults.set(true, forKey: KeepAwakeController.lidClosedKey)
    let keepAwake = KeepAwakeController(system: fake, defaults: defaults)
    fake.working = 1
    keepAwake.check(now: 0)
    #expect(keepAwake.holding && fake.disabled)
    keepAwake.sleepNow()
    #expect(fake.held == nil && !fake.disabled && !keepAwake.holding && fake.slept == 1)
    #expect(fake.calls.suffix(2) == ["release", "ask 0"])

    let plain = FakeSleep()
    let alone = KeepAwakeController(system: plain, defaults: temporaryDefaults())
    alone.sleepNow()
    #expect(plain.slept == 1 && plain.asks.isEmpty)
}
