import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

/// The harness's staged two-way rows behave as L8's phone tests expect, through the real routes.
@MainActor @Test func theHarnessTwoWayRowsAnswerLikeTheirDaemons() async throws {
    let store = AccountStore(demo: true)
    HarnessScene.twoWay(store)
    store.remote.confirmCheck = { _, _, _, _, _ in nil }
    func call(_ method: String, _ path: String, _ body: Any? = nil) async throws -> (Int, [String: Any]) {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let request = HTTPRequest(method: method, target: "/" + path, path: path.split(separator: "/").map(String.init), query: [:],
                                  headers: HTTPHeaders([]), body: data)
        let response = await RemoteRoutes.route(request, RemoteServer.Caller(device: "d1", connection: 1), store.remote)
        return (response.status, response.body.isEmpty ? [:] : try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any]))
    }
    func session(_ pid: Int) throws -> RemoteSession { WireBuilders.session(try #require(store.sessions.live.first { $0.pid == pid }), store: store, finished: []) }
    func reply(_ id: String, _ extra: [String: Any] = [:]) async throws -> (Int, String?) {
        let (status, body) = try await call("POST", "v1/sessions/\(id)/reply", ["text": "from the phone", "mode": "auto", "attachments": []].merging(extra) { $1 })
        return (status, body["delivery"] as? String)
    }
    #expect(store.remote.capabilities.contains(.replyTerminal) && store.remote.capabilities.contains(.replyInbox))
    #expect(try session(94001).abilities.isSuperset(of: [.replyTerminal, .interrupt]) && session(94001).status == .working)
    #expect(try await reply("codex-steer") == (200, "typed"))
    #expect(try await reply("codex-steer", ["submit": "queue"]) == (200, "queued"))
    #expect(try await reply("codex-steer", ["mode": "followUp"]) == (200, "queued"))
    let (status, body) = try await call("POST", "v1/sessions/codex-steer/interrupt")
    #expect(try status == 200 && body["method"] as? String == "turnInterrupt" && session(94001).status == .idle)

    #expect(try session(94002).status == .idle)
    #expect(try await reply("codex-idle") == (200, "typed"))
    #expect(try session(94002).status == .working)

    #expect(try !session(94003).abilities.contains(.replyTerminal))

    #expect(try session(94004).flag?.kind == .unsent)
    #expect(try await reply("codex-dropped") == (200, "typed"))
    #expect(try session(94004).flag?.kind != .unsent)

    #expect(try session(94005).abilities.contains(.replyInbox))
    #expect(try await reply("claude-inbox") == (200, "inbox"))
}

/// A Claude turn's diff comes from the bridge's reading of its transcript; compact and review say why not.
@MainActor @Test func claudeSessionsDiffTheirTurnsAndSayWhyTheyCantCompactOrReview() async throws {
    let store = AccountStore(demo: true), id = "c1a00000-0000-4000-8000-000000000000"
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-turns-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let home = folder.appendingPathComponent("home")
    try TranscriptFixture.write(TranscriptFixture.lines(session: id, cwd: "/tmp/work"), session: id, home: home)
    store.sessions.transcriptSource = (home: home, bridge: TranscriptFixture.bridge, python: "/usr/bin/python3", root: folder.appendingPathComponent("Side A"))
    store.sessions.live = [try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: [
        "pid": 4201, "id": id, "status": "idle", "cwd": "/tmp/work", "started": 1_700_000_000, "agent": "claude", "turnID": "u1"]))]
    let commands = SessionCommands(store: store)
    let diff = try await commands.turnDiff(id, turn: "u1")
    #expect(diff.turnID == "u1" && !diff.running && diff.files.map(\.path) == ["/tmp/work/a.js"])
    #expect(diff.files.first?.hunks.first?.lines == ["-x = 1", "+x = 2"])
    #expect(diff.note == "Edits made with Claude's file tools; shell changes aren't shown.")
    await #expect(throws: SessionCommands.Failure(status: 404, code: "turn_not_found", message: "Side A has no changes for that turn.")) {
        _ = try await commands.turnDiff(id, turn: "a1")
    }
    let row = WireBuilders.session(store.sessions.live[0], store: store, finished: [])
    #expect(row.turnID == "u1" && row.abilities.contains(.turnDiff) && !row.abilities.contains(.review))
    #expect(row.abilityReasons?["turnDiff"] == nil)
    #expect(row.abilityReasons?["review"] == "Ask Claude in a reply.")
    await #expect(throws: SessionCommands.cannot("Compacting needs a session Side A hosts.")) { try await commands.compact(id) }
    await #expect(throws: SessionCommands.cannot("Ask Claude in a reply.")) { try await commands.review(id, ReviewRequest()) }
    await #expect(throws: SessionCommands.Failure.noSession) { try await commands.compact("nope") }
}
