import CryptoKit
import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import SideARemoteKit
import Testing

private let conversation = "a06442e2-3f6b-4a35-931a-a4599bfa8acd"
private let movedConversation = conversation
/// The id a fork of it registers under, as the CLI does once it has read the conversation it forks.
let forkedConversation = "f0c1e2d3-5a6b-4c7d-8e9f-a0b1c2d3e4f5"

/// Notes how it was started and then sits at an empty prompt, as an idle agent does.
private let idleAgent = """
#!/usr/bin/env python3
import os, sys, time
out = "__OUT__"
open(out + ".args", "w").write(repr(sys.argv[1:]))
open(out + ".cwd", "w").write(os.getcwd())
open(out + ".pid", "w").write(str(os.getpid()))
open(out + ".pin", "w").write(os.environ.get("SIDE_A_PIN", ""))
sys.stdout.write("idle\\n")
sys.stdout.flush()
while True:
    time.sleep(1)
"""

/// One computer: its own Side A folder, home, tmux server and agent.
@MainActor
final class Computer {
    nonisolated static let conversationID = movedConversation
    let fixture: HostedFixture
    let name: String
    /// Who this computer says it is, when a real server of its own answers for it.
    var identity: MacInfo?
    /// What the session list says the agent is doing.
    var status: @MainActor () -> String = { "idle" }
    private(set) lazy var hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge, live: { [weak self] in self?.live() ?? [] })
    /// Replaced to stand for the app starting again on the same folder.
    lazy var moves = makeMoves()
    var projects: URL { fixture.base.appendingPathComponent("home/.claude/projects") }
    var landing: URL { fixture.base.appendingPathComponent("landing") }
    /// What the session list reads for the agent besides its mode.
    var model: String?, effort: String?

    init(_ name: String) throws {
        self.name = name
        fixture = try HostedFixture()
        let fake = fixture.base.appendingPathComponent("bin/claude")
        try idleAgent.replacingOccurrences(of: "__OUT__", with: fixture.submitted.path).write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    }

    /// A `Moves` over this computer's folder: a second one is the app launched again.
    func makeMoves() -> Moves {
        let name = name
        let places = Moves.Places(claudeProjects: projects, codexStores: [fixture.base.appendingPathComponent("home/.codex/sessions")], landing: landing)
        let fixture = fixture
        let moves = Moves(root: fixture.root, hosted: hosted, places: places, me: { [weak self] in self?.identity ?? MacInfo(id: name, name: name) }, bridge: { request in
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("bridge/sidea_bridge.py").path
            let result = await HostedSessions.process("/usr/bin/python3", [script, "--root", fixture.root.path, "move"], input: request,
                                                      environment: fixture.environment, timeout: 60)
            return Data(result.output.utf8)
        }, live: { [weak self] in self?.live() ?? [] })
        moves.patience = .seconds(60)
        return moves
    }

    private func note(_ suffix: String) -> String? {
        let text = try? String(contentsOf: fixture.submitted.appendingPathExtension(suffix), encoding: .utf8)
        return text
    }
    var arguments: String? { note("args") }
    var pin: String? { note("pin") }
    var cwd: String? { note("cwd") }
    var agentAlive: Bool { note("pid").flatMap(Int.init).map { ProcessCheck.alive($0) } ?? false }

    /// The agent this computer hosts, as the session list would show it.
    func live() -> [LiveSession] {
        guard let pid = note("pid").flatMap(Int.init), ProcessCheck.alive(pid), let name = hosted.sessions.first?.name else { return [] }
        let id = arguments?.contains("--fork-session") == true ? forkedConversation : conversation
        var row = LiveSession(pid: pid, sessionID: id, name: nil, title: "Fix the login redirect", cost: nil, cwd: cwd, status: status(), waitingFor: nil, since: nil)
        row.hosted = name; row.agent = "claude"; row.mode = "bypassPermissions"; row.model = model; row.effort = effort
        row.started = ProcessCheck.startTime(pid)?.rounded(.down)
        return [row]
    }

    /// A repository with a commit, uncommitted work, and a hosted session with a transcript.
    func startSession() async throws -> LiveSession {
        let project = fixture.project
        for command in ["git init -q -b main", "printf 'one\\n' > tracked.txt", "git add -A",
                        "git -c user.name=you -c user.email=you@example.com commit -qm base", "printf 'two\\n' > tracked.txt", "printf 'new\\n' > untracked.txt"] {
            let run = await HostedSessions.process("/bin/sh", ["-c", "cd \(Shell.quote(project.path)) && \(command) 2>&1"], environment: fixture.environment, timeout: 20)
            try #require(run.status == 0, "\(command): \(run.output)")
        }
        _ = try await hosted.start(.init(agent: .claude, cwd: project.path, mode: .new(model: nil)))
        try #require(await eventually { self.agentAlive && !self.live().isEmpty })
        let session = try #require(live().first)
        let slug = String(try #require(session.cwd).map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let folder = projects.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{\"type\":\"user\"}\n".write(to: folder.appendingPathComponent("\(conversation).jsonl"), atomically: true, encoding: .utf8)
        return session
    }

    func transcripts() -> [String] {
        (FileManager.default.enumerator(at: projects, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent == "\(conversation).jsonl" }.map(\.path)
    }

    func cleanUp() async { await fixture.cleanUp() }
}

/// The link to another computer in the same process, able to lose a request or its answer.
final class LocalPeer: MovePeer, @unchecked Sendable {
    enum Loss { case stageAnswer, commitRequest, commitAnswer }
    struct Lost: Error {}

    let id: String
    let name: String
    private let moves: @MainActor () -> Moves
    @MainActor var lose: Loss?
    /// Runs while a piece of the session is on its way, as a timer on the sending computer could.
    @MainActor var duringPart: (@MainActor () async -> Void)?

    @MainActor init(_ computer: Computer) {
        id = computer.name; name = computer.name
        moves = { computer.moves }
    }

    func offer(_ offer: MoveOffer) async throws -> MoveAnswer { try await moves().offered(offer, from: "laptop") }
    func part(_ move: String, _ name: String, _ index: Int, _ data: Data) async throws {
        if let hook = await duringPart { await hook() }
        try await moves().part(move, name, index, data)
    }
    func stage(_ move: String, _ stage: MoveStage) async throws -> MoveState {
        let state = try await moves().stage(move, stage)
        if await lose == .stageAnswer { throw Lost() }
        return state
    }
    func commit(_ move: String, _ commit: MoveCommit) async throws -> MoveState {
        if await lose == .commitRequest { throw Lost() }
        let state = try await moves().commit(move, commit)
        if await lose == .commitAnswer { throw Lost() }
        return state
    }
    func abort(_ move: String) async throws -> MoveState { await moves().abort(move, from: "laptop") }
    func state(_ move: String) async throws -> MoveState { await moves().state(move) }
}

/// A computer's accounts, with the logins as plain strings.
@MainActor
final class FakeLogins: MoveLogins {
    var running: (id: String, wire: MoveAccount)?
    var signedIn: [String: String] = [:]
    var any = true
    var staying: String?
    var events: [String] = []
    var stored: [String: String] = [:]
    var blob = "{\"secret\":1}"
    /// Runs as the login is taken out of use, which is after the other computer holds the rest.
    var onHold: (() -> Void)?
    /// Why an arriving login is not stored: it is not the account it says it is, or that can't be confirmed.
    var refuses: String?

    func account(of session: LiveSession) -> (id: String, wire: MoveAccount)? { running }
    func signedIn(_ agent: AgentProvider, email: String) -> String? { signedIn[email] }
    func hasAny(_ agent: AgentProvider) -> Bool { any }
    func staying(_ account: String, besides session: LiveSession) async -> String? { staying }
    func hold(_ account: String) async throws -> MoveLogin {
        events.append("hold")
        onHold?()
        return MoveLogin(email: running?.wire.email ?? "", name: running?.wire.name ?? "", login: blob)
    }
    func release(_ account: String, to peer: String) async { events.append("release to \(peer)") }
    func restore(_ account: String) async { events.append("restore") }
    func receive(_ login: MoveLogin, agent: AgentProvider) async throws -> (id: String, added: Bool) {
        events.append("receive \(login.email)")
        if let refuses { throw MoveFailure.refused(refuses) }
        stored["new"] = login.login
        return ("new", true)
    }
    func remove(_ account: String, added: Bool) async { events.append("remove"); stored[account] = nil }
    func seat(_ account: String) -> Moves.Seat { Moves.Seat(pin: account) }
}

@MainActor
func accounts(_ laptop: Computer, _ mini: Computer) -> (FakeLogins, FakeLogins) {
    let here = FakeLogins(), there = FakeLogins()
    here.running = ("work", MoveAccount(email: "you@example.com", name: "Work"))
    laptop.moves.logins = here
    mini.moves.logins = there
    return (here, there)
}

private let hasTmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }

@MainActor
func pair() async throws -> (Computer, Computer, LocalPeer) {
    let laptop = try Computer("MacBook"), mini = try Computer("Mac mini")
    await laptop.hosted.install()
    await mini.hosted.install()
    return (laptop, mini, LocalPeer(mini))
}

@MainActor @Test(.enabled(if: hasTmux))
func aSessionMovesToAnotherComputerWithItsUncommittedWorkAndRunsOnlyThere() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        try #require(laptop.hosted.available && mini.hosted.available)
        let session = try await laptop.startSession()
        let state = try await laptop.moves.send(session, to: peer)

        #expect(state.status == .live)
        #expect(await eventually { mini.agentAlive })
        #expect(!laptop.agentAlive)
        await laptop.hosted.refresh()
        #expect(laptop.hosted.sessions.isEmpty)
        #expect(mini.arguments == "['--resume', '\(conversation)', '--permission-mode', 'default']")
        let landed = try #require(mini.cwd)
        #expect(landed.hasSuffix("/landing/app"))
        #expect(try String(contentsOfFile: landed + "/tracked.txt", encoding: .utf8) == "two\n")
        #expect(try String(contentsOfFile: landed + "/untracked.txt", encoding: .utf8) == "new\n")
        #expect(mini.transcripts().count == 1)
        // The copy left on the laptop is out of the CLI's reach, so it cannot be resumed there by hand.
        #expect(laptop.transcripts().isEmpty)
        #expect(laptop.moves.ownership(of: conversation) == .away(peer: "Mac mini"))
        #expect(mini.moves.ownership(of: conversation) == .here)

        // A repeated start request starts nothing more, and a second move of the same session is refused.
        let again = try await mini.moves.commit(state.id)
        #expect(again.session == state.session)
        await mini.hosted.refresh()
        #expect(mini.hosted.sessions.count == 1)
        await #expect(throws: MoveFailure.self) { _ = try await laptop.moves.send(session, to: peer) }
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aSessionThatMovedAwayCanComeBackAndLandsBesideTheCheckoutItLeft() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let session = try await laptop.startSession()
        _ = try await laptop.moves.send(session, to: peer)
        #expect(await eventually { mini.agentAlive && !mini.live().isEmpty })
        let there = try #require(mini.live().first)
        try "three\n".write(toFile: try #require(there.cwd) + "/tracked.txt", atomically: true, encoding: .utf8)
        let transcript = try #require(mini.transcripts().first)
        try "{\"type\":\"user\"}\n{\"type\":\"assistant\"}\n".write(toFile: transcript, atomically: true, encoding: .utf8)

        let back = try await mini.moves.send(there, to: LocalPeer(laptop))
        #expect(back.status == .live)
        #expect(await eventually { laptop.agentAlive })
        #expect(!mini.agentAlive)
        let landed = try #require(laptop.cwd)
        #expect(landed.contains("/app/.sidea-worktrees/sa-app-"))
        #expect(try String(contentsOfFile: landed + "/tracked.txt", encoding: .utf8) == "three\n")
        // The checkout it left from is as it was.
        #expect(try String(contentsOf: laptop.fixture.project.appendingPathComponent("tracked.txt"), encoding: .utf8) == "two\n")
        #expect(laptop.transcripts().count == 1)
        #expect(try String(contentsOfFile: try #require(laptop.transcripts().first), encoding: .utf8).hasSuffix("{\"type\":\"assistant\"}\n"))
        #expect(laptop.moves.ownership(of: conversation) == .here)
        #expect(mini.moves.ownership(of: conversation) == .away(peer: "MacBook"))
        #expect(mini.transcripts().isEmpty)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aMoveThatFailsBeforeTheStartRequestLeavesTheSessionRunningHereAndNothingThere() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let session = try await laptop.startSession()
        let first = session.pid
        peer.lose = .stageAnswer
        await #expect(throws: MoveFailure.refused("Mac mini couldn't be reached, so the session stayed here.")) {
            _ = try await laptop.moves.send(session, to: peer)
        }
        #expect(await eventually { laptop.agentAlive && laptop.live().first?.pid != first })
        #expect(laptop.arguments?.hasPrefix("['--resume', '\(conversation)'") == true)
        #expect(laptop.moves.ownership(of: conversation) == .here)
        #expect(laptop.transcripts().count == 1)
        #expect(!mini.agentAlive)
        #expect(mini.transcripts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: mini.landing.appendingPathComponent("app").path))
        await mini.hosted.refresh()
        #expect(mini.hosted.sessions.isEmpty)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aLostAnswerToTheStartRequestIsShownAsUnknownAndSettledByAsking() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let session = try await laptop.startSession()
        peer.lose = .commitAnswer
        await #expect(throws: MoveFailure.unknown(peer: "Mac mini")) { _ = try await laptop.moves.send(session, to: peer) }
        #expect(laptop.moves.ownership(of: conversation) == .unknown(peer: "Mac mini"))
        #expect(!laptop.agentAlive)
        #expect(await eventually { mini.agentAlive })

        // Unreachable: still unknown, and still not started here.
        await laptop.moves.settle()
        #expect(laptop.moves.ownership(of: conversation) == .unknown(peer: "Mac mini"))
        #expect(!laptop.agentAlive)

        peer.lose = nil
        laptop.moves.peer = { _ in peer }
        await laptop.moves.settle()
        #expect(laptop.moves.ownership(of: conversation) == .away(peer: "Mac mini"))
        #expect(!laptop.agentAlive)
        #expect(laptop.transcripts().isEmpty)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aStartRequestThatNeverArrivedIsWithdrawnAndTheSessionComesBack() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let session = try await laptop.startSession()
        peer.lose = .commitRequest
        await #expect(throws: MoveFailure.unknown(peer: "Mac mini")) { _ = try await laptop.moves.send(session, to: peer) }
        #expect(!laptop.agentAlive && !mini.agentAlive)

        peer.lose = nil
        laptop.moves.peer = { _ in peer }
        await laptop.moves.settle()
        #expect(await eventually { laptop.agentAlive })
        #expect(laptop.moves.ownership(of: conversation) == .here)
        // The request arriving after all is refused: the copy was dropped.
        await #expect(throws: MoveFailure.self) { _ = try await mini.moves.commit(try #require(laptop.moves.journal.all.first?.id)) }
        #expect(!mini.agentAlive)
        #expect(mini.transcripts().isEmpty)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test func aSessionThatIsWorkingOrNotHostedIsNotMoved() {
    var row = LiveSession(pid: 1, sessionID: conversation, name: nil, title: nil, cost: nil, cwd: "/code/app", status: "busy", waitingFor: nil, since: nil)
    #expect(Moves.refusal(row) == "Only sessions Side A hosts can move. Use Continue on phone first.")
    row.hosted = "sa-app-1a2b"
    #expect(Moves.refusal(row) == "It's working. Move it when it has finished its turn.")
    #expect(Moves.arrival(.bypassPermissions, agent: .claude) == "default")
    #expect(Moves.arrival(.acceptEdits, agent: .claude) == "acceptEdits")
    #expect(Moves.arrival(PermissionMode(rawValue: "dangerFullAccess"), agent: .codex) == "default")
}

/// The routes a linked computer calls, against the app's own wiring.
@MainActor @Test func theMoveRoutesAnswerALinkedComputerAndRefuseWhatWasNeverOffered() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moves-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AccountStore(demo: true, root: folder)
    try store.remote.devices.add(computerDevice("laptop"), replacing: nil)
    try store.remote.devices.add(RemoteDevice(id: "phone", name: "iPhone", model: "iPhone", system: "", app: "", build: 1, hash: Data(count: 32), secretHash: "", created: 0), replacing: nil)
    func call(_ method: String, _ path: String, _ body: Data = Data(), as device: String = "laptop") async throws -> (Int, [String: Any]) {
        let request = HTTPRequest(method: method, target: "/" + path, path: path.split(separator: "/").map(String.init), query: [:], headers: HTTPHeaders([]), body: body)
        let response = await RemoteRoutes.route(request, RemoteServer.Caller(device: device, connection: 1), store.remote)
        return (response.status, response.body.isEmpty ? [:] : try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any]))
    }
    func code(_ answer: [String: Any]) -> String? { (answer["error"] as? [String: Any])?["code"] as? String }

    let offer = MoveOffer(id: "mv-000000000001", conversationID: conversation, agent: .claude, project: "app", commits: [], from: MacInfo(id: "laptop", name: "MacBook"))
    let offered = try await call("POST", "v1/moves", try JSONEncoder().encode(offer))
    // Hosting is off in a demo store, so nothing can land here.
    #expect(offered.0 == 409 && code(offered.1) == "move_refused")
    #expect(try await call("POST", "v1/moves", Data("{}".utf8)).0 == 400)

    let part = try await call("POST", "v1/moves/mv-000000000001/parts/workspace.bundle/0", Data([1, 2, 3]))
    #expect(part.0 == 409 && code(part.1) == "move_refused")
    #expect(try await call("GET", "v1/moves/mv-000000000001").1["status"] as? String == "none")
    #expect(try await call("POST", "v1/moves/mv-000000000001/commit").0 == 409)
    // Dropping a move this computer never saw is remembered, so it can never be started late.
    #expect(try await call("POST", "v1/moves/mv-000000000001/abort").1["status"] as? String == "none")
    #expect(try await call("GET", "v1/moves/mv-000000000001").1["status"] as? String == "discarded")
    #expect(store.remote.moves.ownership(of: conversation) == .here)

    // A phone's token opens none of it.
    for (method, path) in [("POST", "v1/moves"), ("POST", "v1/moves/mv-000000000002/parts/manifest.json/0"), ("POST", "v1/moves/mv-000000000002/commit"),
                           ("POST", "v1/moves/mv-000000000002/abort"), ("GET", "v1/moves/mv-000000000002"), ("POST", "v1/computers"), ("DELETE", "v1/computers/laptop")] {
        let body = path == "v1/moves" ? try JSONEncoder().encode(offer) : path == "v1/computers" ? try JSONEncoder().encode(link(from: "x").link) : Data()
        let refused = try await call(method, path, body, as: "phone")
        #expect(refused.0 == 403 && code(refused.1) == "not_computer", "\(method) \(path)")
    }
    #expect(store.remote.moves.journal["mv-000000000002"] == nil)
}

private func computerDevice(_ id: String, computer: String = "") -> RemoteDevice {
    RemoteDevice(id: id, name: "MacBook", model: "Mac", system: "", app: "", build: 1, hash: Data(count: 32), secretHash: "", created: 0, computer: computer)
}

@MainActor private func link(from id: String) -> (link: ComputerLink, device: RemoteDevice) {
    RemoteController.invitation(for: MacInfo(id: "mini", name: "Mac mini"), from: MacInfo(id: id, name: "MacBook"),
                                endpoints: Endpoints(tailnet: "100.64.0.7:47800", name: "macbook.example.ts.net:47800", lans: ["192.168.1.20:47800"]),
                                spki: Data(repeating: 7, count: 32), relay: RelayInfo(url: "https://relay.example.com", installID: "install", keyID: ""))
}

/// The second half of a link: the computer that paired sends the way back to itself, and each ends up able to call
/// the other and sign for it.
@MainActor @Test func aLinkGoesBothWaysAndEitherComputerCanEndIt() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moves-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AccountStore(demo: true, root: folder)
    let mini = store.remote
    // The laptop paired with the mini as a computer, and now sends its own invitation.
    try mini.devices.add(computerDevice("laptop-at-mini"), replacing: nil)
    let made = link(from: "laptop")
    func call(_ method: String, _ path: String, _ body: Data = Data(), as device: String = "laptop-at-mini") async -> HTTPResponse {
        let request = HTTPRequest(method: method, target: "/" + path, path: path.split(separator: "/").map(String.init), query: [:], headers: HTTPHeaders([]), body: body)
        return await RemoteRoutes.route(request, RemoteServer.Caller(device: device, connection: 1), mini)
    }
    let answer = await call("POST", "v1/computers", try JSONEncoder().encode(made.link))
    #expect(answer.status == 200, "\(String(decoding: answer.body, as: UTF8.self))")
    let keys = try JSONDecoder().decode(ComputerLinked.self, from: answer.body)

    let linked = try #require(mini.computers.all.first)
    #expect(linked.id == "laptop" && linked.name == "MacBook" && linked.token == made.link.token && linked.device == "laptop-at-mini")
    #expect(linked.endpoint.addresses.map(\.absoluteString) == ["https://100.64.0.7:47800", "https://macbook.example.ts.net:47800", "https://192.168.1.20:47800"])
    #expect(linked.endpoint.serverKeyHash == Data(repeating: 7, count: 32).base64URL)
    #expect(linked.endpoint.relay?.deviceID == made.link.deviceID && linked.secret?.count == 32)
    #expect(mini.devices.devices.first { $0.id == "laptop-at-mini" }?.computer == "laptop")
    // What the laptop keeps for the mini lets the mini's token in and nothing else.
    #expect(DeviceToken.match(made.link.token, in: [made.device.hash]) == 0 && made.device.computer == "mini")

    // The mini signs its calls to the laptop with the keys it just announced.
    let peer = try #require(mini.computers.peer("laptop", me: mini.mac))
    let header = try peer.signature(.action, subject: "x", faceID: true)
    let signature = try #require(ConfirmSignature(header: header))
    #expect(signature.signer == .confirm)
    let text = try ConfirmMessage.text(macID: "laptop", deviceID: made.link.deviceID, purpose: .action, subject: "x", at: signature.at)
    let announced = try #require(keys.confirmKey)
    let key = try P256.Signing.PublicKey(x963Representation: try #require(Secret.base64url(announced)))
    #expect(key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature.signature), for: Data(text.utf8)))

    let list = try JSONDecoder().decode(ComputerList.self, from: await call("GET", "v1/computers", as: "phone").body)
    #expect(list.computers == [RemoteComputer(id: "laptop", name: "MacBook")])

    // Another computer can't unlink this one; the laptop can, and then it is gone from both lists here.
    try mini.devices.add(computerDevice("other", computer: "other-host"), replacing: nil)
    // A linked computer speaks only for itself: it can't point this Mac's link to the laptop at its own address.
    #expect(await call("POST", "v1/computers", try JSONEncoder().encode(link(from: "laptop").link), as: "other").status == 403)
    #expect(mini.computers.all.first?.token == made.link.token)
    #expect(await call("DELETE", "v1/computers/laptop", as: "other").status == 204)
    #expect(mini.computers.all.count == 1)
    #expect(await call("DELETE", "v1/computers/laptop").status == 204)
    #expect(mini.computers.all.isEmpty)
    #expect(await eventually { !mini.devices.devices.contains { $0.id == "laptop-at-mini" } })
    #expect(mini.devices.devices.contains { $0.id == "other" })
    // Its own host id is not a computer it can link with.
    try mini.devices.add(computerDevice("self"), replacing: nil)
    #expect(await call("POST", "v1/computers", try JSONEncoder().encode(link(from: mini.mac.id).link), as: "self").status == 403)
}

/// The whole path a real move takes: this computer's client, pinned TLS, the other computer's server and routes.
@MainActor @Test(.enabled(if: hasTmux))
func aSessionMovesOverTheNetworkThroughTheOtherComputersServer() async throws {
    let (laptop, mini, _) = try await pair()
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moves-\(UUID().uuidString)")
    let keychain = try TestKeychain()
    let store = AccountStore(demo: true, root: folder)
    store.remote.moves = mini.moves
    try store.remote.devices.add(computerDevice("laptop"), replacing: nil)
    let identity = try #require(try keychain.store.identity())
    let server = RemoteServer(identity: identity, epoch: "e1", handler: RemoteRoutes.handler(store.remote))
    let token = DeviceToken.make()
    server.setDevices([(id: "laptop", hash: DeviceToken.hash(token))])
    let port = freePort()
    server.serve(addresses: ["127.0.0.1"], port: port)
    for _ in 0..<250 where server.listenerStates.values.first != .ready { try await Task.sleep(for: .milliseconds(20)) }
    do {
        let pin = identity.spkiHash.base64URL
        let endpoint = Endpoint(macID: "mini", baseURL: try #require(URL(string: "https://127.0.0.1:\(port)")), serverKeyHash: pin, name: "Mac mini")
        let computer = LinkedComputer(id: "mini", name: "Mac mini", endpoint: endpoint, token: token, linked: 0)
        let info = LinkedComputers.client(MacInfo(id: "laptop", name: "MacBook"))
        let peer = RemotePeer(computer, info: info, transport: URLSessionTransport(trust: PinnedTrust(.pinned(pin))))

        let session = try await laptop.startSession()
        // Bigger than one piece, so the workspace crosses in several requests.
        try Data((0..<(Moves.chunk * 2 + 4321)).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: laptop.fixture.project.appendingPathComponent("large.bin"))
        let state = try await laptop.moves.send(session, to: peer)
        #expect(state.status == .live)
        #expect(await eventually { mini.agentAlive })
        #expect(!laptop.agentAlive)
        let landed = try #require(mini.cwd)
        #expect(try Data(contentsOf: URL(fileURLWithPath: landed + "/large.bin")) == Data(contentsOf: laptop.fixture.project.appendingPathComponent("large.bin")))
        #expect(try await peer.state(state.id).status == .live)
        #expect(try await peer.commit(state.id, MoveCommit()).session == state.session)
        await mini.hosted.refresh()
        #expect(mini.hosted.sessions.count == 1)

        // A token the other computer does not know is a plain no, never an open question.
        let stranger = RemotePeer(LinkedComputer(id: "mini", name: "Mac mini", endpoint: endpoint, token: DeviceToken.make(), linked: 0), info: info,
                                  transport: URLSessionTransport(trust: PinnedTrust(.pinned(pin))))
        await #expect(throws: MoveFailure.self) { _ = try await stranger.commit("mv-000000000009", MoveCommit()) }
    } catch { Issue.record(error) }
    server.stop()
    try? FileManager.default.removeItem(at: folder)
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func theLoginGoesWithTheSessionWhenTheOtherComputerIsNotSignedInToIt() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let (here, there) = accounts(laptop, mini)
        let session = try await laptop.startSession()
        let state = try await laptop.moves.send(session, to: peer)
        #expect(state.account == "you@example.com")
        #expect(here.events == ["hold", "release to Mac mini"])
        #expect(there.events == ["receive you@example.com"])
        #expect(there.stored["new"] == "{\"secret\":1}")
        #expect(await eventually { mini.agentAlive })
        // A repeated start request says the same about the login and stores nothing twice.
        #expect(try await mini.moves.commit(state.id).account == "you@example.com")
        #expect(there.events.count == 1)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func noLoginIsSentToAComputerAlreadySignedInToTheAccountOrWhenItMustStay() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let (here, there) = accounts(laptop, mini)
        there.signedIn["you@example.com"] = "theirs"
        let session = try await laptop.startSession()
        let plan = try await laptop.moves.prepare(session, to: peer)
        #expect(plan.answer.account == .here && !plan.hands)
        await laptop.moves.withdraw(plan, from: peer)

        // Not signed in to it there, and another session here still uses it: it runs on the other computer's own.
        there.signedIn = [:]
        here.staying = "another session here is using Work"
        let other = try await laptop.moves.prepare(session, to: peer)
        #expect(other.answer.account == .wanted && !other.hands)
        await laptop.moves.withdraw(other, from: peer)

        // Nothing there can run it and the login can't leave: refused while the session is still running.
        there.any = false
        await #expect(throws: MoveFailure.refused("Mac mini isn't signed in to Claude, and another session here is using Work.")) {
            _ = try await laptop.moves.prepare(session, to: peer)
        }
        #expect(laptop.agentAlive)
        #expect(here.events.isEmpty && there.events.isEmpty)
        #expect(mini.moves.ownership(of: conversation) == .here)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aLoginSentWithAMoveWhoseOutcomeIsUnknownStaysOutOfUseUntilTheComputersAgree() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let (here, there) = accounts(laptop, mini)
        let session = try await laptop.startSession()
        peer.lose = .commitAnswer
        await #expect(throws: MoveFailure.unknown(peer: "Mac mini")) { _ = try await laptop.moves.send(session, to: peer) }
        #expect(here.events == ["hold"])
        #expect(there.events == ["receive you@example.com"])

        peer.lose = nil
        laptop.moves.peer = { _ in peer }
        await laptop.moves.settle()
        #expect(here.events == ["hold", "release to Mac mini"])
        #expect(laptop.moves.ownership(of: conversation) == .away(peer: "Mac mini"))
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aLoginComesBackWhenTheOtherComputerNeverStartedTheSession() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let (here, there) = accounts(laptop, mini)
        let session = try await laptop.startSession()
        peer.lose = .commitRequest
        await #expect(throws: MoveFailure.unknown(peer: "Mac mini")) { _ = try await laptop.moves.send(session, to: peer) }
        #expect(here.events == ["hold"])
        peer.lose = nil
        laptop.moves.peer = { _ in peer }
        await laptop.moves.settle()
        #expect(here.events == ["hold", "restore"])
        #expect(there.events.isEmpty)
        #expect(await eventually { laptop.agentAlive })
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aPreviewAsksBothComputersAndLeavesNothingBehind() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let (here, there) = accounts(laptop, mini)
        let session = try await laptop.startSession()
        let preview = try await laptop.moves.preview(session, to: peer)
        #expect(preview.computer == RemoteComputer(id: "Mac mini", name: "Mac mini"))
        #expect(preview.landing?.hasSuffix("/landing/app") == true)
        // The session runs with bypassPermissions here, which the other computer does not take on trust.
        #expect(preview.permissionMode == .default)
        #expect(preview.account == "Work" && preview.login == .sent)
        #expect(MoveSheet.account(preview, computer: "Mac mini") == "Signs Mac mini in to Work and stops using it here")
        #expect(laptop.agentAlive && here.events.isEmpty && there.events.isEmpty)
        #expect(mini.moves.ownership(of: conversation) == .here && laptop.moves.ownership(of: conversation) == .here)
        #expect(laptop.moves.records().isEmpty)
        // Nothing of the preview is in the way of the move itself.
        #expect(try await laptop.moves.send(session, to: peer).status == .live)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aMoveStartedForThePhoneIsListedWhileItRunsAndAfter() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let session = try await laptop.startSession()
        var done = false
        laptop.moves.finished = { done = true }
        let record = try await laptop.moves.start(session, to: peer)
        #expect(record.state == .moving && record.computerName == "Mac mini" && record.conversationID == conversation)
        #expect(record.title == "Fix the login redirect" && record.project == "app")
        #expect(await eventually { done })
        let away = try #require(laptop.moves.record(record.id))
        #expect(away.state == .away)
        #expect(away.session == mini.hosted.sessions.first?.name && away.session != nil)
        #expect(await eventually { mini.agentAlive })

        // Back again, the list is empty; a move that then fails is listed with its reason and the session runs here.
        let there = try #require(mini.live().first)
        _ = try await mini.moves.send(there, to: LocalPeer(laptop))
        #expect(await eventually { laptop.agentAlive && !laptop.live().isEmpty })
        #expect(laptop.moves.records().isEmpty)
        peer.lose = .stageAnswer
        done = false
        let second = try await laptop.moves.start(try #require(laptop.live().first), to: peer)
        #expect(await eventually { done })
        let failed = try #require(laptop.moves.record(second.id))
        #expect(failed.state == .failed && failed.message == "Mac mini couldn't be reached, so the session stayed here.")
        #expect(await eventually { laptop.agentAlive })
        laptop.moves.now = { Date().timeIntervalSince1970 + Moves.failuresShownFor + 1 }
        #expect(laptop.moves.records().isEmpty)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test func thePhonesMoveRoutesNameWhatIsMissing() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moves-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AccountStore(demo: true, root: folder)
    func call(_ method: String, _ path: String, _ body: Data = Data()) async -> HTTPResponse {
        let request = HTTPRequest(method: method, target: "/" + path, path: path.split(separator: "/").map(String.init), query: [:], headers: HTTPHeaders([]), body: body)
        return await RemoteRoutes.route(request, RemoteServer.Caller(device: "phone", connection: 1), store.remote)
    }
    #expect(try JSONDecoder().decode(MoveList.self, from: await call("GET", "v1/moves").body).moves.isEmpty)
    #expect(await call("POST", "v1/moves/mv-000000000001/check").status == 404)
    let body = try JSONEncoder().encode(MoveRequest(computer: "mini"))
    #expect(await call("POST", "v1/sessions/nope/move/preview", body).status == 404)
    #expect(await call("POST", "v1/sessions/nope/move/preview", Data("[]".utf8)).status == 400)
    // Without a signature nothing is looked up, let alone moved.
    #expect([401, 503].contains(await call("POST", "v1/sessions/nope/move", body).status))
}

extension LocalPeer: StandbyPeer {
    func standby(_ offer: StandbyOffer) async throws -> MoveAnswer { try await moves().standbyOffered(offer, from: "laptop") }
    func standbyPart(_ id: String, _ name: String, _ index: Int, _ data: Data) async throws { try await moves().standbyPart(id, name, index, data, from: "laptop") }
    func keep(_ id: String, _ stage: MoveStage) async throws { try await moves().keep(id, stage, from: "laptop") }
    func forget(_ conversation: String) async throws { await moves().forget(conversation, from: "laptop") }
}

@MainActor @Test(.enabled(if: hasTmux))
func aStandbyKeepsTheNewestCheckpointAndContinuesItAsACopyWithoutTouchingTheOriginal() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let session = try await laptop.startSession()
        var clock = Date().timeIntervalSince1970
        laptop.moves.now = { clock }
        #expect(try await laptop.moves.checkpoint(session, to: peer))
        #expect(laptop.agentAlive && !mini.agentAlive)
        #expect(laptop.moves.ownership(of: conversation) == .here)
        let first = try #require(mini.moves.copies().first)
        #expect(first.conversationID == conversation && first.computerName == "MacBook" && first.title == "Fix the login redirect")
        // Nothing of it is where a CLI or a checkout would find it.
        #expect(mini.transcripts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: mini.landing.path))

        // Within the minute, and after it with nothing changed, nothing is sent.
        #expect(try await laptop.moves.checkpoint(session, to: peer) == false)
        clock += 61
        #expect(try await laptop.moves.checkpoint(session, to: peer) == false)
        // A change is a new checkpoint, and the old one is gone.
        try "three\n".write(to: laptop.fixture.project.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        clock += 61
        #expect(try await laptop.moves.checkpoint(session, to: peer))
        #expect(mini.moves.copies().count == 1 && mini.moves.kept.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: mini.moves.standbyFolder.path).filter { $0.hasPrefix("sb-") }.count == 1)
        // The laptop's own repository shows nothing of it.
        let refs = await HostedSessions.process("/bin/sh", ["-c", "cd \(Shell.quote(laptop.fixture.project.path)) && git for-each-ref refs/sidea && git stash list"], environment: laptop.fixture.environment, timeout: 20)
        #expect(refs.output.isEmpty)

        // A copy of the original the mini had before, under another folder, is not the copy's to touch.
        let before = mini.projects.appendingPathComponent("-elsewhere/\(conversation).jsonl")
        try FileManager.default.createDirectory(at: before.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "here before\n".write(to: before, atomically: true, encoding: .utf8)

        // The laptop is gone as far as the mini can tell: the copy starts there as a fork, with the newer work.
        let copy = try await mini.moves.continueCopy(of: conversation)
        #expect(copy.status == .live)
        #expect(await eventually { mini.agentAlive })
        #expect(mini.arguments == "['--resume', '\(conversation)', '--fork-session', '--permission-mode', 'default']")
        // Once the fork has read it, the original it forked can't be resumed on the mini by its id: it may still run on the laptop.
        #expect(mini.transcripts().map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent } == ["-elsewhere"])
        #expect(try String(contentsOf: before, encoding: .utf8) == "here before\n")
        #expect(try String(contentsOfFile: try #require(mini.cwd) + "/tracked.txt", encoding: .utf8) == "three\n")
        #expect(try String(contentsOfFile: try #require(mini.cwd) + "/untracked.txt", encoding: .utf8) == "new\n")
        #expect(laptop.agentAlive)
        await #expect(throws: MoveFailure.self) { _ = try await mini.moves.continueCopy(of: "no-such-conversation") }

        // Another computer's device can neither replace nor delete it; the one that sent it can.
        await mini.moves.forget(conversation, from: "someone-else")
        #expect(mini.moves.copies().count == 1)
        try await peer.forget("all")
        #expect(mini.moves.copies().isEmpty)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: mini.moves.standbyFolder.path).contains { $0.hasPrefix("sb-") })
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aDamagedCheckpointIsNotKeptAndStandbyGoesOnlyToTheChosenComputer() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let session = try await laptop.startSession()
        let offer = StandbyOffer(id: "sb-000000000001", conversationID: conversation, agent: .claude, project: "app", commits: [], from: MacInfo(id: "MacBook", name: "MacBook"), at: 1)
        _ = try await mini.moves.standbyOffered(offer, from: "laptop")
        try mini.moves.standbyPart(offer.id, "manifest.json", 0, Data("{}".utf8), from: "laptop")
        #expect(throws: MoveFailure.self) { try mini.moves.standbyPart(offer.id, "manifest.json", 0, Data(), from: "other") }
        #expect(throws: MoveFailure.self) { try mini.moves.standbyPart(offer.id, "../escape", 0, Data(), from: "laptop") }
        #expect(throws: MoveFailure.self) { try mini.moves.keep(offer.id, MoveStage(parts: [MovePart(name: "manifest.json", sha256: "00", size: 2)]), from: "laptop") }
        #expect(mini.moves.copies().isEmpty && mini.moves.kept.isEmpty)
        #expect(throws: MoveFailure.self) { try mini.moves.standbyPart(offer.id, "manifest.json", 1, Data(), from: "laptop") }

        // With no computer chosen nothing is sent; with one chosen, every hosted idle session is.
        laptop.moves.peer = { _ in peer }
        await laptop.moves.checkpointAll()
        #expect(mini.moves.copies().isEmpty)
        laptop.moves.standbyPeer = { "Mac mini" }
        await laptop.moves.checkpointAll()
        #expect(mini.moves.copies().map(\.conversationID) == [conversation])
        // Turned off, what was sent is deleted there.
        laptop.moves.standbyPeer = { nil }
        await laptop.moves.checkpointAll()
        #expect(mini.moves.copies().isEmpty)
        _ = session
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func aPassThatFinishesOldMovesLeavesOneThatIsRunningAlone() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let (here, there) = accounts(laptop, mini)
        let session = try await laptop.startSession()
        laptop.moves.peer = { _ in peer }
        var passes = 0
        // The once-a-minute pass and Check Again both land in the middle of a move sooner or later.
        peer.duringPart = { passes += 1; await laptop.moves.settle() }
        let state = try await laptop.moves.send(session, to: peer)
        #expect(passes > 0 && state.status == .live)
        #expect(await eventually { mini.agentAlive })
        #expect(!laptop.agentAlive)
        await laptop.hosted.refresh()
        #expect(laptop.hosted.sessions.isEmpty)
        #expect(here.events == ["hold", "release to Mac mini"] && there.events == ["receive you@example.com"])
        #expect(laptop.moves.ownership(of: conversation) == .away(peer: "Mac mini"))
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func oneSessionCannotBeMovedTwiceAtOnceAndAnIdFromAnotherComputerNeverNamesAFolder() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let session = try await laptop.startSession()
        let first = try await laptop.moves.prepare(session, to: peer)
        await #expect(throws: MoveFailure.refused("That session is already moving.")) { _ = try await laptop.moves.prepare(session, to: peer) }
        await laptop.moves.withdraw(first, from: peer)
        // Withdrawn, it can be agreed again.
        await laptop.moves.withdraw(try await laptop.moves.prepare(session, to: peer), from: peer)

        let keep = mini.moves.folder.appendingPathComponent("away/keep.txt")
        try FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "kept".write(to: keep, atomically: true, encoding: .utf8)
        for id in ["../../../escape", "away", "logins", "standby", "mv-../x", "mv-", "MV-000000000001", "mv-00000000000g"] {
            let offer = MoveOffer(id: id, conversationID: conversation, agent: .claude, project: "app", commits: [], from: MacInfo(id: "MacBook", name: "MacBook"))
            await #expect(throws: MoveFailure.self, "\(id)") { _ = try await mini.moves.offered(offer, from: "laptop") }
            _ = await mini.moves.abort(id, from: "laptop")
        }
        let odd = MoveOffer(id: "mv-000000000003", conversationID: "../../x", agent: .claude, project: "app", commits: [], from: MacInfo(id: "MacBook", name: "MacBook"))
        await #expect(throws: MoveFailure.self) { _ = try await mini.moves.offered(odd, from: "laptop") }
        await mini.moves.expire()
        // Only the two withdrawn moves are remembered; none of the odd ids left a record or a folder.
        #expect(mini.moves.journal.all.count == 2 && mini.moves.journal.all.allSatisfy { Moves.wellFormed(move: $0.id) && $0.step == .discarded })
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(!FileManager.default.fileExists(atPath: mini.fixture.root.appendingPathComponent("escape").path))
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

@MainActor @Test(.enabled(if: hasTmux))
func anUnknownMoveWhoseComputerIsGoneCanBeRunHereAndItsLoginComesBack() async throws {
    let (laptop, mini, peer) = try await pair()
    do {
        let (here, _) = accounts(laptop, mini)
        let session = try await laptop.startSession()
        peer.lose = .commitRequest
        await #expect(throws: MoveFailure.unknown(peer: "Mac mini")) { _ = try await laptop.moves.send(session, to: peer) }
        let id = try #require(laptop.moves.records().first?.id)
        // The other computer was unlinked: nobody to ask.
        laptop.moves.peer = { _ in nil }
        await laptop.moves.settle()
        #expect(laptop.moves.record(id)?.state == .unknown && !laptop.agentAlive)
        await laptop.moves.runHere(id)
        #expect(await eventually { laptop.agentAlive })
        #expect(here.events == ["hold", "restore"])
        #expect(laptop.moves.records().isEmpty && laptop.moves.ownership(of: conversation) == .here)
    } catch { Issue.record(error) }
    await laptop.cleanUp()
    await mini.cleanUp()
}

/// A live run against a real `sidead` on another machine, never part of the suite: this process is a whole Side A
/// host (real server, routes, linking and move code; a throwaway keychain, folder, tmux server and stand-in agent).
/// SIDEA_MOVES_LIVE_LINK=<the link `sidead pair` printed> SIDEA_MOVES_LIVE_ADDRESS=<this Mac's address the other
/// machine can reach> swift test --filter aSessionMovesToARealDaemonOnAnotherMachineAndComesBack. Lines start LIVE.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDEA_MOVES_LIVE_LINK"] != nil && hasTmux))
func aSessionMovesToARealDaemonOnAnotherMachineAndComesBack() async throws {
    let env = ProcessInfo.processInfo.environment
    func say(_ line: String) { FileHandle.standardError.write(Data(("LIVE " + line + "\n").utf8)) }
    let link = try #require(env["SIDEA_MOVES_LIVE_LINK"])
    let address = try #require(env["SIDEA_MOVES_LIVE_ADDRESS"])
    UserDefaults.standard.setVolatileDomain([RemoteController.enabledKey: true, RemoteController.portKey: Int(freePort())], forName: UserDefaults.argumentDomain)
    let laptop = try Computer("MacBook")
    await laptop.hosted.install()
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moves-live-\(UUID().uuidString)")
    let keychain = try TestKeychain()
    let store = AccountStore(demo: true, root: folder)
    let remote = RemoteController(store: store, keychain: keychain.store, addresses: [address])
    store.remote = remote
    laptop.identity = remote.mac
    remote.moves = laptop.moves
    remote.start()
    do {
        try #require(await eventually(2) { remote.listening.values.contains(.ready) })
        say("listening \(remote.listening) as \(remote.mac.id)")
        let pending = try await remote.computers.begin(link: link, me: remote.mac)
        say("code \(pending.code) for \(pending.name): confirm it there")
        let computer = try await remote.computers.finish(pending, controller: remote)
        say("linked \(computer.name) (\(computer.id)) at \(computer.endpoint.baseURL)")
        let peer = try #require(remote.computers.peer(computer.id, me: remote.mac))
        laptop.moves.peer = { _ in peer }
        // A login of the right shape and no value: the daemon has no account, so this one must travel and come back.
        let logins = FakeLogins()
        logins.running = ("work", MoveAccount(email: "you@example.com", name: "Work"))
        logins.blob = "{\"claudeAiOauth\":{\"accessToken\":\"not-a-token\",\"refreshToken\":\"not-a-token\",\"expiresAt\":4102444800000,\"subscriptionType\":\"max\"}}"
        laptop.moves.logins = logins

        let session = try await laptop.startSession()
        let big = Data((0..<(Moves.chunk * 3 + 999)).map { UInt8(truncatingIfNeeded: $0 &* 131) })
        try big.write(to: laptop.fixture.project.appendingPathComponent("large.bin"))
        let started = Date()
        let state = try await laptop.moves.send(session, to: peer)
        say("moved in \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(state.status.rawValue) session=\(state.session ?? "-") folder=\(state.folder ?? "-")")
        #expect(state.status == .live)
        #expect(!laptop.agentAlive)
        #expect(try await peer.state(state.id).status == .live)
        #expect(laptop.moves.ownership(of: conversation) == .away(peer: computer.id))
        say("login: \(logins.events) account there: \(state.account ?? "-")")
        say("large.bin sha256 \(SHA256.hash(data: big).map { String(format: "%02x", $0) }.joined())")

        // Time for whoever runs this to look at the other machine.
        let hold = TimeInterval(env["SIDEA_MOVES_LIVE_HOLD"].flatMap(Int.init) ?? 0)
        say("holding \(Int(hold)) s")
        _ = await eventually(hold / 6) { false }

        let back = try await peer.bring(conversation, to: remote.mac.id)
        say("asked for it back: \(back.state.rawValue)")
        #expect(await eventually(20) { laptop.agentAlive })
        say("back here: agent alive \(laptop.agentAlive) in \(laptop.cwd ?? "-")")
        let home = try #require(laptop.cwd)
        #expect(try Data(contentsOf: URL(fileURLWithPath: home + "/large.bin")) == big)
        #expect(try String(contentsOfFile: home + "/tracked.txt", encoding: .utf8) == "two\n")
        #expect(await eventually(5) { laptop.moves.ownership(of: conversation) == .here })
        say("login after coming back: \(logins.events)")
        say("there now: \(try await peer.state(state.id).status.rawValue)")
        remote.computers.remove(computer.id, controller: remote)
        say("unlinked")
    } catch {
        say("failed: \(error)")
        Issue.record(error)
    }
    remote.setEnabled(false)
    try? FileManager.default.removeItem(at: folder)
    await laptop.cleanUp()
}
