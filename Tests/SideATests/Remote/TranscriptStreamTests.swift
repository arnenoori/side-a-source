import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import SideAProtocolFixtures
import SideARemoteKit
import Testing

/// What came in on the events socket.
private actor Inbox {
    var events: [ServerEvent] = []
    func add(_ event: ServerEvent) { events.append(event) }
    var appended: [String] {
        events.flatMap { event -> [String] in
            guard case .transcriptAppend(let delta) = event else { return [] }
            return delta.messages.compactMap(\.text)
        }
    }
    var cursor: Cursor? {
        events.reversed().lazy.compactMap { event -> Cursor? in
            if case .transcriptAppend(let delta) = event { return delta.cursor }
            return nil
        }.first
    }
}

@MainActor
private func soon(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

private func say(_ text: String, uuid: String, session: String, to home: URL) throws {
    let line: [String: Any] = ["type": "user", "uuid": uuid, "sessionId": session, "timestamp": "\(TranscriptFixture.today)T10:01:00Z", "cwd": "/tmp/app",
                               "message": ["role": "user", "content": [["type": "text", "text": text]]]]
    let file = home.appendingPathComponent(".claude/projects/-fixture/\(session).jsonl")
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: line) + Data("\n".utf8))
    try handle.close()
}

/// A phone subscribed to a session gets what it missed at once, then each new message as the transcript grows,
/// through the real listener, the hub and the bridge.
@MainActor @Test func aSubscribedPhoneCatchesUpThenHearsNewMessages() async throws {
    let keychain = try TestKeychain()
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sidea-stream-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    try TranscriptFixture.write(TranscriptFixture.lines(session: "t1", cwd: "/tmp/app", day: TranscriptFixture.today), session: "t1", home: home)
    let index = home.appendingPathComponent("Side A")
    TranscriptFixture.index(home: home, root: index)
    let store = AccountStore(demo: true)
    store.sessions.transcriptSource = (home: home, bridge: TranscriptFixture.bridge, python: "/usr/bin/python3", root: index)

    let identity = try #require(try keychain.store.identity())
    let server = RemoteServer(identity: identity, epoch: "e1") { _, _ in HTTPResponse(status: 404) }
    let hub = EventHub(queue: server.queue, epoch: "e1", snapshot: { { seq, epoch in StateSnapshot(seq: seq, epoch: epoch) } }, hello: {
        Hello(app: "", build: 0, mac: MacInfo(id: "", name: ""), capabilities: [], epoch: "e1", serverTime: 0, remoteOn: true,
              endpoints: Endpoints(tailnet: ""), keyID: "")
    })
    server.opened = { peer in hub.attach(peer) }
    let stream = TranscriptStream(store: store, hub: hub)
    defer { stream.stop() }
    let token = DeviceToken.make()
    server.setDevices([(id: "d1", hash: DeviceToken.hash(token))])
    let port = freePort()
    server.serve(addresses: ["127.0.0.1"], port: port)
    defer { server.stop() }
    for _ in 0..<250 where server.listenerStates.values.first != .ready { try await Task.sleep(for: .milliseconds(20)) }

    // The cursor the phone holds; then a message arrives while it's away.
    let page = try RemoteTranscript.page(try await store.sessions.remoteReply(["show", "--format", "remote", "--limit", "50", "--", "t1"]))
    try say("Away message", uuid: "u9", session: "t1", to: home)

    var request = URLRequest(url: URL(string: "wss://127.0.0.1:\(port)/v1/ws/events")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let socket = URLSessionTransport(trust: PinnedTrust(.pinned(identity.spkiHash.base64URL))).socket(request)
    let inbox = Inbox()
    Task {
        while let message = try? await socket.receive() {
            guard case .text(let text) = message, let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: Data(text.utf8)) else { continue }
            await inbox.add(envelope.event)
        }
    }
    func send(_ message: ClientMessage) async throws { try await socket.send(.text(String(decoding: try JSONEncoder().encode(message), as: UTF8.self))) }
    try await send(.hello(epoch: nil, lastSeq: nil, capabilities: [.events, .transcriptStream]))
    #expect(await soon { await inbox.events.contains { if case .snapshot = $0 { true } else { false } } })

    try await send(.subscribe(sessions: ["t1": page.after]))
    #expect(await soon { await inbox.appended == ["Away message"] })

    try say("Live message", uuid: "u10", session: "t1", to: home)
    let live = await soon { await inbox.appended == ["Away message", "Live message"] }
    let heard = await inbox.events
    #expect(live, "\(heard)")
    // Each delta's cursor is what the phone pages from next: nothing past it.
    let after = try #require(await inbox.cursor)
    let rest = try RemoteTranscript.page(try await store.sessions.remoteReply(["show", "--format", "remote", "--after", after.raw, "--", "t1"]))
    #expect(rest.messages.isEmpty && !rest.reset)

    // A transcript rewritten from its head is a new view: the phone starts over.
    var lines = TranscriptFixture.lines(session: "t1", cwd: "/tmp/app", day: TranscriptFixture.today)
    lines[0]["uuid"] = "u0-rewritten"
    try TranscriptFixture.write(lines, session: "t1", home: home)
    #expect(await soon { await inbox.events.contains { if case .transcriptReset(let session, _) = $0 { session == "t1" } else { false } } })
    socket.close(code: 1000, reason: nil)
}

/// Twenty 64 KiB rows go out as two appends; a phone cut off after the first resumes from before the page.
@MainActor @Test func onlyAPagesLastEventCarriesItsCursor() throws {
    var page = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("TranscriptPage.after-replaced")) as? [String: Any])
    let row = try #require((page["messages"] as? [[String: Any]])?.first)
    page["messages"] = (0..<20).map { index in
        row.merging(["seq": 900 + index, "uuid": UUID().uuidString, "text": String(repeating: "x", count: 64 * 1024)]) { $1 }
    }
    let decoded = try JSONDecoder().decode(TranscriptPage.self, from: JSONSerialization.data(withJSONObject: page))
    let from = Cursor("a41f09c2e7b3.813.0")
    let events = TranscriptStream.events(decoded, session: decoded.sessionID, from: from)
    let cursors = events.map { event -> Cursor? in
        switch event {
        case .transcriptAppend(let delta), .transcriptReplace(let delta): delta.cursor
        default: nil
        }
    }
    #expect(events.count == 3)
    #expect(cursors == [from, from, decoded.after])
}

/// A snapshot too big for the socket comes over REST instead of closing it with 4008 again and again.
@MainActor @Test func aLargeSnapshotIsLeftForGETState() async throws {
    let keychain = try TestKeychain()
    let identity = try #require(try keychain.store.identity())
    let one = try JSONDecoder().decode(HostedSession.self, from: Fixtures.data("HostedSession.alive"))
    let server = RemoteServer(identity: identity, epoch: "e1") { _, _ in HTTPResponse(status: 404) }
    let hub = EventHub(queue: server.queue, epoch: "e1", snapshot: { { seq, epoch in
        StateSnapshot(seq: seq, epoch: epoch, hosted: Array(repeating: one, count: 3_000))
    } }, hello: {
        Hello(app: "", build: 0, mac: MacInfo(id: "", name: ""), capabilities: [], epoch: "e1", serverTime: 0, remoteOn: true,
              endpoints: Endpoints(tailnet: ""), keyID: "")
    })
    server.opened = { peer in hub.attach(peer) }
    let token = DeviceToken.make()
    server.setDevices([(id: "d1", hash: DeviceToken.hash(token))])
    let port = freePort()
    server.serve(addresses: ["127.0.0.1"], port: port)
    defer { server.stop() }
    for _ in 0..<250 where server.listenerStates.values.first != .ready { try await Task.sleep(for: .milliseconds(20)) }

    var request = URLRequest(url: URL(string: "wss://127.0.0.1:\(port)/v1/ws/events")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let socket = URLSessionTransport(trust: PinnedTrust(.pinned(identity.spkiHash.base64URL))).socket(request)
    let inbox = Inbox()
    Task {
        while let message = try? await socket.receive() {
            guard case .text(let text) = message, let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: Data(text.utf8)) else { continue }
            await inbox.add(envelope.event)
        }
    }
    try await socket.send(.text(String(decoding: try JSONEncoder().encode(ClientMessage.hello(epoch: nil, lastSeq: nil, capabilities: [.events])), as: UTF8.self)))
    #expect(await soon { await inbox.events.contains { if case .welcome(let welcome) = $0 { welcome.snapshotOverREST } else { false } } })
    try await Task.sleep(for: .milliseconds(300))
    #expect(await !inbox.events.contains { if case .snapshot = $0 { true } else { false } })
}
