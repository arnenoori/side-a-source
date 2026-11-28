import Foundation
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

/// Two of the user's computers in one test: each its own home, state folder, tmux server and bridge root, linked over
/// real pinned TLS on loopback. The agent is the stand-in `fake-claude-live.py`; nothing here reaches the real `claude`
/// or `codex`, or the real `~/.claude` and `~/.codex`. Skipped where tmux, git or python3 is missing.
struct Machine {
    let name: String
    let hostID = "host-" + UUID().uuidString.lowercased()
    let home: URL
    let state: URL
    let socket: String
    /// One line for each time the stand-in agent started here.
    let starts: URL
    let book: AccountBook
    var settings: SessionServices.Settings
    let hooks = MoveHooks()
    /// A relay the daemon holds its tunnel to; none unless a test sets one.
    var relay: RelayConfig?
    var landing: URL { home.appendingPathComponent("Side A") }
    var ownFolder: URL { home.appendingPathComponent(".claude") }

    static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var available: Bool {
        guard Run.which("tmux") != nil, Run.which("python3") != nil, Run.which("git") != nil else { return false }
        return FileManager.default.fileExists(atPath: repository.appendingPathComponent("bridge/sidea_bridge.py").path)
    }

    init(_ name: String, projects: [String] = []) throws {
        self.name = name
        // Resolved, as the CLI and tmux report the folders a session runs in.
        home = URL(fileURLWithPath: DaemonMoves.real(try temporaryDirectory("mv").path))
        state = home.appendingPathComponent("state")
        socket = home.appendingPathComponent("t.sock").path
        starts = home.appendingPathComponent("starts.jsonl")
        // Nothing of the session running these tests: its Claude Code, Codex and Side A settings would point the agents,
        // the bridge and git at the real ones.
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !["CLAUDE", "CODEX", "ANTHROPIC", "SIDE_A", "SIDEAD", "GIT_"].contains { key.hasPrefix($0) }
        }
        environment["HOME"] = home.path
        environment["SIDE_A_TMUX_SOCKET"] = socket
        environment["SIDEAD_BRIDGE"] = Self.repository.appendingPathComponent("bridge").path
        environment["FAKE_CLAUDE_WORK"] = "0.3"
        environment["FAKE_CLAUDE_STARTS"] = starts.path
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["TERM"] = "xterm-256color"
        let book = AccountBook(state: state, home: home)
        environment["SIDEAD_CLAUDE_DIRS_FILE"] = book.foldersFile.path
        var settings = SessionServices.Settings(root: home.appendingPathComponent("root"), projects: projects)
        settings.environment = environment
        settings.agents[.claude] = "python3 \(Self.repository.appendingPathComponent("Daemon/Tests/Fixtures/fake-claude-live.py").path)"
        settings.poll = .milliseconds(300)
        settings.accountEnvironment = { [accounts = AccountsService(book: book)] in await accounts.environment(for: $0) }
        settings.moves = hooks
        self.book = book
        self.settings = settings
    }

    /// Signs `folder` (this computer's own Claude folder unless given) in to Claude Code as `email`, the way Claude Code
    /// leaves it: `.credentials.json`, and who it is in `.claude.json`.
    @discardableResult
    func signIn(_ email: String, folder: URL? = nil) throws -> Data {
        let folder = folder ?? ownFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let login = Data(#"{"claudeAiOauth":{"accessToken":"test-access-\#(UUID().uuidString)","refreshToken":"test-refresh","expiresAt":4102444800000,"subscriptionType":"max"}}"#.utf8)
        try login.write(to: folder.appendingPathComponent(".credentials.json"))
        let record = folder == ownFolder ? home.appendingPathComponent(".claude.json") : folder.appendingPathComponent(".claude.json")
        try Data(#"{"oauthAccount":{"emailAddress":"\#(email)"}}"#.utf8).write(to: record)
        return login
    }

    func git(_ arguments: [String], in folder: URL) async throws {
        let result = await Run.process(try #require(Run.which("git")), ["-C", folder.path] + arguments, environment: settings.environment)
        try #require(result.status == 0, "git \(arguments.first ?? ""): \(result.errors)")
    }

    /// A repository with one commit, a tracked file changed since and a file git doesn't know yet.
    func project(_ name: String = "app") async throws -> URL {
        let folder = home.appendingPathComponent("work/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"], in: folder)
        try Data("one\n".utf8).write(to: folder.appendingPathComponent("README.md"))
        try await git(["add", "README.md"], in: folder)
        try await git(["-c", "user.name=you", "-c", "user.email=you@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "First"], in: folder)
        try Data("one\ntwo\n".utf8).write(to: folder.appendingPathComponent("README.md"))
        try Data("not committed\n".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        return folder
    }

    /// The times the stand-in agent was started here to continue `conversation`.
    func resumes(_ conversation: String) -> Int {
        let text = (try? String(contentsOf: starts, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { $0.contains("\"--resume\", \"\(conversation)\"") }.count
    }

    func cleanUp() async {
        if let tmux = Run.which("tmux") { _ = await Run.process(tmux, ["-S", socket, "kill-server"], environment: settings.environment) }
        try? FileManager.default.removeItem(at: home)
    }
}

/// A computer while its daemon runs.
struct Running {
    let machine: Machine
    let daemon: SideADaemon
    let sessions: SessionServices
    let service: MoveServices
    var moves: DaemonMoves { service.moves }
    var engine: SessionEngine { sessions.engine }

    /// Starts a hosted session in `folder` with `prompt` and waits until it has answered and is idle.
    func host(_ folder: URL, prompt: String, account: StoredAccount? = nil) async throws -> LiveRow {
        var start = HostedTmux.Start(agent: .claude, cwd: folder.path, mode: .new(model: nil))
        start.arguments = Hosting.arguments(.claude, start.mode)
        start.prompt = prompt
        if let account {
            start.environment = ["CLAUDE_CONFIG_DIR": account.configDir]
            start.account = account.id
        }
        let name = try await engine.tmux.start(start)
        var row: LiveRow?
        let answered = await eventually(30) {
            row = await engine.live().first { $0.hosted == name && $0.id != nil && $0.status == "idle" }
            return row.map { transcript(of: $0, account: account)?.contains("Echo: \(prompt)") == true } ?? false
        }
        #expect(answered)
        // Idle again after the answer was written, not before the prompt was read.
        #expect(await eventually(10) { await engine.live().contains { $0.hosted == name && $0.status == "idle" } })
        return try #require(await engine.live().first { $0.hosted == name })
    }

    func transcript(of row: LiveRow, account: StoredAccount? = nil) -> String? {
        guard let id = row.id, let cwd = row.cwd else { return nil }
        let folder = account.map { URL(fileURLWithPath: $0.configDir) } ?? machine.ownFolder
        let slug = cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        return try? String(contentsOf: folder.appendingPathComponent("projects/\(slug)/\(id).jsonl"), encoding: .utf8)
    }

    func running(_ conversation: String) async -> LiveRow? { await engine.live().first { $0.id == conversation } }
}

func withComputers<T>(_ machines: [Machine], _ body: ([Running]) async throws -> T) async throws -> T {
    var running: [Running] = []
    func stopAll() async {
        for computer in running {
            // swiftlint:disable:next swallowed_try -- the test's own result is what is reported.
            try? await computer.daemon.stop()
        }
        for machine in machines { await machine.cleanUp() }
    }
    do {
        for machine in machines { running.append(try await start(machine)) }
        let result = try await body(running)
        await stopAll()
        return result
    } catch {
        await stopAll()
        throw error
    }
}

/// A daemon for `machine` on port 0 (or `port`), with its sessions and moves; again on the same state folder after a stop.
func start(_ machine: Machine, port: Int = 0) async throws -> Running {
    let location = try #require(BridgeLocation.find(environment: machine.settings.environment))
    let sessions = try #require(SessionServices(settings: machine.settings, location: location))
    let service = MoveServices(state: machine.state, sessions: sessions, book: machine.book, landing: machine.landing,
                               repositories: machine.settings.projects, location: location, settleEvery: .seconds(3600), standbyEvery: .seconds(3600))
    var config = DaemonConfig(paths: DaemonPaths(state: machine.state))
    config.port = port
    config.discover = false
    config.relay = machine.relay
    config.os = .linux
    config.name = machine.name
    config.hostID = machine.hostID
    let daemon = try SideADaemon(config: config, services: CombinedServices([sessions, service]))
    try await daemon.start()
    return Running(machine: machine, daemon: daemon, sessions: sessions, service: service)
}

/// `a` links to `b` as a Mac does: it pairs with `b` as a computer (someone at `b` confirms the digits), keeps the token,
/// and sends `b` the way back.
@discardableResult
func link(_ a: Running, to b: Running) async throws -> PairResponse {
    let client = FakePhone(name: a.machine.name, capabilities: [.computer, .moves])
    let pin = b.daemon.identity.spkiHash
    let paired = try await client.pair(with: b.daemon, pin: pin)
    _ = try await a.moves.link(paired: paired, endpoints: b.daemon.hello(paired: true).endpoints, pin: pin, secret: client.secret,
                               confirm: client.biometric.rawRepresentation, unlock: client.unlock.rawRepresentation)
    return paired
}

private func call(_ connection: TestConnection, _ method: String, _ path: String, token: String, body: Data = Data(), key: String? = nil,
                  confirm: String? = nil) async throws -> Answer {
    var headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json"]
    if let key { headers["Idempotency-Key"] = key }
    if let confirm { headers[ConfirmSignature.header] = confirm }
    return try await connection.request(method, path, headers: headers, body: body)
}

/// A link that loses the answer to `commit`: the request arrives and runs, the reply never comes back.
struct LosingPeer: MovePeer {
    let inner: any MovePeer
    var id: String { inner.id }
    var name: String { inner.name }
    func offer(_ offer: MoveOffer) async throws -> MoveAnswer { try await inner.offer(offer) }
    func part(_ move: String, _ name: String, _ index: Int, _ data: Data) async throws { try await inner.part(move, name, index, data) }
    func stage(_ move: String, _ stage: MoveStage) async throws -> MoveState { try await inner.stage(move, stage) }
    func commit(_ move: String, _ commit: MoveCommit) async throws -> MoveState {
        _ = try await inner.commit(move, commit)
        throw PeerFailure.noAnswer
    }
    func abort(_ move: String) async throws -> MoveState { try await inner.abort(move) }
    func state(_ move: String) async throws -> MoveState { try await inner.state(move) }
}

/// A link to a computer whose checkout disappears between `stage` and `commit`, so the session can't start there.
private struct BreakingPeer: MovePeer {
    let inner: any MovePeer
    let breaks: URL
    var id: String { inner.id }
    var name: String { inner.name }
    func offer(_ offer: MoveOffer) async throws -> MoveAnswer { try await inner.offer(offer) }
    func part(_ move: String, _ name: String, _ index: Int, _ data: Data) async throws { try await inner.part(move, name, index, data) }
    func stage(_ move: String, _ stage: MoveStage) async throws -> MoveState { try await inner.stage(move, stage) }
    func commit(_ move: String, _ commit: MoveCommit) async throws -> MoveState {
        try? FileManager.default.removeItem(at: breaks)
        return try await inner.commit(move, commit)
    }
    func abort(_ move: String) async throws -> MoveState { try await inner.abort(move) }
    func state(_ move: String) async throws -> MoveState { try await inner.state(move) }
}

private func codexAuth(_ email: String) -> Data {
    let claims = Data(#"{"email":"\#(email)"}"#.utf8).base64URL
    return Data(#"{"tokens":{"id_token":"e30.\#(claims).sig","access_token":"test-access"}}"#.utf8)
}

@Suite(.serialized, .enabled(if: Machine.available)) struct MoveTests {
    @Test func aSessionMovesFromThePhoneOverPinnedTLSWithItsUncommittedWorkAndThenRunsOnlyThere() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let row = try await a.host(folder, prompt: "hello there")
            let conversation = try #require(row.id)

            let phone = FakePhone()
            let pin = a.daemon.identity.spkiHash
            let token = try await phone.pair(with: a.daemon, pin: pin).token
            let connection = try await TestConnection.open(port: a.daemon.port, pin: pin)
            let hello = try await connection.request("GET", "/v1/hello", headers: ["Authorization": "Bearer \(token)"]).json(Hello.self)
            #expect(hello.capabilities.contains(.moves))
            let listed = try await call(connection, "GET", "/v1/computers", token: token).json(ComputerList.self)
            #expect(listed.computers.map(\.id) == [b.machine.hostID] && listed.computers.first?.name == "spare-box")
            var session: RemoteSession?
            #expect(await eventually(10) {
                session = (try? await call(connection, "GET", "/v1/sessions", token: token).json(SessionList.self))?.sessions.first { $0.conversationID == conversation }
                return session?.abilities.contains(.move) == true
            })
            let id = try #require(session?.id)

            let request = MoveRequest(computer: b.machine.hostID)
            let body = try JSONEncoder().encode(request)
            let previewed = try await call(connection, "POST", "/v1/sessions/\(id)/move/preview", token: token, body: body, key: "preview-1")
            #expect(previewed.status == 200)
            let preview = try previewed.json(MovePreview.self)
            #expect(preview.computer.id == b.machine.hostID && preview.login == .there)
            #expect(preview.landing == b.machine.landing.appendingPathComponent("app").path)
            // Asking stopped nothing.
            #expect(await a.running(conversation) != nil)

            let unsigned = try await call(connection, "POST", "/v1/sessions/\(id)/move", token: token, body: body, key: "move-1")
            #expect(unsigned.status == 401)
            let unlockOnly = try phone.confirm(purpose: .action, subject: try ConfirmMessage.subject(action: .moveSession, target: id, body: request),
                                               macID: a.machine.hostID)
            #expect(try await call(connection, "POST", "/v1/sessions/\(id)/move", token: token, body: body, key: "move-2", confirm: unlockOnly).status == 401)
            let proof = try phone.confirm(purpose: .action, subject: try ConfirmMessage.subject(action: .moveSession, target: id, body: request),
                                          biometric: true, macID: a.machine.hostID)
            let moving = try await call(connection, "POST", "/v1/sessions/\(id)/move", token: token, body: body, key: "move-3", confirm: proof)
            #expect(moving.status == 202)
            let record = try moving.json(MoveRecord.self)
            #expect(record.state == .moving && record.computerName == "spare-box")
            var last: MoveRecord?
            #expect(await eventually(120) {
                last = (try? await call(connection, "GET", "/v1/moves", token: token).json(MoveList.self))?.moves.first { $0.id == record.id }
                return last?.state == .away
            })
            #expect(last?.session != nil)

            // It runs on the other computer, in a new checkout with the work that wasn't committed, continuing the same
            // conversation from the transcript that came with it.
            let there = try #require(await b.running(conversation))
            let landed = try #require(there.cwd)
            #expect(landed == b.machine.landing.appendingPathComponent("app").path, "\(landed)")
            #expect(try String(contentsOf: URL(fileURLWithPath: landed).appendingPathComponent("README.md"), encoding: .utf8) == "one\ntwo\n")
            #expect(try String(contentsOf: URL(fileURLWithPath: landed).appendingPathComponent("notes.txt"), encoding: .utf8) == "not committed\n")
            #expect(b.transcript(of: there)?.contains("Echo: hello there") == true)
            #expect(b.machine.resumes(conversation) == 1)

            // And nowhere else: not here, its transcript out of the CLI's reach, and a start of it here refused.
            #expect(await a.running(conversation) == nil)
            // The phone hears it is away once it runs there; the transcript here is put aside just after.
            #expect(await eventually(10) { a.transcript(of: row) == nil })
            #expect(await a.moves.elsewhere(conversation)?.id == b.machine.hostID)
            let resume = StartHosted(cwd: folder.path, agent: .claude, resume: conversation)
            let refused = try await call(connection, "POST", "/v1/hosted", token: token, body: try JSONEncoder().encode(resume), key: "start-1")
            #expect(refused.status == 409 && refused.errorCode == "moved")
            // The checkout it left is as it was.
            #expect(try String(contentsOf: folder.appendingPathComponent("README.md"), encoding: .utf8) == "one\ntwo\n")
            await connection.close()
        }
    }

    @Test func aMovedSessionComesBackToTheComputerItLeftThroughTheCommand() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let conversation = try #require(try await a.host(folder, prompt: "go and come back").id)
            let answer = try #require(await a.service.control("move", ["session": conversation, "computer": "spare-box"]))
            let went = try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
            #expect(went["ok"] as? Bool == true)
            let name = try #require(went["session"] as? String)
            #expect(await b.running(conversation)?.hosted == name)

            // `sidead move` there, back to the computer it came from: it lands beside the repository it left, in a
            // worktree, and the record of it being away is closed.
            let back = try await b.moves.move(name, to: "build-box")
            #expect(back.status == .live)
            let here = try #require(await a.running(conversation))
            #expect(here.cwd?.hasPrefix(folder.appendingPathComponent(".sidea-worktrees").path) == true, "\(here.cwd ?? "")")
            #expect(await b.running(conversation) == nil)
            #expect(await a.moves.ownership(of: conversation).mayRun)
            #expect(await a.moves.elsewhere(conversation) == nil)
            #expect(await b.moves.elsewhere(conversation)?.id == a.machine.hostID)
            let sent = await a.moves.journal.all.filter { $0.session == conversation && $0.role == .source }
            #expect(sent.map(\.step) == [.returned])
            #expect(a.transcript(of: here)?.contains("Echo: go and come back") == true)
            #expect(a.machine.resumes(conversation) == 1 && b.machine.resumes(conversation) == 1)
        }
    }

    @Test func aLostAnswerToTheStartEndsUnknownAndSettlesOnTheOtherComputersWord() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let row = try await a.host(folder, prompt: "lose the answer")
            let conversation = try #require(row.id)
            await a.moves.set(peers: { LosingPeer(inner: LinkedPeer($0)) })
            await #expect(throws: MoveFailure.unknown(peer: "spare-box")) { try await a.moves.move(conversation, to: "spare-box") }
            let id = try #require(await a.moves.journal.all.first { $0.session == conversation }?.id)
            #expect(await a.moves.journal[id]?.step == .unknown)
            #expect(await a.moves.records().first { $0.id == id }?.state == .unknown)
            // It started there; here it is neither restarted nor allowed to be.
            #expect(await b.running(conversation) != nil)
            #expect(await a.running(conversation) == nil)
            #expect(await a.moves.elsewhere(conversation)?.id == b.machine.hostID)

            // The phone asks again: the other computer says it is running there, so it is away.
            let phone = FakePhone()
            let pin = a.daemon.identity.spkiHash
            let token = try await phone.pair(with: a.daemon, pin: pin).token
            let connection = try await TestConnection.open(port: a.daemon.port, pin: pin)
            let checked = try await call(connection, "POST", "/v1/moves/\(id)/check", token: token, key: "check-1")
            #expect(checked.status == 200)
            #expect(try checked.json(MoveRecord.self).state == .away)
            #expect(await a.moves.journal[id]?.step == .away)
            #expect(a.transcript(of: row) == nil)
            #expect(await a.running(conversation) == nil)
            #expect(b.machine.resumes(conversation) == 1)
            #expect(try await call(connection, "POST", "/v1/moves/mv-f0000000001/check", token: token, key: "check-2").status == 404)
            await connection.close()
        }
    }

    @Test func aRepeatedStartStartsNothingTwiceAndNothingStartsAfterADrop() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let conversation = try #require(try await a.host(folder, prompt: "only once").id)
            let moved = try await a.moves.move(conversation, to: "spare-box")
            let id = try #require(await a.moves.journal.all.first { $0.session == conversation }?.id)
            let peer = LinkedPeer(try #require(await a.moves.links.computer(b.machine.hostID)))
            // The same request again (the ledger answers it), another with a new key (the journal does), and a drop
            // after it started (too late: it says it is live).
            let again = try await peer.commit(id, MoveCommit())
            let other = try JSONDecoder().decode(MoveState.self, from: try await peer.call("POST", "/v1/moves/\(id)/commit", body: Data("{}".utf8), key: "\(id)-again").body)
            let dropped = try await peer.abort(id)
            for state in [again, other, dropped] { #expect(state.status == .live && state.session == moved.session) }
            #expect(try await b.moves.commit(id).session == moved.session)
            #expect(b.machine.resumes(conversation) == 1)
            #expect(await b.engine.tmux.list().filter { $0.session == conversation && !$0.dead }.count == 1)

            // A move dropped before its start is never started, even when the start arrives later.
            _ = try await peer.abort("mv-d0000000001")
            await #expect(throws: MoveFailure.self) { try await peer.commit("mv-d0000000001", MoveCommit()) }
            await #expect(throws: MoveFailure.self) { try await peer.commit("mv-e0000000001", MoveCommit()) }
        }
    }

    @Test func theOtherComputerSaysWhichAccountItCanRunTheSessionOn() async throws {
        let machine = try Machine("spare-box")
        try await withComputers([machine]) { computers in
            let moves = computers[0].moves
            let from = MacInfo(id: "host-of-alex", name: "Mac mini", os: .macos)
            var count = 0
            func offer(_ agent: AgentProvider, _ email: String?) async throws -> MoveAnswer.Account? {
                count += 1
                let offer = MoveOffer(id: String(format: "mv-a%08x", count), conversationID: UUID().uuidString.lowercased(), agent: agent, project: "app", commits: [],
                                      from: from, account: email.map { MoveAccount(email: $0, name: "Work") })
                return try await moves.offered(offer, from: "device-of-alex").account
            }
            // Signed in to nothing.
            #expect(try await offer(.claude, "alex@example.com") == .missing)
            await #expect(throws: MoveFailure.self) { try await offer(.claude, nil) }
            #expect(try await offer(.codex, "alex@example.com") == .missing)
            // Signed in, to another account.
            try machine.signIn("you@example.com")
            let codex = machine.home.appendingPathComponent(".codex/auth.json")
            try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
            try codexAuth("you@example.com").write(to: codex)
            #expect(try await offer(.claude, "alex@example.com") == .wanted)
            #expect(try await offer(.codex, "alex@example.com") == .wanted)
            #expect(try await offer(.claude, nil) == nil)
            // Signed in to that account, here as one of the daemon's accounts.
            let work = try machine.book.add("Work")
            try machine.signIn("alex@example.com", folder: URL(fileURLWithPath: work.configDir))
            #expect(try await offer(.claude, "Alex@Example.com") == .here)
            #expect(try await offer(.codex, "you@example.com") == .here)

            // A Codex login arrives only where there is none.
            let logins = await moves.logins
            let arriving = MoveLogin(email: "alex@example.com", name: "alex@example.com", login: String(decoding: codexAuth("alex@example.com"), as: UTF8.self))
            #expect(throws: MoveFailure.self) { try logins.receive(arriving, agent: .codex) }
            try FileManager.default.removeItem(at: codex)
            let mismatched = MoveLogin(email: "you@example.com", name: "you", login: arriving.login)
            #expect(throws: MoveFailure.self) { try logins.receive(mismatched, agent: .codex) }
            #expect(try logins.receive(arriving, agent: .codex).id == DaemonLogins.codex)
            #expect(try FileManager.default.attributesOfItem(atPath: codex.path)[.posixPermissions] as? Int == 0o600)
        }
    }

    @Test func aLoginGoesWithTheSessionAndIsTakenBackWhenTheStartFails() async throws {
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
            let row = try await a.host(folder, prompt: "on the work account", account: work)
            let conversation = try #require(row.id)
            #expect(await a.engine.tmux.account(of: try #require(row.hosted)) == work.id)

            // The other computer is signed in to another account, so the login goes along, and when the session can't
            // start there it is deleted there and put back here, and the session runs here again on it.
            await a.moves.set(peers: { BreakingPeer(inner: LinkedPeer($0), breaks: b.machine.landing) })
            await #expect(throws: MoveFailure.self) { try await a.moves.move(conversation, to: "spare-box") }
            #expect(b.machine.book.load().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: b.machine.book.folders.appendingPathComponent("work").path))
            #expect(await b.running(conversation) == nil)
            #expect(FileManager.default.contents(atPath: credentials.path) == login)
            var again: LiveRow?
            #expect(await eventually(30) { again = await a.running(conversation); return again?.status == "idle" })
            #expect(await a.engine.tmux.account(of: try #require(again?.hosted)) == work.id)
            #expect(await a.moves.journal.all.first { $0.session == conversation }?.step == .returned)

            // Now it starts: the login is stored there in an account of its own, and gone from here.
            await a.moves.set(peers: { LinkedPeer($0) })
            let moved = try await a.moves.move(conversation, to: "spare-box")
            #expect(moved.account == "alex@example.com")
            let stored = try #require(b.machine.book.load().first)
            #expect(stored.email == "alex@example.com" && stored.name == "Work")
            let arrived = URL(fileURLWithPath: stored.configDir).appendingPathComponent(".credentials.json")
            #expect(FileManager.default.contents(atPath: arrived.path) == login)
            #expect(try FileManager.default.attributesOfItem(atPath: arrived.path)[.posixPermissions] as? Int == 0o600)
            let there = try #require(await b.running(conversation))
            #expect(await b.engine.tmux.account(of: try #require(there.hosted)) == stored.id)
            #expect(b.transcript(of: there, account: stored)?.contains("Echo: on the work account") == true)
            #expect(!FileManager.default.fileExists(atPath: credentials.path))
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: a.machine.home.appendingPathComponent("root/runtime/moves/logins").path)) ?? []).isEmpty)
            // This computer's own login was never touched.
            #expect(FileManager.default.fileExists(atPath: b.machine.ownFolder.appendingPathComponent(".credentials.json").path))
        }
    }

    @Test func aPhoneIsRefusedOnTheRoutesBetweenComputers() async throws {
        let machine = try Machine("spare-box")
        try await withComputers([machine]) { computers in
            let daemon = computers[0].daemon
            let phone = FakePhone()
            let pin = daemon.identity.spkiHash
            let paired = try await phone.pair(with: daemon, pin: pin)
            let connection = try await TestConnection.open(port: daemon.port, pin: pin)
            let offer = MoveOffer(id: "mv-0123456789", conversationID: UUID().uuidString.lowercased(), agent: .claude, project: "app", commits: [],
                                  from: MacInfo(id: "host-of-alex", name: "Mac mini"))
            let link = ComputerLink(mac: MacInfo(id: "host-of-alex", name: "Mac mini"), endpoints: Endpoints(tailnet: "127.0.0.1:9"), serverKeyHash: pin,
                                    token: "test-token", deviceID: "device-of-alex", deviceSecret: "test-secret")
            let refused: [(String, String, Data)] = [
                ("POST", "/v1/moves", try JSONEncoder().encode(offer)),
                ("POST", "/v1/moves/mv-0123456789/parts/manifest.json/0", Data("{}".utf8)),
                ("POST", "/v1/moves/mv-0123456789/stage", try JSONEncoder().encode(MoveStage(parts: []))),
                ("POST", "/v1/moves/mv-0123456789/commit", Data("{}".utf8)),
                ("POST", "/v1/moves/mv-0123456789/abort", Data("{}".utf8)),
                ("GET", "/v1/moves/mv-0123456789", Data()),
                ("POST", "/v1/computers", try JSONEncoder().encode(link)),
                ("DELETE", "/v1/computers/host-of-alex", Data()),
            ]
            for (index, (method, path, body)) in refused.enumerated() {
                let answer = try await call(connection, method, path, token: paired.token, body: body, key: "phone-\(index)")
                #expect(answer.status == 403 && answer.errorCode == "not_computer", "\(method) \(path)")
            }
            #expect(await computers[0].moves.journal.all.isEmpty)
            #expect(await computers[0].moves.links.all.isEmpty)
            // What a phone may ask.
            #expect(try await call(connection, "GET", "/v1/computers", token: paired.token).json(ComputerList.self).computers.isEmpty)
            #expect(try await call(connection, "GET", "/v1/moves", token: paired.token).json(MoveList.self).moves.isEmpty)
            await connection.close()
        }
    }

    @Test func twoComputersLinkListEachOtherAndUnlinkOnBothSides() async throws {
        let source = try Machine("build-box"), target = try Machine("spare-box")
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            #expect(await !a.moves.movable())
            try await link(a, to: b)
            #expect(await a.moves.links.all.map(\.id) == [b.machine.hostID])
            #expect(await b.moves.links.all.map(\.id) == [a.machine.hostID])
            #expect(await a.moves.movable())
            #expect(await b.moves.movable())
            // Each knows the other as a device that paired as a computer.
            #expect(await a.daemon.devices.devices.filter(\.isComputer).map(\.computer) == [b.machine.hostID])
            #expect(await b.daemon.devices.devices.filter(\.isComputer).map(\.computer) == [a.machine.hostID])
            let listed = try #require(await a.service.control("computers", [:]))
            let names = try #require((try JSONSerialization.jsonObject(with: listed) as? [String: Any])?["computers"] as? [[String: Any]])
            #expect(names.map { $0["name"] as? String } == ["spare-box"])

            // Linking again replaces the link and the device it came in as.
            try await link(a, to: b)
            #expect(await a.moves.links.all.count == 1)
            #expect(await b.moves.links.all.count == 1)
            #expect(await a.daemon.devices.devices.filter(\.isComputer).count == 1)
            #expect(await b.daemon.devices.devices.filter(\.isComputer).count == 1)

            // `sidead unlink` forgets it here and tells the other computer, which forgets this one.
            let answer = try #require(await a.service.control("unlink", ["computer": "spare-box"]))
            #expect((try JSONSerialization.jsonObject(with: answer) as? [String: Any])?["ok"] as? Bool == true)
            #expect(await a.moves.links.all.isEmpty)
            #expect(await eventually(10) { await b.moves.links.all.isEmpty })
            #expect(await eventually(10) { await !b.daemon.devices.devices.contains(where: \.isComputer) })
            #expect(await !a.daemon.devices.devices.contains(where: \.isComputer))
            #expect(await !a.moves.movable())
            let unknown = try #require(await a.service.control("unlink", ["computer": "spare-box"]))
            #expect((try JSONSerialization.jsonObject(with: unknown) as? [String: Any])?["ok"] as? Bool == false)
        }
    }

    @Test func aStartAskedForAgainWhileTheSessionIsStartingIsAnsweredInProgressAndNothingIsDecided() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let conversation = try #require(try await a.host(folder, prompt: "slow to start").id)
            let gate = Gate()
            // Let go however the test ends, so the move it holds always finishes.
            defer { Task { await gate.open() } }
            await b.moves.set(launch: { [tmux = b.engine.tmux] start in
                await gate.wait()
                return try await tmux.start(start)
            })
            async let moved = a.moves.move(conversation, to: "spare-box")
            var id = ""
            #expect(await eventually(60) {
                id = await b.moves.journal.all.first { $0.session == conversation && $0.step == .starting }?.id ?? ""
                return !id.isEmpty
            })
            #expect(await b.moves.state(id).status == .starting)
            let computer = try #require(await a.moves.links.computer(b.machine.hostID))
            // Another start of it, as a sender that lost the first answer would send: neither yes nor no.
            let again = try await PeerHTTP.send(to: computer.addresses, pin: computer.pin, method: "POST", path: "/v1/moves/\(id)/commit",
                                                headers: [("Authorization", "Bearer \(computer.token)"), ("Content-Type", "application/json"),
                                                          ("X-SideA-Client", "SideARemote/\(SideADaemon.version) (\(RemotePolicy.minClientBuild); Linux)"),
                                                          ("Idempotency-Key", "\(id)-asked-again")],
                                                body: Data("{}".utf8), timeout: .seconds(30))
            #expect(again.status == 503)
            #expect(LinkedPeer.refusal(again).code == .inProgress && again.headers["retry-after"] == "2")
            // A drop while it starts is too late, and the sender's settling pass leaves a move it is carrying alone.
            let peer = LinkedPeer(computer)
            #expect(try await peer.abort(id).status == .starting)
            #expect(try await peer.state(id).status == .starting)
            await a.moves.settle()
            #expect(await a.moves.journal[id]?.step == .committing)

            await gate.open()
            let state = try await moved
            #expect(state.status == .live)
            #expect(await b.moves.journal[id]?.step == .live)
            #expect(await b.running(conversation) != nil)
            #expect(await a.running(conversation) == nil)
            #expect(b.machine.resumes(conversation) == 1)
        }
    }

    @Test func aMoveLeftStartingWhenTheDaemonStoppedIsCleanedUpWhenItStartsAgain() async throws {
        var source = try Machine("build-box")
        let target = try Machine("spare-box")
        try source.signIn("you@example.com"); try target.signIn("you@example.com")
        let folder = try await source.project()
        source.settings.projects = [folder.path]
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let row = try await a.host(folder, prompt: "stopped while starting")
            let conversation = try #require(row.id)
            await a.moves.set(peers: { StallingPeer(inner: LinkedPeer($0)) })
            await #expect(throws: MoveFailure.unknown(peer: "spare-box")) { try await a.moves.move(conversation, to: "spare-box") }
            let id = try #require(await b.moves.journal.all.first { $0.session == conversation }?.id)
            #expect(await b.moves.journal[id]?.step == .staged)
            let landed = b.machine.landing.appendingPathComponent("app")
            #expect(FileManager.default.fileExists(atPath: landed.path))

            // The daemon there stops after writing down that it is starting the session, and before it did.
            try await b.daemon.stop()
            let store = FileSecretStore(directory: b.machine.state)
            var journal = try JSONDecoder().decode(MoveJournal.self, from: try #require(try store.read("moves.json")))
            #expect(journal.commit(id, at: Date().timeIntervalSince1970) == .start)
            try store.write("moves.json", try JSONEncoder().encode(journal))
            let again = try await start(b.machine)
            // Started again, it finds the session isn't running: nothing of it is left, and the sender hears it didn't start.
            #expect(await eventually(30) { await again.moves.journal[id]?.step == .discarded })
            #expect(!FileManager.default.fileExists(atPath: landed.path))
            #expect(await again.running(conversation) == nil)
            await #expect(throws: MoveFailure.self) { try await again.moves.commit(id) }
            try await a.moves.links.update(b.machine.hostID) { $0.endpoints = Endpoints(tailnet: "127.0.0.1:\(again.daemon.port)") }
            await a.moves.set(peers: { LinkedPeer($0) })
            await a.moves.settle()
            #expect(await a.moves.journal[id]?.step == .returned)
            #expect(await eventually(30) { await a.running(conversation) != nil })
            #expect(b.machine.resumes(conversation) == 0)
            try await again.daemon.stop()
        }
    }

    @Test func idsFromAnotherComputerAreCheckedBeforeTheyNameAnything() async throws {
        let source = try Machine("build-box"), target = try Machine("spare-box")
        try target.signIn("you@example.com")
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let peer = LinkedPeer(try #require(await a.moves.links.computer(b.machine.hostID)))
            let me = a.daemon.me
            for (move, conversation) in [("mv-../../../etc", UUID().uuidString.lowercased()), ("MV-ABCDEF123", UUID().uuidString.lowercased()),
                                         ("mv-xyz123456", UUID().uuidString.lowercased()), ("mv-12", UUID().uuidString.lowercased()),
                                         ("mv-0123456789", "../../escape"), ("mv-0123456788", "")] {
                let offer = MoveOffer(id: move, conversationID: conversation, agent: .claude, project: "app", commits: [], from: me)
                await #expect(throws: MoveFailure.self, "\(move) \(conversation)") { try await peer.offer(offer) }
            }
            await #expect(throws: MoveFailure.self) { try await peer.part("mv-../../x", "manifest.json", 0, Data("{}".utf8)) }
            await #expect(throws: MoveFailure.self) { try await peer.stage("mv-nothex!!", MoveStage(parts: [])) }
            await #expect(throws: MoveFailure.self) { try await peer.commit("mv-q", MoveCommit()) }
            #expect(try await peer.abort("mv-not-hex-zz").status == MoveState.Status.none)
            // None of them left a record or a folder there.
            #expect(await b.moves.journal.all.isEmpty)
            let moves = b.machine.home.appendingPathComponent("root/runtime/moves")
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: moves.path)) ?? []).isEmpty)
        }
    }

    @Test func aLinkedComputerSpeaksOnlyForItself() async throws {
        let source = try Machine("build-box"), target = try Machine("spare-box")
        try target.signIn("you@example.com")
        try await withComputers([source, target]) { computers in
            let (a, b) = (computers[0], computers[1])
            try await link(a, to: b)
            let peer = LinkedPeer(try #require(await a.moves.links.computer(b.machine.hostID)))
            // An offer naming another sender than the computer this token is linked as.
            let someone = MacInfo(id: "host-of-alex", name: "Mac mini", os: .macos)
            let offer = MoveOffer(id: "mv-0123456789", conversationID: UUID().uuidString.lowercased(), agent: .claude, project: "app", commits: [], from: someone)
            await #expect(throws: MoveFailure.refused("That move names another computer as its sender.")) { try await peer.offer(offer) }
            #expect(await b.moves.journal.all.isEmpty)

            // Its device may link again as the computer it is, never as another one or as the computer it is calling.
            let kept = try #require(await b.moves.links.computer(a.machine.hostID))
            func claim(as mac: MacInfo, device: String) -> ComputerLink {
                ComputerLink(mac: mac, endpoints: kept.endpoints, serverKeyHash: kept.pin, token: kept.token, deviceID: device, deviceSecret: kept.deviceSecret)
            }
            await #expect(throws: MoveFailure.self) { try await peer.link(claim(as: someone, device: "device-claims-alex")) }
            await #expect(throws: MoveFailure.self) { try await peer.link(claim(as: b.daemon.me, device: "device-claims-itself")) }
            #expect(await b.moves.links.all.map(\.id) == [a.machine.hostID])
            #expect(await b.moves.links.computer(a.machine.hostID)?.token == kept.token)
            let relinked = try await peer.link(claim(as: a.daemon.me, device: kept.deviceID + "-again"))
            #expect(relinked.confirmKey != nil)
            #expect(await b.moves.links.all.map(\.id) == [a.machine.hostID])
            #expect(await b.daemon.devices.devices.filter(\.isComputer).map(\.computer) == [a.machine.hostID])
        }
    }
}

/// Holds an arriving session's start until the test lets it go.
private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        for waiter in waiting { waiter.resume() }
        waiting = []
    }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// A link on which the start is never sent: the sender is left not knowing, the receiver holding a staged copy.
struct StallingPeer: MovePeer {
    let inner: any MovePeer
    var id: String { inner.id }
    var name: String { inner.name }
    func offer(_ offer: MoveOffer) async throws -> MoveAnswer { try await inner.offer(offer) }
    func part(_ move: String, _ name: String, _ index: Int, _ data: Data) async throws { try await inner.part(move, name, index, data) }
    func stage(_ move: String, _ stage: MoveStage) async throws -> MoveState { try await inner.stage(move, stage) }
    func commit(_ move: String, _ commit: MoveCommit) async throws -> MoveState { throw PeerFailure.noAnswer }
    func abort(_ move: String) async throws -> MoveState { try await inner.abort(move) }
    func state(_ move: String) async throws -> MoveState { try await inner.state(move) }
}
