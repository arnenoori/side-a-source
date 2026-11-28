import Foundation
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

// `sidead hooks` in a home of its own, and the launcher it writes run for real. Nothing here reads or writes the user's
// ~/.claude: the folders are inside the test's temporary home.

private struct HooksRig {
    let directory: URL
    let home: URL
    let state: URL
    let environment: [String: String]
    let hooks: Hooks

    static var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    static var available: Bool {
        Run.which("python3") != nil && FileManager.default.fileExists(atPath: repository.appendingPathComponent("bridge/sidea_bridge.py").path)
    }

    init() throws {
        directory = try temporaryDirectory("hk")
        home = directory.appendingPathComponent("home")
        state = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["SIDEAD_BRIDGE"] = Self.repository.appendingPathComponent("bridge").path
        environment["CLAUDE_CONFIG_DIR"] = nil
        self.environment = environment
        hooks = Hooks(paths: DaemonPaths(state: state), environment: environment, home: home)
    }

    var location: BridgeLocation? { BridgeLocation.find(environment: environment) }
    var settings: URL { home.appendingPathComponent(".claude/settings.json") }

    func json(_ url: URL) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] }
    func clean() { try? FileManager.default.removeItem(at: directory) }
}

private var usersOwn: [String: Any] { ["model": "opus", "hooks": ["PermissionRequest": [["matcher": "Bash", "hooks": [["type": "command", "command": "my-guard"]]]]]] }

@Test(.enabled(if: HooksRig.available)) func hooksOnAddsOnlyThePermissionRequestHookBesideTheUsersOwnInEveryFolderAndOffTakesItAway() async throws {
    let rig = try HooksRig()
    defer { rig.clean() }
    try JSONSerialization.data(withJSONObject: usersOwn).write(to: rig.settings)
    let account = rig.directory.appendingPathComponent("work-login")
    try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
    try AccountBook(state: rig.state, home: rig.home).adopt("Work", directory: account.path)

    let off = await rig.hooks.command("status", location: rig.location)
    #expect(off.code == 0 && off.lines.allSatisfy { $0.hasPrefix("off") } && off.lines.count == 2)

    let on = await rig.hooks.command("on", location: rig.location)
    #expect(on.code == 0)
    #expect(on.lines.filter { $0.hasPrefix("on ") }.count == 2)
    for folder in [rig.settings, account.appendingPathComponent("settings.json")] {
        let hooks = try #require(rig.json(folder)?["hooks"] as? [String: Any])
        // Nothing else of Side A's runs on the user's tool calls.
        #expect(hooks.keys.sorted() == ["PermissionRequest"])
        let groups = try #require(hooks["PermissionRequest"] as? [[String: Any]])
        let added = try #require((groups.last?["hooks"] as? [[String: Any]])?.first)
        let command = try #require(added["command"] as? String)
        #expect(command.hasSuffix("# side-a-island") && command.contains("island-hook.sh") && !command.contains("python"))
        #expect(added["timeout"] as? Int == 86400)
        if folder == rig.settings {
            #expect(groups.count == 2 && (groups[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "my-guard")
            #expect(rig.json(folder)?["model"] as? String == "opus")
        }
    }
    let launcher = rig.state.appendingPathComponent("root/runtime/island-hook.sh")
    #expect(FileManager.default.fileExists(atPath: launcher.path))
    #expect(try String(contentsOf: launcher, encoding: .utf8).contains(Hooks.socket(root: rig.hooks.root)))
    #expect(await rig.hooks.command("on", location: rig.location).code == 0)
    #expect((try #require(rig.json(rig.settings)?["hooks"] as? [String: Any])["PermissionRequest"] as? [Any])?.count == 2)

    // An account taken off the list since is still cleaned.
    try AccountBook(state: rig.state, home: rig.home).remove("Work")
    let gone = await rig.hooks.command("off", location: rig.location)
    #expect(gone.code == 0 && gone.lines.filter { $0.hasPrefix("off") }.count == 2)
    #expect(NSDictionary(dictionary: try #require(rig.json(rig.settings))).isEqual(to: usersOwn))
    #expect(rig.json(account.appendingPathComponent("settings.json"))?.isEmpty == true)
    #expect(await rig.hooks.command("status", location: rig.location).lines.allSatisfy { $0.hasPrefix("off") })
}

@Test(.enabled(if: HooksRig.available)) func hooksRefuseAFileTheyDontUnderstandAndSayWhichOne() async throws {
    let rig = try HooksRig()
    defer { rig.clean() }
    try Data("[1, 2]".utf8).write(to: rig.settings)
    let result = await rig.hooks.command("on", location: rig.location)
    #expect(result.code == 1 && result.lines.contains { $0.contains("settings.json") && $0.contains("left it unchanged") })
    #expect(try String(contentsOf: rig.settings, encoding: .utf8) == "[1, 2]")
}

@Test func hooksSayWhatIsMissingAndRefuseASocketPathThatCannotBind() async throws {
    let rig = try HooksRig()
    defer { rig.clean() }
    #expect(await rig.hooks.command("on", location: nil).code == 1)
    let long = Hooks(paths: DaemonPaths(state: URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 100))), environment: rig.environment, home: rig.home)
    let refused = await long.command("on", location: BridgeLocation(python: "/usr/bin/python3", directory: rig.directory))
    #expect(refused.code == 1 && refused.lines.first?.contains("too long") == true)
}

@Test func theClaudeFolderInTheEnvironmentIsWhereHooksGoWhenItIsSet() throws {
    let rig = try HooksRig()
    defer { rig.clean() }
    var environment = rig.environment
    environment["CLAUDE_CONFIG_DIR"] = rig.directory.appendingPathComponent("elsewhere/").path
    let hooks = Hooks(paths: DaemonPaths(state: rig.state), environment: environment, home: rig.home)
    #expect(hooks.folders() == [rig.directory.appendingPathComponent("elsewhere").path])
    #expect(rig.hooks.folders() == [rig.home.appendingPathComponent(".claude").path])
}

// MARK: the launcher, run as Claude Code runs it

private func payload(_ rig: HooksRig, command: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["session_id": "sess-9", "cwd": rig.home.path, "permission_mode": "default", "hook_event_name": "PermissionRequest",
                                                "tool_name": "Bash", "tool_input": ["command": command, "description": "Run it"]])
}

private func launch(_ rig: HooksRig, _ input: Data) async -> (output: String, status: Int32, seconds: Double) {
    let launcher = rig.hooks.root.appendingPathComponent("runtime/island-hook.sh").path
    let started = Date()
    let result = await Run.process("/bin/sh", [launcher, "claude"], environment: rig.environment, input: input, timeout: 60)
    return (result.output, result.status, Date().timeIntervalSince(started))
}

@Test(.enabled(if: HooksRig.available)) func theHookLeavesClaudeCodesOwnPromptAloneWhenTheDaemonIsNotRunning() async throws {
    let rig = try HooksRig()
    defer { rig.clean() }
    #expect(await rig.hooks.command("on", location: rig.location).code == 0)
    let ran = await launch(rig, try payload(rig, command: "npm test"))
    // No answer, no error, and quickly: Claude Code shows its own prompt.
    #expect(ran.status == 0 && ran.output.isEmpty && ran.seconds < 5)
    // A socket file nobody listens on is the same.
    let stale = rig.hooks.root.appendingPathComponent("runtime/island.sock")
    FileManager.default.createFile(atPath: stale.path, contents: nil)
    let again = await launch(rig, try payload(rig, command: "npm test"))
    #expect(again.status == 0 && again.output.isEmpty)
}

@Test(.enabled(if: HooksRig.available)) func theHookClaudeCodeRunsAsksTheDaemonAndPrintsTheAnswerThePhoneGave() async throws {
    let rig = try HooksRig()
    defer { rig.clean() }
    #expect(await rig.hooks.command("on", location: rig.location).code == 0)
    let approvals = try ApprovalRig(directory: rig.directory, socket: Hooks.socket(root: rig.hooks.root))
    try await withDaemon(services: ApprovalServices(approvals: approvals.approvals)) { daemon, _ in
        let fake = FakePhone()
        let paired = try await fake.pair(with: daemon, pin: daemon.identity.spkiHash)
        let phone = Phone(phone: fake, token: paired.token, deviceID: paired.deviceID, http: try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash), daemon: daemon)

        let first = try payload(rig, command: "npm test")
        async let allowed = launch(rig, first)
        #expect(await eventually { (try? await phone.requests().count) == 1 })
        let request = try #require(try await phone.requests().first)
        #expect(request.action == .command("npm test") && request.sessionID == "sess-9")
        #expect(try await phone.answer(request.id, .allow(confirmDestructive: false), signer: .unlock).status == 200)
        let yes = await allowed
        #expect(yes.status == 0)
        let decision = try #require(try JSONSerialization.jsonObject(with: Data(yes.output.utf8)) as? [String: Any])
        let inner = try #require((decision["hookSpecificOutput"] as? [String: Any]))
        #expect(inner["hookEventName"] as? String == "PermissionRequest" && (inner["decision"] as? [String: Any])?["behavior"] as? String == "allow")

        let publish = try payload(rig, command: "npm publish")
        async let denied = launch(rig, publish)
        #expect(await eventually { (try? await phone.requests().count) == 1 })
        let second = try #require(try await phone.requests().first)
        #expect(try await phone.answer(second.id, .deny(message: "Not from this machine.")).status == 200)
        let no = await denied
        let refusal = try #require((try JSONSerialization.jsonObject(with: Data(no.output.utf8)) as? [String: Any])?["hookSpecificOutput"] as? [String: Any])
        let verdict = try #require(refusal["decision"] as? [String: Any])
        #expect(verdict["behavior"] as? String == "deny" && verdict["message"] as? String == "Not from this machine.")

        // Handed back to the terminal, the hook prints nothing and Claude Code asks.
        let list = try payload(rig, command: "ls")
        async let handed = launch(rig, list)
        #expect(await eventually { (try? await phone.requests().count) == 1 })
        let third = try #require(try await phone.requests().first)
        #expect(try await phone.answer(third.id, .terminal).status == 200)
        let ask = await handed
        #expect(ask.status == 0 && ask.output.isEmpty)
    }
}

/// The stand-in agent the end-to-end run uses, against the daemon in this process: it runs every PermissionRequest hook in the
/// settings file, the user's own and Side A's, and reports what Claude Code would do.
@Test(.enabled(if: HooksRig.available)) func theStandInAgentSeesAllowDenyAndAskThroughTheInstalledHook() async throws {
    let rig = try HooksRig()
    defer { rig.clean() }
    try JSONSerialization.data(withJSONObject: usersOwn).write(to: rig.settings)
    #expect(await rig.hooks.command("on", location: rig.location).code == 0)
    let standIn = HooksRig.repository.appendingPathComponent("Daemon/Tests/Fixtures/fake-claude-permission.py").path
    func run(_ command: String) async -> [String: Any] {
        let result = await Run.process(Run.which("python3") ?? "/usr/bin/python3", [standIn, "--command", command, "--cwd", rig.home.path, "--timeout", "30"], environment: rig.environment, timeout: 60)
        let line = result.output.split(separator: "\n").last { $0.hasPrefix("RESULT ") }.map { String($0.dropFirst(7)) } ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? ["output": result.output, "errors": result.errors]
    }
    // Nothing listens yet: both hooks ran, neither decided, so Claude Code would ask.
    let open = await run("npm test")
    #expect(open["outcome"] as? String == "ask" && open["hooks"] as? Int == 2)

    let approvals = try ApprovalRig(directory: rig.directory, socket: Hooks.socket(root: rig.hooks.root))
    try await withDaemon(services: ApprovalServices(approvals: approvals.approvals)) { daemon, _ in
        let fake = FakePhone()
        let paired = try await fake.pair(with: daemon, pin: daemon.identity.spkiHash)
        let phone = Phone(phone: fake, token: paired.token, deviceID: paired.deviceID, http: try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash), daemon: daemon)
        async let allowed = run("npm test")
        #expect(await eventually { (try? await phone.requests().count) == 1 })
        let first = try #require(try await phone.requests().first)
        #expect(try await phone.answer(first.id, .allow(confirmDestructive: false), signer: .unlock).status == 200)
        #expect(await allowed["outcome"] as? String == "allow")
        async let denied = run("npm publish")
        #expect(await eventually { (try? await phone.requests().count) == 1 })
        let second = try #require(try await phone.requests().first)
        #expect(try await phone.answer(second.id, .deny(message: "Not from here.")).status == 200)
        let no = await denied
        #expect(no["outcome"] as? String == "deny" && no["message"] as? String == "Not from here.")
    }
}
