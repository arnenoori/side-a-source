import Foundation
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

/// The agent of a session that arrived on `computer` exits there (the person quit it, or it crashed): tmux keeps its pane,
/// dead, and the session list no longer has it (on Linux, even while tmux 3.4 has yet to reap the agent).
private func agentExits(_ computer: Running, _ row: LiveRow) async throws {
    let conversation = try #require(row.id)
    try #require(kill(pid_t(row.pid), SIGTERM) == 0)
    #expect(await eventually(30) { await computer.running(conversation) == nil })
    #expect(await eventually(30) { await computer.engine.tmux.list().contains { $0.session == conversation && $0.dead } })
}

private func phoneCall(_ connection: TestConnection, _ method: String, _ path: String, token: String, body: Data = Data(), key: String? = nil,
                       confirm: String? = nil) async throws -> Answer {
    var headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json"]
    if let key { headers["Idempotency-Key"] = key }
    if let confirm { headers[ConfirmSignature.header] = confirm }
    return try await connection.request(method, path, headers: headers, body: body)
}

extension MoveTests {
    @Test func aSessionWhoseAgentExitedWhereItArrivedIsBroughtBackWithItsLaterWorkAndItsLogin() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try target.signIn("you@example.com")
        let work = try source.book.add("Work")
        let login = try source.signIn("alex@example.com", folder: URL(fileURLWithPath: work.configDir))
        let credentials = URL(fileURLWithPath: work.configDir).appendingPathComponent(".credentials.json")
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let conversation = try #require(try await a.host(folder, prompt: "before it went", account: work).id)
            _ = try await a.moves.move(conversation, to: "spare-box")
            let stored = try #require(b.machine.book.load().first)
            let there = try #require(await b.running(conversation))
            let name = try #require(there.hosted)
            #expect(!FileManager.default.fileExists(atPath: credentials.path))

            // More work there: a change nobody committed, and another turn of the conversation. Then the agent exits.
            let landed = URL(fileURLWithPath: try #require(there.cwd))
            try Data("one\ntwo\nthree\n".utf8).write(to: landed.appendingPathComponent("README.md"))
            try await b.engine.tmux.type(name, agent: .claude, text: "later on the spare box")
            #expect(await eventually(30) { b.transcript(of: there, account: stored)?.contains("Echo: later on the spare box") == true })
            #expect(await eventually(10) { await b.running(conversation)?.status == "idle" })
            try await agentExits(b, try #require(await b.running(conversation)))
            let ended = try #require(await b.moves.ended(conversation))
            #expect(ended.pid == 0 && ended.hosted == name && ended.cwd == landed.path && ended.status == "idle")
            #expect(await b.moves.ended(name)?.id == conversation)

            // Bring Back is the phone's move on the computer it is on, naming the conversation.
            let phone = FakePhone()
            let pin = b.daemon.identity.spkiHash
            let token = try await phone.pair(with: b.daemon, pin: pin).token
            let connection = try await TestConnection.open(port: b.daemon.port, pin: pin)
            let request = MoveRequest(computer: a.machine.hostID)
            let body = try JSONEncoder().encode(request)
            let previewed = try await phoneCall(connection, "POST", "/v1/sessions/\(conversation)/move/preview", token: token, body: body, key: "preview-1")
            try #require(previewed.status == 200, "\(String(decoding: previewed.body, as: UTF8.self))")
            let preview = try previewed.json(MovePreview.self)
            #expect(preview.computer.id == a.machine.hostID && preview.login == .sent && preview.account == "Work")
            // Asking started nothing on either computer.
            #expect(await b.running(conversation) == nil)
            #expect(await a.running(conversation) == nil)
            let proof = try phone.confirm(purpose: .action, subject: try ConfirmMessage.subject(action: .moveSession, target: conversation, body: request),
                                          biometric: true, macID: b.machine.hostID)
            let moving = try await phoneCall(connection, "POST", "/v1/sessions/\(conversation)/move", token: token, body: body, key: "move-1", confirm: proof)
            #expect(moving.status == 202)
            let record = try moving.json(MoveRecord.self)
            #expect(await eventually(120) {
                (try? await phoneCall(connection, "GET", "/v1/moves", token: token).json(MoveList.self))?.moves.first { $0.id == record.id }?.state == .away
            })
            await connection.close()

            // Back where it started, beside the checkout it left, with the work and the conversation from there and its login.
            var back: LiveRow?
            #expect(await eventually(30) { back = await a.running(conversation); return back?.status == "idle" })
            let home = try #require(back)
            #expect(home.cwd?.hasPrefix(folder.appendingPathComponent(".sidea-worktrees").path) == true, "\(home.cwd ?? "")")
            #expect(try String(contentsOf: URL(fileURLWithPath: try #require(home.cwd)).appendingPathComponent("README.md"), encoding: .utf8) == "one\ntwo\nthree\n")
            #expect(try String(contentsOf: URL(fileURLWithPath: try #require(home.cwd)).appendingPathComponent("notes.txt"), encoding: .utf8) == "not committed\n")
            #expect(a.transcript(of: home, account: work)?.contains("Echo: later on the spare box") == true)
            #expect(FileManager.default.contents(atPath: credentials.path) == login)
            #expect(await a.engine.tmux.account(of: try #require(home.hosted)) == work.id)
            #expect(a.machine.resumes(conversation) == 1 && b.machine.resumes(conversation) == 1)

            // The spare box holds nothing it could run: no login, no transcript within the CLI's reach and no pane (both go
            // just after the phone hears it is away).
            #expect(await eventually(10) { b.transcript(of: there, account: stored) == nil })
            #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: stored.configDir).appendingPathComponent(".credentials.json").path))
            #expect(await eventually(10) { await b.engine.tmux.list().allSatisfy { $0.session != conversation } })
            #expect(await b.moves.ended(conversation) == nil)
            #expect(await b.moves.elsewhere(conversation)?.id == a.machine.hostID)
            #expect(await b.moves.journal.all.filter { $0.session == conversation }.map(\.step) == [.gone, .away])
            #expect(await a.moves.ownership(of: conversation).mayRun)
            #expect(await a.moves.journal.all.filter { $0.session == conversation && $0.role == .source }.map(\.step) == [.returned])
            #expect(await a.moves.journal.all.filter { $0.session == conversation && $0.role == .destination }.map(\.step) == [.discarded, .live])
        }
    }

    @Test func anEndedSessionWhoseFolderIsGoneIsRefusedAndNothingChanges() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let conversation = try #require(try await a.host(folder, prompt: "its folder goes").id)
            _ = try await a.moves.move(conversation, to: "spare-box")
            let there = try #require(await b.running(conversation))
            try await agentExits(b, there)
            try FileManager.default.removeItem(atPath: try #require(there.cwd))
            let before = (await b.moves.journal, await a.moves.journal)

            let gone = "The folder it ran in on spare-box is gone, so it can't move."
            await #expect(throws: MoveFailure.refused(gone)) { try await b.moves.preview(conversation, to: "build-box") }
            // `sidead move` by the name it was hosted as.
            let name = try #require(there.hosted)
            let answer = try #require(await b.service.control("move", ["session": name, "computer": "build-box"]))
            let said = try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
            #expect(said["ok"] as? Bool == false && said["error"] as? String == gone)
            #expect(await b.moves.journal == before.0)
            #expect(await a.moves.journal == before.1)
            #expect(await b.moves.claimed.isEmpty)
            #expect(await b.running(conversation) == nil)
            #expect(await a.running(conversation) == nil)
            #expect(await b.moves.ownership(of: conversation).mayRun)
            #expect(await a.moves.ownership(of: conversation) == .away(peer: b.machine.hostID))
            #expect(a.machine.resumes(conversation) == 0 && b.machine.resumes(conversation) == 1)
        }
    }

    @Test func anArrivedSessionThatStillRunsIsStoppedBeforeItMovesOn() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let conversation = try #require(try await a.host(folder, prompt: "still running").id)
            _ = try await a.moves.move(conversation, to: "spare-box")
            let there = try #require(await b.running(conversation))
            #expect(await b.moves.ended(conversation) == nil)
            let peer = LinkedPeer(try #require(await b.moves.links.computer(a.machine.hostID)))
            // Nothing that stands in for it moves it while it runs.
            let standIn = LiveRow(standingIn: try #require(await b.moves.arrival(of: conversation)?.incoming))
            await #expect(throws: MoveFailure.refused("That session isn't running on spare-box.")) { try await b.moves.prepare(standIn, to: peer) }
            #expect(await b.running(conversation) != nil)

            let plan = try await b.moves.prepare(there, to: peer)
            #expect(plan.ended == nil && plan.row.pid == there.pid)
            #expect(try await b.moves.run(plan, to: peer).status == .live)
            #expect(await eventually(30) { await a.running(conversation) != nil })
            #expect(await b.running(conversation) == nil)
            #expect(await b.engine.tmux.list().allSatisfy { $0.session != conversation })
            #expect(await b.moves.journal.all.first { $0.role == .source }?.ended == nil)
        }
    }
}
