import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import SideAProtocolFixtures
import SideARemoteKit
import Testing

/// Byte budgets for what a phone pulls from the Mac. A very long session once cost its newest fifty rows, tool output and
/// all, at every open; these pin what opening, resuming and idling cost now.
@MainActor
final class HeavySession {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heavy-\(UUID().uuidString)")
    let store: AccountStore
    let session: String
    let fileBytes: Int

    init(turns: Int) throws {
        let session = "heavy1", home = folder.appendingPathComponent("home")
        self.session = session
        store = AccountStore(demo: true, root: folder)
        // Output that doesn't compress to nothing: every line differs, as build logs and diffs do.
        var seed: UInt64 = 42
        func noise(_ count: Int) -> [String] {
            (0..<count).map { _ in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return "src/module-\(seed >> 40).ts:\(seed >> 52) error TS\(seed >> 48 & 9_999) \(String(seed, radix: 36)) in handle\(seed >> 44)"
            }
        }
        var lines: [[String: Any]] = []
        func entry(_ type: String, _ uuid: String, _ content: [[String: Any]]) -> [String: Any] {
            ["type": type, "uuid": uuid, "sessionId": session, "timestamp": "\(TranscriptFixture.today)T10:00:00Z", "cwd": "/tmp/app",
             "message": ["role": type, "id": "m-\(uuid)", "model": "claude-opus-5-5", "content": content]]
        }
        for turn in 0..<turns {
            lines.append(entry("user", "u\(turn)", [["type": "text", "text": "Turn \(turn): please keep going and check the build again."]]))
            var calls: [[String: Any]] = [["type": "text", "text": String(repeating: "I looked at the module and the tests. ", count: 40)]]
            calls.append(["type": "tool_use", "id": "e\(turn)", "name": "Edit", "input": ["file_path": "/tmp/app/a\(turn).ts", "old_string": "x", "new_string": "y"]])
            for call in 0..<3 { calls.append(["type": "tool_use", "id": "c\(turn)-\(call)", "name": "Bash", "input": ["command": "npm test -- --shard \(call)"]]) }
            lines.append(entry("assistant", "a\(turn)", calls))
            lines.append(entry("user", "r\(turn)", (0..<3).map { ["type": "tool_result", "tool_use_id": "c\(turn)-\($0)", "content": noise(400).joined(separator: "\n"), "is_error": false] }))
            var edited = entry("user", "x\(turn)", [["type": "tool_result", "tool_use_id": "e\(turn)", "content": "edited"]])
            edited["toolUseResult"] = ["filePath": "/tmp/app/a\(turn).ts",
                                       "structuredPatch": [["oldStart": 1, "oldLines": 300, "newStart": 1, "newLines": 300, "lines": noise(300).map { "+" + $0 }]]]
            lines.append(edited)
        }
        try TranscriptFixture.write(lines, session: session, home: home)
        let file = home.appendingPathComponent(".claude/projects/-fixture/\(session).jsonl")
        fileBytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let index = home.appendingPathComponent("Side A")
        TranscriptFixture.index(home: home, root: index)
        store.sessions.transcriptSource = (home: home, bridge: TranscriptFixture.bridge, python: "/usr/bin/python3", root: index)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func get(_ path: String, gzip: Bool = true, etag: String? = nil) async -> HTTPResponse {
        let parts = URLComponents(string: "/" + path)
        let query = Dictionary((parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        var headers = gzip ? [("Accept-Encoding", "gzip")] : []
        if let etag { headers.append(("If-None-Match", etag)) }
        let request = HTTPRequest(method: "GET", target: "/" + path, path: (parts?.path ?? path).split(separator: "/").map(String.init), query: query,
                                  headers: HTTPHeaders(headers), body: Data())
        let response = await RemoteRoutes.route(request, RemoteServer.Caller(device: "d1", connection: 1), store.remote)
        return RemoteServer.compressed(response, for: request)
    }
}

enum Measure {
    static func record(_ name: String, before: Int, after: Int) {
        FileHandle.standardError.write(Data("MEASURE \(name): before \(before) B, after \(after) B\n".utf8))
    }
}

@MainActor @Test func openingAVeryLongSessionCostsAFewKilobytes() async throws {
    let heavy = try HeavySession(turns: 150)
    #expect(heavy.fileBytes > 15 << 20)
    let route = "v1/sessions/\(heavy.session)/transcript"

    let old = try await heavy.store.sessions.remoteReply(["show", "--format", "remote", "--limit", "50", "--", heavy.session])
    let before = try JSONEncoder().encode(try RemoteTranscript.page(old)).count

    let open = await heavy.get(route)
    let plain = await heavy.get(route, gzip: false)
    let page = try JSONDecoder().decode(TranscriptPage.self, from: plain.body)
    let newest = try #require(page.messages.last)
    Measure.record("open a \(heavy.fileBytes >> 20) MB session, newest page", before: before, after: open.body.count)
    #expect(open.status == 200 && open.headers["Content-Encoding"] == "gzip")
    #expect(plain.body.count < 130 << 10, "a page is cut at its byte budget, not its row count")
    #expect(open.body.count < 48 << 10)
    #expect(page.before != nil && !page.messages.isEmpty && newest.seq == page.count - 1)

    let earlier = await heavy.get("\(route)?before=\(try #require(page.before).raw)")
    #expect(earlier.status == 200 && earlier.body.count < 48 << 10)

    let idle = await heavy.get("\(route)?after=\(page.after.raw)")
    Measure.record("resume from a cursor, nothing new", before: before, after: idle.body.count)
    #expect(idle.body.count < 600)

    let tag = try #require(open.headers["ETag"])
    let again = await heavy.get(route, etag: tag)
    #expect(again.status == 304 && again.body.isEmpty)
}

private actor Heard {
    var texts = 0, binaries = 0, snapshots = 0
    func note(_ message: SocketMessage, snapshot: Bool) {
        switch message {
        case .text: texts += 1
        case .data: binaries += 1
        }
        if snapshot { snapshots += 1 }
    }
}

@MainActor @Test func aSnapshotOfFortySessionsIsAFewKilobytesToAPhoneThatTakesGzip() async throws {
    let keychain = try TestKeychain()
    let identity = try #require(try keychain.store.identity())
    let base = try JSONSerialization.jsonObject(with: Fixtures.data("RemoteSession.working")) as? [String: Any] ?? [:]
    let sessions = try (0..<40).map { index -> RemoteSession in
        var row = base
        row["id"] = "s\(index)-\(UUID().uuidString)"
        row["title"] = "Session \(index): fix the flaky build in module \(index)"
        row["context"] = 40_000 + index * 1_000
        return try JSONDecoder().decode(RemoteSession.self, from: JSONSerialization.data(withJSONObject: row))
    }
    var sizes: [Bool: Int] = [:]
    for gzip in [false, true] {
        let server = RemoteServer(identity: identity, epoch: "e1") { _, _ in HTTPResponse(status: 404) }
        let hub = EventHub(queue: server.queue, epoch: "e1", snapshot: { { seq, epoch in StateSnapshot(seq: seq, epoch: epoch, sessions: sessions) } }, hello: {
            Hello(app: "", build: 0, mac: MacInfo(id: "", name: ""), capabilities: [], epoch: "e1", serverTime: 0, remoteOn: true,
                  endpoints: Endpoints(tailnet: ""), keyID: "")
        })
        server.opened = { peer in hub.attach(peer) }
        let token = DeviceToken.make()
        server.setDevices([(id: "d1", hash: DeviceToken.hash(token))])
        let port = freePort()
        server.serve(addresses: ["127.0.0.1"], port: port)
        defer { server.stop() }
        await eventually { server.listenerStates.values.first == .ready }
        _ = Traffic.shared.drain()

        var request = URLRequest(url: try #require(URL(string: "wss://127.0.0.1:\(port)/v1/ws/events")))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSessionTransport(trust: PinnedTrust(.pinned(identity.spkiHash.base64URL))).socket(request)
        let heard = Heard()
        Task {
            while let message = try? await socket.receive() {
                let text: String? = switch message {
                case .text(let text): text
                case .data(let packed): Gzip.decompress(packed).map { String(decoding: $0, as: UTF8.self) }
                }
                await heard.note(message, snapshot: text?.contains("\"type\":\"snapshot\"") == true)
            }
        }
        var capabilities: Set<Capability> = [.events]
        if gzip { capabilities.insert(.gzip) }
        try await socket.send(.text(String(decoding: try JSONEncoder().encode(ClientMessage.hello(epoch: nil, lastSeq: nil, capabilities: capabilities)), as: UTF8.self)))
        #expect(await eventually { await heard.snapshots == 1 })
        let sent = Traffic.shared.drain()["WS /v1/ws/events"]?.sent ?? 0
        sizes[gzip] = sent
        #expect(gzip == (await heard.binaries == 1), "only a phone that asked gets a binary frame")
        socket.close(code: 1000, reason: nil)
    }
    Measure.record("first connect, 40 sessions (snapshot)", before: sizes[false] ?? 0, after: sizes[true] ?? 0)
    #expect((sizes[true] ?? .max) < 12 << 10 && (sizes[true] ?? .max) * 5 < (sizes[false] ?? 0))
}
