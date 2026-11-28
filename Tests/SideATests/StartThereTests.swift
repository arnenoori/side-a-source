import CryptoKit
import CSideAPTY
import Darwin
import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import SideARemoteKit
import Testing

private let hasTmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }

/// The other computer: its own Side A folder, tmux server and fake agent, behind the Remote server, routes and terminal
/// stream a phone uses, which this Mac reaches as a linked computer over pinned TLS.
@MainActor
final class OtherMac {
    let fixture: HostedFixture
    let hosted: HostedSessions
    let store: AccountStore
    let server: RemoteServer
    let pin: String
    let port: UInt16
    let token = DeviceToken.make()
    /// The keys this Mac announced when the link was made, as the other computer keeps them.
    let confirm = P256.Signing.PrivateKey(), unlock = P256.Signing.PrivateKey()
    private let keychain: TestKeychain

    init() async throws {
        fixture = try HostedFixture()
        let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge)
        self.hosted = hosted
        await hosted.install()
        store = AccountStore(demo: true, root: fixture.base.appendingPathComponent("mini"))
        store.hosted = hosted
        // A recent session there names the project, which makes it one a start may use.
        let home = fixture.base.appendingPathComponent("transcripts")
        try TranscriptFixture.write(TranscriptFixture.lines(session: "p1", cwd: fixture.project.path, day: TranscriptFixture.today), session: "p1", home: home)
        let index = home.appendingPathComponent("Side A")
        TranscriptFixture.index(home: home, root: index)
        store.sessions.transcriptSource = (home: home, bridge: TranscriptFixture.bridge, python: "/usr/bin/python3", root: index)
        keychain = try TestKeychain()
        let identity = try #require(try keychain.store.identity())
        pin = identity.spkiHash.base64URL
        let server = RemoteServer(identity: identity, epoch: "e1", handler: RemoteRoutes.handler(store.remote))
        self.server = server
        let terminals = TerminalHub(queue: server.queue, epoch: "e1") { hosted }
        hosted.onEnded = { name, status, reason in terminals.ended(name, status: status, reason: reason) }
        hosted.onRefresh = { terminals.queue.async { terminals.evaluateAll() } }
        server.opened = { peer in
            if peer.path.count == 4 { terminals.attach(peer, name: peer.path[3]) } else { peer.close(4404, "") }
        }
        server.macID = "mini"
        server.setDevices([(id: "laptop", hash: DeviceToken.hash(token))],
                          keys: ["laptop": .init(confirm: confirm.publicKey.x963Representation.base64URL, unlock: unlock.publicKey.x963Representation.base64URL)])
        // The routes ask this server, which checks each signature against those keys and refuses a replay.
        store.remote.server = server
        store.remote.hub = EventHub(queue: server.queue, epoch: "e1", snapshot: { { seq, epoch in StateSnapshot(seq: seq, epoch: epoch) } }, hello: {
            Hello(app: "", build: 0, mac: MacInfo(id: "mini", name: "Mac mini"), capabilities: [], epoch: "e1", serverTime: 0, endpoints: Endpoints(tailnet: ""), keyID: "")
        })
        port = freePort()
        server.serve(addresses: ["127.0.0.1"], port: port)
    }

    /// This Mac's link to it. `keys: false` is a link whose keys the other computer never took.
    func peer(keys: Bool = true) throws -> RemotePeer {
        let endpoint = Endpoint(macID: "mini", baseURL: try #require(URL(string: "https://127.0.0.1:\(port)")), serverKeyHash: pin, name: "Mac mini")
        let strangers = (P256.Signing.PrivateKey(), P256.Signing.PrivateKey())
        let computer = LinkedComputer(id: "mini", name: "Mac mini", endpoint: endpoint, token: token, linked: 0,
                                      confirm: keys ? confirm.rawRepresentation : strangers.0.rawRepresentation,
                                      unlock: keys ? unlock.rawRepresentation : strangers.1.rawRepresentation, device: "mini-here", me: "laptop")
        return RemotePeer(computer, info: LinkedComputers.client(MacInfo(id: "laptop", name: "MacBook")),
                          transport: URLSessionTransport(trust: PinnedTrust(.pinned(pin))))
    }

    func ready() async -> Bool { await eventually { self.server.listenerStates.values.first == .ready } }

    func window(_ name: String) async -> String {
        await hosted.command(["display-message", "-p", "-t", "=\(name):", "#{window_width}x#{window_height}"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func showing(_ name: String, _ text: String) async -> Bool {
        await hosted.command(["capture-pane", "-p", "-t", "=\(name):"]).output.contains(text)
    }

    var arguments: String? { try? String(contentsOf: fixture.submitted.appendingPathExtension("args"), encoding: .utf8) }

    func cleanUp() async {
        server.stop()
        await fixture.cleanUp()
    }
}

/// A terminal tab: the wrapper in a PTY of its own, as Ghostty or Terminal runs it. Like a terminal, it reads the PTY
/// all the time: one left unread fills, and `nc` then waits on its output and stops reading keys.
final class TerminalTab: @unchecked Sendable {
    let pid: pid_t
    private var master: Int32 = -1
    private let queue = DispatchQueue(label: "tab")
    private let reader: DispatchSourceRead
    private var shown = Data()
    private var reaped = false

    init(_ path: String, _ arguments: [String], cols: UInt16, rows: UInt16) throws {
        let environment: [String] = ["PATH=/usr/bin:/bin", "TERM=xterm-256color", "LANG=en_US.UTF-8"]
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var master: Int32 = -1
        pid = sidea_pty_spawn(path, argv, envp, cols, rows, &master)
        let fd = master
        reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        try #require(pid > 0)
        self.master = master
        reader.setEventHandler { [weak self] in self?.drain(fd) }
        reader.setCancelHandler { Darwin.close(fd) }
        reader.resume()
    }

    private func drain(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &chunk, chunk.count)
        if count > 0 { shown.append(contentsOf: chunk[..<count]) } else if count == 0 || errno != EAGAIN { reader.cancel() }
    }

    /// Everything the tab has drawn so far.
    func screen() -> String { queue.sync { String(decoding: shown, as: UTF8.self) } }

    func type(_ text: String) {
        let bytes = Array(text.utf8)
        #expect(Darwin.write(master, bytes, bytes.count) == bytes.count)
    }

    /// The terminal window resized: the kernel tells what runs in the tab with SIGWINCH.
    func resize(_ cols: UInt16, _ rows: UInt16) { #expect(sidea_pty_resize(master, cols, rows) == 0) }

    var echoes: Bool {
        var settings = termios()
        return tcgetattr(master, &settings) == 0 && settings.c_lflag & tcflag_t(ECHO) != 0
    }

    /// Closing the tab: the terminal lets go of the PTY and the kernel hangs up on what runs in it.
    func close() {
        queue.sync { reader.cancel() }
        master = -1
    }

    func exited() -> Bool {
        guard !reaped else { return true }
        var status: Int32 = 0
        reaped = waitpid(pid, &status, WNOHANG) == pid
        return reaped
    }

    func stop() {
        if master >= 0 { close() }
        if !exited() { kill(pid, SIGKILL); _ = waitpid(pid, nil, 0) }
    }
}

private func mode(_ path: String) -> Int? {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber).map { $0.intValue & 0o777 }
}

@MainActor
private func refusal(_ call: () async throws -> HostedSession) async -> String? {
    do {
        _ = try await call()
        return nil
    } catch let failure as RemoteFailure {
        return failure.error.code.rawValue
    } catch {
        return "\(error)"
    }
}

/// Start There: this Mac's signed start, through the other computer's own server and routes, and nothing without it.
@MainActor @Test(.enabled(if: hasTmux))
func aSessionStartsOnALinkedComputerOnlyWithThisMacsSignature() async throws {
    let mini = try await OtherMac()
    do {
        try #require(mini.hosted.available)
        #expect(await mini.ready())
        let peer = try mini.peer()
        #expect(try await peer.projects().map(\.path) == [mini.fixture.project.path])
        #expect(try await peer.hosted().isEmpty)
        let start = StartHosted(cwd: mini.fixture.project.path, agent: .claude, prompt: "Fix the build")

        // A token alone starts nothing, and nor does a signature over another start.
        #expect(await refusal { try await peer.client.post("/v1/hosted", json: start) } == "confirm_required")
        let other = try peer.signature(.settings, subject: try ConfirmMessage.subject(start: StartHosted(cwd: mini.fixture.project.path, agent: .codex)), faceID: false)
        #expect(await refusal { try await peer.client.post("/v1/hosted", json: start, confirm: other) } == "confirm_invalid")
        await mini.hosted.refresh()
        #expect(mini.hosted.sessions.isEmpty)

        let session = try await peer.startHosted(start)
        #expect(session.name.hasPrefix("sa-app-") && session.cwd == mini.fixture.project.path && session.agent == .claude)
        #expect(await eventually { mini.arguments == "['--', 'Fix the build']" }, "\(mini.arguments ?? "nothing")")
        #expect(try await peer.hosted().map(\.name) == [session.name])

        // A shell escape asks for the key that stands for the person at this Mac, which is what the start signs with then.
        let shell = StartHosted(cwd: mini.fixture.project.path, agent: .claude, prompt: "!ls")
        let unlocked = try peer.signature(.settings, subject: try ConfirmMessage.subject(start: shell), faceID: false)
        #expect(await refusal { try await peer.client.post("/v1/hosted", json: shell, confirm: unlocked) } == "confirm_required")
        let second = try await peer.startHosted(shell)
        #expect(Set(try await peer.hosted().map(\.name)) == [session.name, second.name])

        // A link the other computer has no keys for is a plain no, said in words for this Mac.
        let stranger = try mini.peer(keys: false)
        await #expect(throws: RemoteFailure.self) { _ = try await stranger.startHosted(start) }
        do { _ = try await stranger.startHosted(start) } catch { #expect(stranger.sentence(error) == "Mac mini didn’t let this Mac in. Link it again in Remote settings.") }

        try await peer.endHosted(session.name)
        try await peer.endHosted(second.name)
        #expect(await eventually { await mini.hosted.refresh(); return mini.hosted.sessions.isEmpty })
    } catch { Issue.record(error) }
    await mini.cleanUp()
}

/// The attach path end to end: a PTY running the real wrapper, the Unix sockets, the terminal stream over pinned TLS,
/// the other computer's TerminalHub, tmux and the agent.
@MainActor @Test(.enabled(if: hasTmux))
func aTabHereTypesIntoASessionThereSizesItAndClosingItOnlyDetaches() async throws {
    let mini = try await OtherMac()
    let here = mini.fixture.base.appendingPathComponent("laptop")
    var tabs: [TerminalTab] = []
    do {
        try #require(mini.hosted.available)
        #expect(await mini.ready())
        let peer = try mini.peer()
        let name = try await peer.startHosted(StartHosted(cwd: mini.fixture.project.path, agent: .claude)).name
        #expect(await eventually { await mini.showing(name, "Try \"refactor") })

        let opened = try LinkedTerminals.start(name, peer: peer, root: here)
        let wrapper = LinkedTerminals.wrapper(here).path
        #expect(opened.command == "'\(wrapper)' '\(opened.folder.path)'")
        #expect(mode(wrapper) == 0o700 && mode(opened.folder.path) == 0o700)
        #expect(mode(opened.folder.appendingPathComponent("tty").path) == 0o600 && mode(opened.folder.appendingPathComponent("size").path) == 0o600)

        let tab = try TerminalTab(wrapper, [opened.folder.path], cols: 60, rows: 20)
        tabs.append(tab)
        #expect(await eventually { tab.screen().contains("Try \"refactor") }, "\(tab.screen())")
        #expect(await eventually { await mini.window(name) == "60x20" })
        // Raw: keys go as they are, and the tab itself echoes nothing.
        #expect(!tab.echoes)
        // Only the tab: the socket it joined by is gone.
        #expect(!FileManager.default.fileExists(atPath: opened.folder.appendingPathComponent("tty").path))

        tab.type("hi")
        tab.type("\r")
        tab.type("\r")
        #expect(await eventually { mini.fixture.lines() == ["'hi'"] }, "\(mini.fixture.lines())")

        tab.resize(70, 22)
        #expect(await eventually { await mini.window(name) == "70x22" })

        // Closing the tab detaches: the folder goes, the other computer's viewer goes, and the session runs on.
        tab.close()
        #expect(await eventually { LinkedTerminals.running[opened.folder.lastPathComponent] == nil })
        #expect(!FileManager.default.fileExists(atPath: opened.folder.path))
        #expect(await eventually { await mini.hosted.clients(name).isEmpty })
        #expect(await eventually { tab.exited() })
        await mini.hosted.refresh()
        #expect(mini.hosted.sessions.contains { $0.name == name })

        // Back in, and the session ends there: the tab returns to its prompt by itself, put back as it was.
        let again = try LinkedTerminals.start(name, peer: peer, root: here)
        let second = try TerminalTab(wrapper, [again.folder.path], cols: 60, rows: 20)
        tabs.append(second)
        #expect(await eventually { second.screen().contains("Try \"refactor") })
        try await peer.endHosted(name)
        #expect(await eventually(15) { second.exited() }, "\(second.screen())")
        #expect(second.screen().hasSuffix("\u{1B}[?25h\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?2004l\u{1B}[?1004l\u{1B}[>4m\u{1B}[<u"))
        #expect(await eventually { LinkedTerminals.running[again.folder.lastPathComponent] == nil })
    } catch { Issue.record(error) }
    tabs.forEach { $0.stop() }
    await mini.cleanUp()
}

/// What a tab says when the other computer won't open the terminal, and a folder no tab ever came for.
@MainActor @Test(.enabled(if: hasTmux))
func aTabTheOtherComputerRefusesSaysWhyAndAnUnusedFolderGoes() async throws {
    let mini = try await OtherMac()
    let here = mini.fixture.base.appendingPathComponent("laptop")
    var tabs: [TerminalTab] = []
    do {
        try #require(mini.hosted.available)
        #expect(await mini.ready())
        let name = try await mini.peer().startHosted(StartHosted(cwd: mini.fixture.project.path, agent: .claude)).name

        // Keys the other computer never took: it refuses every try, and the tab ends with a line saying what to do.
        let refused = try LinkedTerminals.start(name, peer: try mini.peer(keys: false), root: here)
        let tab = try TerminalTab(LinkedTerminals.wrapper(here).path, [refused.folder.path], cols: 60, rows: 20)
        tabs.append(tab)
        #expect(await eventually(15) { tab.exited() }, "\(tab.screen())")
        #expect(tab.screen().contains("[Mac mini didn’t open its terminal for this Mac. Link it again in Remote settings.]"), "\(tab.screen())")
        await mini.hosted.refresh()
        #expect(mini.hosted.sessions.contains { $0.name == name })

        // Nobody opened this one.
        let unused = try LinkedTerminals.start(name, peer: try mini.peer(), root: here, patience: .milliseconds(200))
        #expect(await eventually { LinkedTerminals.running[unused.folder.lastPathComponent] == nil })
        #expect(!FileManager.default.fileExists(atPath: unused.folder.path))

        do {
            _ = try LinkedTerminals.start("../\(name)", peer: try mini.peer(), root: here)
            Issue.record("a name that isn't a session's opened a tab")
        } catch { #expect(error is TerminalRelay.Failure) }
    } catch { Issue.record(error) }
    tabs.forEach { $0.stop() }
    await mini.cleanUp()
}

@MainActor @Test func theTabsWrapperTakesOnlyAFolderSideAMadeAndOnlyInATerminal() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sa-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: base) }
    let wrapper = LinkedTerminals.wrapper(base)
    try LinkedTerminals.install(wrapper)
    #expect(mode(wrapper.path) == 0o700)
    let empty = base.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    for arguments in [[], [empty.path], [empty.path, "more"], ["--help"]] {
        let run = await HostedSessions.process(wrapper.path, arguments, timeout: 10)
        #expect(run.status == 64 && run.errors.contains("usage: sidea-remote FOLDER"), "\(arguments): \(run.status) \(run.errors)")
    }
    let relay = try TerminalRelay(folder: base.appendingPathComponent("rt/a1b2c3d4"))
    let piped = await HostedSessions.process(wrapper.path, [relay.folder.path], timeout: 10)
    #expect(piped.status == 64 && piped.errors.contains("not a terminal"), "\(piped.status) \(piped.errors)")
    relay.finish()
    #expect(await eventually { !FileManager.default.fileExists(atPath: relay.folder.path) })

    #expect(TerminalRelay.size(Data("120 40\n".utf8)).map { [$0.cols, $0.rows] } == [120, 40])
    for line in ["120\n", "0 40\n", "a b\n", "120 40 1\n", ""] { #expect(TerminalRelay.size(Data(line.utf8)) == nil, "\(line)") }
    let deep = URL(fileURLWithPath: "/" + String(repeating: "d", count: 120))
    #expect(throws: TerminalRelay.Failure.self) { _ = try TerminalRelay.listen(deep.appendingPathComponent("tty").path) }
}
