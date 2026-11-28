import Crypto
import Foundation
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

private func ask(_ connection: TestConnection, _ method: String, _ path: String, token: String, body: Data = Data(), key: String? = nil,
                 confirm: String? = nil) async throws -> Answer {
    var headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json"]
    if let key { headers["Idempotency-Key"] = key }
    if let confirm { headers[ConfirmSignature.header] = confirm }
    return try await connection.request(method, path, headers: headers, body: body)
}

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// A checkpoint of no session at all: the four files `keep` checks, as a computer sends them. `damaged` lists a hash for
/// the bundle that isn't the one of what was sent.
private func checkpoint(_ id: String, of conversation: String, to peer: LinkedPeer, from me: MacInfo, at: Double = Date().timeIntervalSince1970,
                        damaged: Bool = false, keep: Bool = true) async throws {
    let offer = StandbyOffer(id: id, conversationID: conversation, agent: .claude, project: "app", title: "Old work", commits: [], from: me, at: at)
    _ = try await peer.standby(offer)
    let files: [(String, Data)] = [("manifest.json", Data(#"{"move":"\#(id)"}"#.utf8)),
                                   ("conversation.json", Data(#"{"session":"\#(conversation)","agent":"claude"}"#.utf8)),
                                   ("workspace.bundle", Data("bundle".utf8)), ("conversation.tar", Data("tar".utf8))]
    var parts: [MovePart] = []
    for (name, data) in files {
        try await peer.standbyPart(id, name, 0, data)
        parts.append(MovePart(name: name, sha256: hex(damaged && name == "workspace.bundle" ? Data("other".utf8) : data), size: data.count))
        if !keep { return }
    }
    try await peer.keep(id, MoveStage(parts: parts))
}

private func object(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

extension MoveTests {
    @Test func aCheckpointGoesToTheStandbyWhenATurnEndsOnlyWhenChangedAndAtMostOnceAMinuteAndIsContinuedThereAsAFork() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        // Long enough that the session reader sees each turn working, then idle.
        source.settings.environment["FAKE_CLAUDE_WORK"] = "2"
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let row = try await a.host(folder, prompt: "keep a copy")
            let conversation = try #require(row.id)
            let name = try #require(row.hosted)
            // No standby chosen: nothing goes anywhere.
            await a.moves.checkpointAll()
            #expect(await b.moves.copies().isEmpty)

            let set = try object(await a.service.control("config", ["key": "standby", "value": "spare-box"]))
            #expect(set["ok"] as? Bool == true)
            #expect((set["settings"] as? [[String: String]])?.contains { $0["key"] == "standby" && $0["value"] == "spare-box" } == true)
            #expect(await a.moves.settings().standby == b.machine.hostID)
            // The end of a turn sends one, without waiting for the minute's pass.
            _ = await a.engine.tmux.run(["send-keys", "-t", HostedTmux.target(name), "-l", "and another"])
            _ = await a.engine.tmux.run(["send-keys", "-t", HostedTmux.target(name), "Enter"])
            #expect(await eventually(60) { await !b.moves.copies().isEmpty })
            let first = try #require(await b.moves.kept.values.first)
            #expect(first.offer.conversationID == conversation && first.complete && first.offer.from.id == a.machine.hostID)
            #expect(await b.moves.copies().map(\.computerName) == ["build-box"])
            let sentAt = Date().timeIntervalSince1970
            // Where it went is written down here.
            #expect(FileManager.default.fileExists(atPath: a.machine.state.appendingPathComponent("standby-sent.json").path))

            // Again at once: within the minute, nothing goes.
            await a.moves.checkpointAll()
            #expect(await b.moves.kept.keys.sorted() == [first.id])
            // A minute on and unchanged: nothing goes.
            await a.moves.set(clock: { sentAt + 61 })
            await a.moves.checkpointAll()
            #expect(await b.moves.kept.keys.sorted() == [first.id])
            // Changed: the new one replaces the old there.
            try Data("later\n".utf8).write(to: folder.appendingPathComponent("later.txt"))
            await a.moves.set(clock: { sentAt + 130 })
            await a.moves.checkpointAll()
            let second = try #require(await b.moves.kept.values.first)
            #expect(await b.moves.kept.count == 1 && second.id != first.id)
            let held = b.machine.home.appendingPathComponent("root/runtime/moves/standby")
            #expect(!FileManager.default.fileExists(atPath: held.appendingPathComponent(first.id).path))
            // Nothing of the session here was touched, and no ref was left in the repository.
            #expect(await a.running(conversation)?.hosted == name)
            let refs = await Run.process(try #require(Run.which("git")), ["-C", folder.path, "for-each-ref", "--format=%(refname)"], environment: a.machine.settings.environment)
            #expect(!refs.output.contains(second.id) && !refs.output.contains(first.id), "\(refs.output)")

            // The phone sees it there and continues it, signed with Face ID.
            let phone = FakePhone()
            let pin = b.daemon.identity.spkiHash
            let token = try await phone.pair(with: b.daemon, pin: pin).token
            let connection = try await TestConnection.open(port: b.daemon.port, pin: pin)
            let hello = try await connection.request("GET", "/v1/hello", headers: ["Authorization": "Bearer \(token)"]).json(Hello.self)
            #expect(hello.capabilities.contains(.standby))
            let listed = try await ask(connection, "GET", "/v1/standby", token: token).json(StandbyList.self)
            #expect(listed.copies.map(\.conversationID) == [conversation] && listed.copies.first?.computer == a.machine.hostID)
            let subject = ConfirmMessage.subject(action: .copyStandby, target: conversation)
            #expect(try await ask(connection, "POST", "/v1/standby/\(conversation)/copy", token: token, key: "copy-1").status == 401)
            let unlockOnly = try phone.confirm(purpose: .action, subject: subject, macID: b.machine.hostID)
            #expect(try await ask(connection, "POST", "/v1/standby/\(conversation)/copy", token: token, key: "copy-2", confirm: unlockOnly).status == 401)
            let proof = try phone.confirm(purpose: .action, subject: subject, biometric: true, macID: b.machine.hostID)
            let copied = try await ask(connection, "POST", "/v1/standby/\(conversation)/copy", token: token, key: "copy-3", confirm: proof)
            #expect(copied.status == 201)
            let state = try copied.json(MoveState.self)
            #expect(state.status == .live && state.id == second.id)
            let landed = try #require(state.folder)
            #expect(try String(contentsOf: URL(fileURLWithPath: landed).appendingPathComponent("later.txt"), encoding: .utf8) == "later\n")
            // A fork: a conversation of its own that starts with everything said so far.
            var copy: LiveRow?
            #expect(await eventually(30) {
                copy = await b.engine.live().first { $0.hosted == state.session && $0.id != nil }
                return copy != nil
            })
            let forked = try #require(copy?.id)
            #expect(forked != conversation)
            #expect(await eventually(10) { copy.flatMap { b.transcript(of: $0) }?.contains("Echo: keep a copy") == true })
            let starts = (try? String(contentsOf: b.machine.starts, encoding: .utf8)) ?? ""
            #expect(starts.contains("\"--resume\", \"\(conversation)\", \"--fork-session\""), "\(starts)")
            #expect(await a.running(conversation) != nil)
            await connection.close()

            // Standby turned off while this daemon is stopped: the next one deletes what went there.
            try await a.daemon.stop()
            #expect(await DaemonCLI.config(DaemonPaths(state: a.machine.state), ["standby", "off"]) == 0)
            let again = try await start(a.machine)
            await again.moves.checkpointAll()
            #expect(await b.moves.kept.isEmpty)
            #expect(!((try? FileManager.default.contentsOfDirectory(atPath: held.path)) ?? []).contains { $0.hasPrefix("sb-") })
            let sent = await again.moves.sent
            #expect(sent.checkpoints.isEmpty && sent.owed.isEmpty)
            try await again.daemon.stop()
        }
    }

    @Test func aStandbyKeepsOnlyWhatALinkedComputerSendsChecksItAndCountsItsAgeFromArrival() async throws {
        let source = try Machine("build-box"), target = try Machine("spare-box")
        try target.signIn("you@example.com")
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let peer = LinkedPeer(try #require(await a.moves.links.computer(b.machine.hostID)))
            let me = a.daemon.me
            let held = b.machine.home.appendingPathComponent("root/runtime/moves/standby")
            // Ids are checked before they name anything.
            for (id, conversation) in [("sb-../../../etc", "c1"), ("SB-ABCDEF123", "c1"), ("mv-0123456789", "c1"), ("sb-12", "c1"), ("sb-xyz123456", "c1"),
                                       ("sb-0123456789", "../../escape"), ("sb-0123456788", "")] {
                let offer = StandbyOffer(id: id, conversationID: conversation, agent: .claude, project: "app", commits: [], from: me, at: 0)
                await #expect(throws: MoveFailure.self, "\(id) \(conversation)") { try await peer.standby(offer) }
            }
            await #expect(throws: MoveFailure.self) { try await peer.standbyPart("sb-../../x", "manifest.json", 0, Data("{}".utf8)) }
            await #expect(throws: MoveFailure.self) { try await peer.standbyPart("sb-0123456789", "../../x", 0, Data("{}".utf8)) }
            await #expect(throws: MoveFailure.self) { try await peer.keep("sb-zz", MoveStage(parts: [])) }
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: held.path)) ?? []).isEmpty)

            // Damaged on the way: nothing is kept.
            await #expect(throws: MoveFailure.refused("The checkpoint was damaged on the way.")) {
                try await checkpoint("sb-000000000001", of: "conversation-one", to: peer, from: me, damaged: true)
            }
            #expect(await b.moves.copies().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: held.appendingPathComponent("sb-000000000001").path))

            // Taken long ago by the sender's clock, it is as old as it has been here.
            try await checkpoint("sb-000000000002", of: "conversation-one", to: peer, from: me, at: 1000)
            await b.moves.dropOldCheckpoints()
            #expect(await b.moves.copies().map(\.conversationID) == ["conversation-one"])

            // A phone may look, and nothing else.
            let phone = FakePhone()
            let pin = b.daemon.identity.spkiHash
            let paired = try await phone.pair(with: b.daemon, pin: pin)
            let connection = try await TestConnection.open(port: b.daemon.port, pin: pin)
            let offer = StandbyOffer(id: "sb-000000000003", conversationID: "conversation-two", agent: .claude, project: "app", commits: [], from: me, at: 0)
            for (index, (method, path, body)) in [("POST", "/v1/standby", try JSONEncoder().encode(offer)),
                                                  ("POST", "/v1/standby/sb-000000000002/parts/manifest.json/0", Data("{}".utf8)),
                                                  ("POST", "/v1/standby/sb-000000000002/keep", try JSONEncoder().encode(MoveStage(parts: []))),
                                                  ("DELETE", "/v1/standby/all", Data()), ("DELETE", "/v1/standby/conversation-one", Data())].enumerated() {
                let answer = try await ask(connection, method, path, token: paired.token, body: body, key: "phone-\(index)")
                #expect(answer.status == 403 && answer.errorCode == "not_computer", "\(method) \(path)")
            }
            #expect(try await ask(connection, "GET", "/v1/standby", token: paired.token).json(StandbyList.self).copies.count == 1)

            // Another linked computer can neither add to what this one is sending nor delete what it sent.
            let other = FakePhone(name: "other-box", capabilities: [.computer, .moves])
            let otherToken = try await other.pair(with: b.daemon, pin: pin).token
            _ = try await peer.standby(offer)
            let part = try await ask(connection, "POST", "/v1/standby/sb-000000000003/parts/manifest.json/0", token: otherToken, body: Data("{}".utf8))
            #expect(part.status == 409 && part.errorCode == "move_refused")
            #expect(try await ask(connection, "DELETE", "/v1/standby/all", token: otherToken, key: "other-1").status == 204)
            #expect(await b.moves.copies().count == 1)
            await connection.close()

            // One still arriving when the daemon stops is gone when it starts; a whole one stays.
            try await peer.standbyPart("sb-000000000003", "manifest.json", 0, Data(#"{"move":"sb-000000000003"}"#.utf8))
            #expect(FileManager.default.fileExists(atPath: held.appendingPathComponent("sb-000000000003").path))
            try await b.daemon.stop()
            let again = try await start(b.machine)
            #expect(!FileManager.default.fileExists(atPath: held.appendingPathComponent("sb-000000000003").path))
            #expect(await again.moves.copies().map(\.conversationID) == ["conversation-one"])
            try await a.moves.links.update(b.machine.hostID) { $0.endpoints = Endpoints(tailnet: "127.0.0.1:\(again.daemon.port)") }
            let back = LinkedPeer(try #require(await a.moves.links.computer(b.machine.hostID)))

            // Thirty days after it arrived, by this computer's clock, it goes.
            let arrived = Date().timeIntervalSince1970
            await again.moves.set(clock: { arrived + 29 * 86_400 })
            await again.moves.dropOldCheckpoints()
            #expect(await again.moves.copies().count == 1)
            await again.moves.set(clock: { arrived + 31 * 86_400 })
            await again.moves.dropOldCheckpoints()
            #expect(await again.moves.copies().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: held.appendingPathComponent("sb-000000000002").path))

            // A computer that isn't accepting sessions keeps no checkpoints either, with the Mac's sentence.
            await again.moves.set(clock: { Date().timeIntervalSince1970 })
            #expect(await DaemonCLI.config(DaemonPaths(state: b.machine.state), ["accept-sessions", "off"]) == 0)
            await #expect(throws: MoveFailure.refused("spare-box isn't accepting sessions.")) {
                try await checkpoint("sb-000000000004", of: "conversation-three", to: back, from: me)
            }
            // Deleting a conversation it holds nothing of is no error.
            try await back.forget("conversation-none")
            try await again.daemon.stop()
        }
    }
}
