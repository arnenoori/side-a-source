import Darwin
import Foundation
@testable import SideA
import SideAProtocol
import SideARemoteKit
import Testing

private let hasTmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }

private func mode(_ path: String) -> Int? {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber).map { $0.intValue & 0o777 }
}

/// This Mac's link to the other one, as Settings keeps it.
@MainActor
private func link(to mini: OtherMac) throws -> LinkedComputer {
    let endpoint = Endpoint(macID: "mini", baseURL: try #require(URL(string: "https://127.0.0.1:\(mini.port)")), serverKeyHash: mini.pin, name: "Mac mini")
    return LinkedComputer(id: "mini", name: "Mac mini", endpoint: endpoint, token: mini.token, linked: 0, confirm: mini.confirm.rawRepresentation,
                          unlock: mini.unlock.rawRepresentation, device: "mini-here", me: "laptop")
}

@MainActor
private func control(_ root: URL, _ computers: [LinkedComputer], pin: String) -> ShellControl {
    ShellControl(root: root, computers: { computers }, peer: { computer in
        RemotePeer(computer, info: LinkedComputers.client(MacInfo(id: "laptop", name: "MacBook")), transport: URLSessionTransport(trust: PinnedTrust(.pinned(pin))))
    })
}

/// `sidea attach NAME@COMPUTER` end to end: the launcher the shell runs, the app's socket, the sockets of a tab, the
/// terminal stream over pinned TLS, and the other computer's tmux and agent.
@MainActor @Test(.enabled(if: hasTmux))
func sideaAttachJoinsASessionOnALinkedComputerAndListsThemThere() async throws {
    let mini = try await OtherMac()
    let here = try HostedFixture()
    var tabs: [TerminalTab] = []
    var answering: ShellControl?
    do {
        try #require(mini.hosted.available)
        #expect(await mini.ready())
        let laptop = HostedSessions(root: here.root, environment: here.environment, bridge: here.bridge)
        await laptop.install()
        let name = try await mini.peer().startHosted(StartHosted(cwd: mini.fixture.project.path, agent: .claude)).name
        #expect(await eventually { await mini.showing(name, "Try \"refactor") })

        let launcher = here.root.appendingPathComponent("runtime/sidea-tmux").path
        func sidea(_ arguments: String...) async -> (status: Int32, output: String, errors: String) {
            let run = await HostedSessions.process(launcher, arguments, environment: here.environment, timeout: 40)
            return (run.status, run.output, run.errors)
        }
        // The app isn't running: one line saying so, and nothing else happens.
        let closed = await sidea("attach", "\(name)@Mac mini")
        #expect(closed.status == 69 && closed.errors == "Side A isn't running. Open it, then try again.", "\(closed)")

        let app = control(here.root, [try link(to: mini)], pin: mini.pin)
        try app.start()
        answering = app
        // Only this user reaches it.
        #expect(mode(ShellControl.folder(here.root).path) == 0o700 && mode(ShellControl.folder(here.root).appendingPathComponent("app.sock").path) == 0o600)

        // Listed by computer, in the form attach takes.
        let listed = await sidea("ls", "--all")
        #expect(listed.status == 0 && listed.output == "\(name)@Mac mini  claude  \(mini.fixture.project.path)\n", "\(listed)")

        // The computer by its name in any case; the terminal it was typed in becomes the session's, as a tab Side A opens.
        let tab = try TerminalTab(launcher, ["attach", "\(name)@mac MINI"], cols: 60, rows: 20)
        tabs.append(tab)
        #expect(await eventually { tab.screen().contains("Try \"refactor") }, "\(tab.screen())")
        #expect(await eventually { await mini.window(name) == "60x20" })
        tab.type("hi")
        tab.type("\r")
        tab.type("\r")
        #expect(await eventually { mini.fixture.lines() == ["'hi'"] }, "\(mini.fixture.lines())")
        // Closing it only detaches: the session runs on there.
        tab.close()
        #expect(await eventually { tab.exited() })
        #expect(await eventually { await mini.hosted.clients(name).isEmpty })
        await mini.hosted.refresh()
        #expect(mini.hosted.sessions.contains { $0.name == name })

        // Each thing it can't do is one line, and opens nothing.
        let folders = { (try? FileManager.default.contentsOfDirectory(atPath: here.root.appendingPathComponent("runtime/rt").path)) ?? [] }
        let opened = folders()
        for (target, said) in [("\(name)@Nowhere", "No linked computer is called Nowhere."),
                               ("sa-gone-0000@Mac mini", "No session called sa-gone-0000 is running on Mac mini. sidea ls --all lists them."),
                               ("@Mac mini", "Name a session on a linked computer: sidea attach <session>@<computer>.")] {
            let refused = await sidea("attach", target)
            #expect(refused.status == 1 && refused.errors == said && refused.output.isEmpty, "\(target): \(refused)")
        }
        #expect(folders() == opened)
    } catch { Issue.record(error) }
    answering?.stop()
    tabs.forEach { $0.stop() }
    await here.cleanUp()
    await mini.cleanUp()
}

/// What the socket takes, and the names it matches, without a network.
@MainActor @Test func theAppAnswersOnlyItsTwoRequestsAndNamesAComputerExactlyOnce() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sa-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    // Nothing answers there, so each is listed as out of reach.
    let endpoint = Endpoint(macID: "a", baseURL: try #require(URL(string: "https://127.0.0.1:\(freePort())")), serverKeyHash: "", name: "Mac mini")
    let first = LinkedComputer(id: "host-a", name: "Mac mini", endpoint: endpoint, token: "", linked: 0)
    let second = LinkedComputer(id: "host-b", name: "mac mini", endpoint: endpoint, token: "", linked: 0)
    let shell = control(root, [first, second], pin: "")
    #expect(throws: Never.self) { try shell.computer("HOST-B").get() }
    #expect(try shell.computer("host-a").get().id == "host-a")
    #expect(await shell.answer("attach sa-app-1a2b@Mac mini") == "no 2 linked computers are called Mac mini. Name one by its id: host-a, host-b.")
    #expect(await shell.answer("attach sa-app-1a2b@Studio") == "no No linked computer is called Studio.")
    for line in ["", "attach", "attach ", "ls", "list all", "LIST", "attach sa-app-1a2b"] {
        let answer = await shell.answer(line)
        #expect(answer.hasPrefix("no ") && !answer.contains("\n"), "\(line): \(answer)")
    }

    // A folder that is a link, or someone else's, is not one the socket goes in.
    let elsewhere = root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("runtime"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: ShellControl.folder(root), withDestinationURL: elsewhere)
    #expect(throws: TerminalRelay.Failure.self) { try shell.start() }
    try FileManager.default.removeItem(at: ShellControl.folder(root))

    // A line longer than a request can be is answered no, and the socket goes on answering.
    try shell.start()
    defer { shell.stop() }
    let socket = ShellControl.folder(root).appendingPathComponent("app.sock").path
    #expect(await ask(socket, String(repeating: "x", count: ShellSocket.maxLine + 10)) == "no That request is too long.\n")
    let listed = await ask(socket, "list").split(separator: "\n", omittingEmptySubsequences: false)
    #expect(listed.first == "ok" && listed.count == 4 && listed[1].hasPrefix("! ") && listed[2].hasPrefix("! ") && listed[3].isEmpty, "\(listed)")
}

/// One request on the socket, as `sidea` sends it; what came back before the app closed the connection.
private func ask(_ path: String, _ line: String) async -> String {
    await Task.detached {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
            raw[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { return "not connected" }
        var wait = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var reply = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<100 {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            reply += chunk[..<count]
        }
        return String(decoding: reply, as: UTF8.self)
    }.value
}
