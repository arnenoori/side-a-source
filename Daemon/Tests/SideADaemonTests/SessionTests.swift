import Foundation
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

/// A real tmux and a real Python bridge, with a stand-in for Claude Code that registers itself and writes a transcript.
/// Skipped where there is no tmux or python3.
private struct Rig {
    let home: URL
    let work: URL
    let socket: String
    let settings: SessionServices.Settings
    let book: AccountBook

    static var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    static var available: Bool {
        guard Run.which("tmux") != nil, Run.which("python3") != nil else { return false }
        return FileManager.default.fileExists(atPath: repository.appendingPathComponent("bridge/sidea_bridge.py").path)
    }

    init() throws {
        home = try temporaryDirectory("sh")
        work = home.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        socket = home.appendingPathComponent("t.sock").path
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["SIDE_A_TMUX_SOCKET"] = socket
        environment["SIDEAD_BRIDGE"] = Self.repository.appendingPathComponent("bridge").path
        environment["FAKE_CLAUDE_WORK"] = "0.5"
        environment["TERM"] = "xterm-256color"
        var settings = SessionServices.Settings(root: home.appendingPathComponent("root"), projects: [work.path])
        settings.environment = environment
        let fake = Self.repository.appendingPathComponent("Daemon/Tests/Fixtures/fake-claude-live.py").path
        settings.agents[.claude] = "python3 \(fake)"
        settings.poll = .milliseconds(300)
        let book = AccountBook(state: home.appendingPathComponent("state"), home: home)
        settings.environment["SIDEAD_CLAUDE_DIRS_FILE"] = book.foldersFile.path
        settings.accountEnvironment = { [accounts = AccountsService(book: book)] in await accounts.environment(for: $0) }
        self.book = book
        self.settings = settings
    }

    func services() throws -> SessionServices {
        let location = try #require(BridgeLocation.find(environment: settings.environment))
        return try #require(SessionServices(settings: settings, location: location))
    }

    func cleanUp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Run.which("tmux") ?? "/usr/bin/tmux")
        process.arguments = ["-S", socket, "kill-server"]
        // swiftlint:disable:next swallowed_try -- cleanup: with no tmux there is no server to stop.
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: home)
    }
}


private func call(_ connection: TestConnection, _ method: String, _ path: String, token: String, body: Data = Data(), key: String? = nil, confirm: String? = nil) async throws -> Answer {
    var headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json"]
    if let key { headers["Idempotency-Key"] = key }
    if let confirm { headers[ConfirmSignature.header] = confirm }
    return try await connection.request(method, path, headers: headers, body: body)
}

@Test(.enabled(if: Rig.available)) func aPhoneStartsASessionRepliesAndReadsTheTranscript() async throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    try await withDaemon(services: try rig.services()) { daemon, _ in
        let phone = FakePhone()
        let pin = daemon.identity.spkiHash
        let paired = try await phone.pair(with: daemon, pin: pin)
        let connection = try await TestConnection.open(port: daemon.port, pin: pin)
        let token = paired.token
        let hello = try await connection.request("GET", "/v1/hello", headers: ["Authorization": "Bearer \(token)"]).json(Hello.self)
        #expect(hello.capabilities.contains(.hosted) && hello.capabilities.contains(.transcriptStream))

        let start = StartHosted(cwd: rig.work.path, agent: .claude, prompt: "hello fake")
        let body = try JSONEncoder().encode(start)
        let unsigned = try await call(connection, "POST", "/v1/hosted", token: token, body: body, key: "start-1")
        #expect(unsigned.status == 401 && unsigned.errorCode == "confirm_required")
        let signed = try phone.confirm(purpose: .settings, subject: try ConfirmMessage.subject(start: start))
        let started = try await call(connection, "POST", "/v1/hosted", token: token, body: body, key: "start-2", confirm: signed)
        #expect(started.status == 201)
        let hosted = try started.json(HostedSession.self)
        #expect(hosted.name.hasPrefix("sa-") && hosted.alive)

        var session: RemoteSession?
        #expect(await eventually(30) {
            guard let list = try? await call(connection, "GET", "/v1/sessions", token: token).json(SessionList.self) else { return false }
            session = list.sessions.first { $0.hosted == hosted.name && $0.conversationID != nil && $0.status == .idle }
            return session != nil
        })
        let live = try #require(session)
        #expect(live.abilities.contains(.type) && live.abilities.contains(.transcript))
        // tmux reports the folder with its links resolved (/tmp is /private/tmp on a Mac).
        #expect(live.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == rig.work.resolvingSymlinksInPath().path)

        func transcript() async throws -> TranscriptPage {
            try await call(connection, "GET", "/v1/sessions/\(live.id)/transcript", token: token).json(TranscriptPage.self)
        }
        #expect(await eventually(20) { ((try? await transcript())?.messages.count ?? 0) >= 2 })
        #expect(try await transcript().messages.last?.text == "Echo: hello fake")

        let socket = try await TestConnection.open(port: daemon.port, pin: pin)
        #expect(try await socket.upgrade("/v1/ws/events", token: token).status == 101)
        try await socket.send(text: String(decoding: try JSONEncoder().encode(ClientMessage.hello(epoch: nil, lastSeq: nil, capabilities: [.events])), as: UTF8.self))
        _ = try await socket.event(); _ = try await socket.event()
        try await socket.send(text: String(decoding: try JSONEncoder().encode(ClientMessage.subscribe(sessions: [live.id: nil])), as: UTF8.self))
        let reply = RemoteReply(text: "second one")
        let replyBody = try JSONEncoder().encode(reply)
        let refused = try await call(connection, "POST", "/v1/sessions/\(live.id)/reply", token: token, body: replyBody, key: "reply-1")
        #expect(refused.status == 401)
        let proof = try phone.confirm(purpose: .action, subject: try ConfirmMessage.subject(action: .reply, target: live.id, body: reply), biometric: true)
        let typed = try await call(connection, "POST", "/v1/sessions/\(live.id)/reply", token: token, body: replyBody, key: "reply-2", confirm: proof)
        #expect(typed.status == 200)
        #expect(try typed.json(ReplyResult.self).delivery == .typed)

        var appended = false
        // swiftlint:disable:next unbounded_poll_in_tests -- not a poll: `event()` blocks and the loop ends when the socket closes.
        while !appended, let event = try? await socket.event() {
            if event["type"] as? String == "transcript.append",
               let messages = (event["data"] as? [String: Any])?["messages"] as? [[String: Any]],
               messages.contains(where: { ($0["text"] as? String) == "Echo: second one" }) { appended = true }
        }
        #expect(appended)
        #expect(await eventually(10) { ((try? await transcript())?.messages.count ?? 0) == 4 })

        let list = try await call(connection, "GET", "/v1/hosted", token: token).json(HostedList.self)
        #expect(list.hosted.map(\.name) == [hosted.name])
        let end = try phone.confirm(purpose: .action, subject: ConfirmMessage.subject(action: .endHosted, target: hosted.name))
        #expect(try await call(connection, "DELETE", "/v1/hosted/\(hosted.name)", token: token, key: "end-1", confirm: end).status == 204)
        #expect(await eventually(10) { ((try? await call(connection, "GET", "/v1/hosted", token: token).json(HostedList.self))?.hosted.isEmpty) == true })
        await socket.close(); await connection.close()
    }
}

@Test(.enabled(if: Rig.available)) func aSessionStartedOnAnotherAccountRunsInThatAccountsFolderAndIsStillSeen() async throws {
    let rig = try Rig()
    defer { rig.cleanUp() }
    let account = try rig.book.add("Second")
    try await withDaemon(services: try rig.services()) { daemon, _ in
        let phone = FakePhone()
        let pin = daemon.identity.spkiHash
        let paired = try await phone.pair(with: daemon, pin: pin)
        let connection = try await TestConnection.open(port: daemon.port, pin: pin)
        let token = paired.token
        let unknown = StartHosted(cwd: rig.work.path, agent: .claude, accountID: "nobody")
        let refused = try await call(connection, "POST", "/v1/hosted", token: token, body: try JSONEncoder().encode(unknown), key: "a-0",
                                     confirm: try phone.confirm(purpose: .settings, subject: try ConfirmMessage.subject(start: unknown)))
        #expect(refused.status == 404)
        let start = StartHosted(cwd: rig.work.path, agent: .claude, accountID: account.id, prompt: "on the second account")
        let started = try await call(connection, "POST", "/v1/hosted", token: token, body: try JSONEncoder().encode(start), key: "a-1",
                                     confirm: try phone.confirm(purpose: .settings, subject: try ConfirmMessage.subject(start: start)))
        #expect(started.status == 201)
        let hosted = try started.json(HostedSession.self)
        // Claude Code, given CLAUDE_CONFIG_DIR, keeps its registry and transcript there; the bridge still finds them.
        #expect(await eventually(30) {
            guard let list = try? await call(connection, "GET", "/v1/sessions", token: token).json(SessionList.self) else { return false }
            return list.sessions.contains { $0.hosted == hosted.name && $0.conversationID != nil && $0.status == .idle }
        })
        let registered = try FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: account.configDir).appendingPathComponent("sessions").path)
        #expect(registered.count == 1)
        #expect(!FileManager.default.fileExists(atPath: rig.home.appendingPathComponent(".claude/sessions").path)
                || ((try? FileManager.default.contentsOfDirectory(atPath: rig.home.appendingPathComponent(".claude/sessions").path)) ?? []).isEmpty)
        let sessions = try await call(connection, "GET", "/v1/sessions", token: token).json(SessionList.self)
        let live = try #require(sessions.sessions.first { $0.hosted == hosted.name })
        let page = try await call(connection, "GET", "/v1/sessions/\(live.id)/transcript", token: token).json(TranscriptPage.self)
        #expect(page.messages.last?.text == "Echo: on the second account")
        await connection.close()
    }
}
