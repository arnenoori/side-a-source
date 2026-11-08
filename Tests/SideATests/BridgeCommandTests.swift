import Foundation
@testable import SideA
import SideACore
import Testing

/// Each argv, as `[]` when the bridge's own parser takes it, or argparse's complaint.
private func bridgeRefusals(_ commands: [[String]]) throws -> [[String]: String] {
    let script = """
    import contextlib, io, json, sys
    sys.path.insert(0, sys.argv[1])
    import sidea_bridge
    parser = sidea_bridge.build_parser()
    refused = []
    for argv in json.load(sys.stdin):
        errors = io.StringIO()
        try:
            with contextlib.redirect_stderr(errors):
                parser.parse_args(["--root", "/tmp/side-a"] + argv)
            refused.append("")
        except SystemExit:
            refused.append(errors.getvalue().strip().splitlines()[-1])
    print(json.dumps(refused))
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", script, TranscriptFixture.bridge.deletingLastPathComponent().path]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    input.fileHandleForWriting.write(try JSONEncoder().encode(commands))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let refused = try JSONDecoder().decode([String].self, from: data)
    #expect(refused.count == commands.count)
    return Dictionary(zip(commands, refused).filter { !$0.1.isEmpty }, uniquingKeysWith: { first, _ in first })
}

@MainActor private func recorded(_ run: (AccountStore) async -> Void) async -> [[String]] {
    final class Calls { var argv: [[String]] = [] }
    let calls = Calls()
    let store = AccountStore(demo: true, root: FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))"))
    store.testBridge = { args in calls.argv.append(args); throw BridgeFailure(message: "recorded") }
    await run(store)
    return calls.argv
}

@MainActor private func tokenArgs() async throws -> [[String]] {
    actor Calls { var argv: [[String]] = []; func add(_ args: [String]) { argv.append(args) } }
    let calls = Calls()
    let cache = PoolTokenCache()
    let bridge: ([String]) async throws -> Data = { args in
        await calls.add(args)
        return Data(#"{"accessToken":"t","accountId":null,"expiresAt":4102444800000,"hash":"h1"}"#.utf8)
    }
    for codex in [false, true] {
        _ = try await cache.token("acct", refused: false, codex: codex, now: 0, bridge: bridge)
        _ = try await cache.token("acct", refused: true, codex: codex, now: 0, bridge: bridge)
    }
    return await calls.argv
}

/// Every command line the app hands the bridge, so a renamed command or option fails here instead of in the menu.
@MainActor @Test func everyCommandTheAppRunsParsesInTheBridge() async throws {
    let account = "11111111-2222-3333-4444-555555555555"
    let keep = ["--keep", "pinned-session"]
    var commands: [[String]] = [
        ["login", account], ["logout", account], ["forget", account], ["status", account], ["activate", account],
        ["adopt", account], ["usage", account], ["renew", account], ["prime", account],
        ["swap", "mac", account], ["swap", "mac", account, "--share"], ["active"],
        ["report"], ["report", "--sync", "/tmp/sync"],
        ["codex-pool-home"], ["codex-pool-home", "--url", "http://127.0.0.1:1", "--remote"],
        ["hosting", "install"], ["hosting", "install", "--bundled", "/Applications/Side A.app/Contents/Helpers/tmux"],
        ["hosting", "codex-env", account],
        ["island", "sync"], ["island", "off"], ["island", "trust"],
        ["sessions", "live"], ["sessions", "serve"], ["sessions", "index", "--seconds", "20"],
        ["sessions", "index", "--seconds", "8"], ["sessions", "index", "--seconds", "8", "--path", "/a.jsonl", "--path", "/b.jsonl"],
        ["setup", "overview"], ["setup", "mcp-health"],
        ["cleanup", "disk", "--days", String(90.0)] + keep, ["cleanup", "disk", "--days", "30"] + keep,
        ["cleanup", "archive", "--days", String(90.0)] + keep, ["cleanup", "archive", "--days", String(30)] + keep,
        ["cleanup", "restore"], ["cleanup", "worktrees"], ["cleanup", "remove-worktree", "/tmp/tree"],
    ]
    for command in ["hook", "shell", "host-terminal", "live", "inbox"] {
        commands += ["on", "off", "status"].map { [command, $0] }
    }
    for agent in [IslandAgent.claude, .codex] {
        commands += ["on", "off"].map { ["island", $0, "--agent", agent.rawValue] }
    }
    commands += try await tokenArgs()
    commands += await recorded { store in
        let id = store.config.accounts[0].id
        await store.renew(id)
        await store.refreshActive()
    }
    #expect(commands.contains(["pool-token", "acct", "--refused", "h1"]))
    #expect(commands.contains(["codex-pool-token", "acct", "--refused", "h1"]))
    #expect(commands.contains { $0.first == "renew" })
    #expect(try bridgeRefusals(commands) == [:])
}

@Test func theCheckCatchesACommandTheBridgeDoesntKnow() throws {
    let refused = try bridgeRefusals([["usage"], ["swap", "mac"], ["hook", "maybe"], ["usage", "a"]])
    #expect(Set(refused.keys) == [["usage"], ["swap", "mac"], ["hook", "maybe"]])
}
