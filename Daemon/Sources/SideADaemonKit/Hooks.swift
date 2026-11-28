import Foundation

/// `sidead hooks on | off | status`: the one place the daemon touches Claude Code's settings. Permission requests reach the phone only
/// through a hook Claude Code runs, so turning them on adds a `PermissionRequest` hook marked `side-a-island` to `settings.json` in
/// Claude Code's folder (`$CLAUDE_CONFIG_DIR`, else `~/.claude`) and in each account's folder, beside the user's own hooks. The
/// bridge does the editing, as it does for the Mac app (`island on`), so the marker, the removal and the care for the user's
/// formatting are the same. With sidead stopped, the hook finds no socket and Claude Code asks in its own terminal.
struct Hooks {
    let paths: DaemonPaths
    let environment: [String: String]
    let home: URL

    init(paths: DaemonPaths, environment: [String: String] = ProcessInfo.processInfo.environment, home: URL? = nil) {
        self.paths = paths; self.environment = environment
        // The bridge's Python reads HOME, so this does too.
        self.home = home ?? URL(fileURLWithPath: environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory())
    }

    var root: URL { paths.state.appendingPathComponent("root") }

    /// Where the hook's socket is, and so what the launcher the bridge writes names. The daemon listens on the same path.
    static func socket(root: URL) -> String { root.appendingPathComponent("runtime/island.sock").path }

    private var remembered: URL { paths.state.appendingPathComponent("hooks.json") }

    /// Claude Code's own folder, then each account's, with nothing twice.
    func folders() -> [String] {
        let own = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home.appendingPathComponent(".claude").path
        var seen: Set<String> = []
        return ([own] + AccountBook(state: paths.state, home: home).load().map(\.configDir)).map { ($0 as NSString).standardizingPath }.filter { seen.insert($0).inserted }
    }

    /// Folders that were turned on, which `off` also visits when an account has since gone from the list.
    private func known() -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(contentsOf: remembered))) ?? []
    }

    private func remember(_ folders: [String]) {
        do {
            try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(folders).write(to: remembered, options: .atomic)
        } catch {
            DaemonLog.line("couldn't record which folders have the hook, so `hooks off` may miss one: \(error.localizedDescription)")
        }
        chmod(remembered.path, 0o600)
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// What the bridge says about one folder: whether the hook is in its `settings.json`.
    func run(_ state: String, folder: String, location: BridgeLocation) async throws -> Bool {
        var arguments = [location.script, "--root", root.path, "island", state, "--agent", "claude", "--claude-dir", folder]
        if state == "on" { arguments.append("--permission-only") }
        let result = await Run.process(location.python, arguments, environment: environment, timeout: 60)
        guard result.status == 0 else {
            let said = result.errors.split(separator: "\n").last.map(String.init) ?? "the bridge failed (\(result.status))"
            throw Failure(description: "\(folder)/settings.json: \(said)")
        }
        let reply = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any]
        return reply?["claude"] as? Bool ?? false
    }

    /// The lines to print, and the exit code.
    func command(_ state: String, location: BridgeLocation?) async -> (lines: [String], code: Int32) {
        guard let location else { return (["sidead: python3 or the bridge scripts weren't found. Set SIDEAD_PYTHON and SIDEAD_BRIDGE."], 1) }
        if state == "on", Hooks.socket(root: root).utf8.count >= HookSocket.pathLimit {
            return (["sidead: the state folder's path is too long for the hook's socket. Use a shorter --state-dir."], 1)
        }
        var lines: [String] = []
        var failed = false
        let targets = state == "off" ? Array(Set(folders() + known())).sorted() : folders()
        var on: [String] = []
        var unchanged: [String] = []
        for folder in targets {
            do {
                let installed = try await run(state, folder: folder, location: location)
                if installed { on.append(folder) }
                lines.append("\(installed ? "on " : "off") \(folder)")
            } catch {
                failed = true
                unchanged.append(folder)
                lines.append("sidead: \(error)")
            }
        }
        // A folder `off` couldn't reach is still on, and is looked for again next time.
        if state != "status" { remember(on + (state == "off" ? unchanged : [])) }
        if state == "on", !failed {
            lines.append("Permission requests from Claude Code now go to your phone while sidead runs. Sessions already open pick the hook up when they restart.")
        }
        return (lines, failed ? 1 : 0)
    }
}
