import AppKit
import Foundation
import ServiceManagement
import SideACore

struct BridgeFailure: LocalizedError, BridgeError, Sendable {
    let message: String
    var kind: BridgeErrorKind = .other
    var errorDescription: String? { message }
    init(message: String, kind: BridgeErrorKind = .other) { self.message = message; self.kind = kind }
    init(stderr: String) { (kind, message) = BridgeErrorKind.parse(stderr) }
}

extension AccountStore {
    /// Whether a bridge command changes a login, the Keychain or files, rather than only reading.
    static func changes(_ args: [String]) -> Bool {
        guard let command = args.first else { return false }
        if command == "cleanup" { return args.count > 1 && ["archive", "remove-worktree", "restore"].contains(args[1]) }
        return ["login", "logout", "adopt", "renew", "activate", "swap", "forget", "prime", "codex-pool-home"].contains(command)
    }
    func bridgeOutput(_ args: [String], timeout: TimeInterval = 60, priority: QualityOfService = .default) async throws -> Data {
        let changes = Self.changes(args)
        if changes { bridgeChanges += 1 }
        defer { if changes { bridgeChanges -= 1 } }
        if let testBridge { return try await testBridge(args) }
        guard let python, let bridgeURL else { throw BridgeFailure(message: "Install Python 3 to connect your accounts.") }
        let arguments = [bridgeURL.path, "--root", root.path] + args
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = arguments
            process.qualityOfService = priority
            let output = Pipe()
            process.standardOutput = output
            // The helper returns sanitized diagnostics; raw CLI stderr is never logged.
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            // The bridge leads its own process group; stopping the group also stops a hung claude or codex child.
            let watchdog = DispatchWorkItem { if process.isRunning { kill(-process.processIdentifier, SIGTERM); process.terminate() } }
            let deadline = BridgeDeadline.current(timeout)
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: watchdog)
            defer { watchdog.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let message = (String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Account verification failed.")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // The watchdog's signal leaves nothing on stderr.
                throw BridgeFailure(stderr: message.isEmpty ? "the helper didn't finish within \(Int(deadline))s" : message)
            }
            return data
        }.value
    }

    /// Whether one of Side A's setups outside its folder (`hook`, `shell`, `live`, `host-terminal`) is installed,
    /// once the bridge has set it to `state`.
    func integration(_ command: String, _ state: String) async throws -> Bool {
        struct State: Decodable { let installed: Bool }
        return try JSONDecoder().decode(State.self, from: try await bridgeOutput([command, state])).installed
    }
    func setShellSwitching(_ enabled: Bool) async {
        do { shellSwitching = try await integration("shell", enabled ? "on" : "off") } catch { self.error = error.localizedDescription }
    }
    func setHostTerminal(_ enabled: Bool) async {
        do { hostTerminal = try await integration("host-terminal", enabled ? "on" : "off") } catch { self.error = error.localizedDescription }
        await syncHosting()
    }

    /// Side A's tmux server is for people who asked for it: terminal hosting, or Remote, which serves hosted sessions.
    var hostingWanted: Bool { hostTerminal || remote.on }

    /// Installs and watches Side A's tmux when it's wanted, and stops watching when it no longer is. Sessions already
    /// running there keep running; `sidea attach` still reaches them.
    func syncHosting() async {
        if hostingWanted { await hosted.install() } else { hosted.stop() }
    }
    func setLiveLimits(_ enabled: Bool) async {
        config.liveLimits = enabled; persist()
        do { liveLimits = try await integration("live", enabled ? "on" : "off") } catch { self.error = error.localizedDescription }
    }
    func setLimitHook(_ enabled: Bool) async {
        do { limitHook = try await integration("hook", enabled ? "on" : "off") } catch { self.error = error.localizedDescription }
    }

    /// Undoes what Side A set up outside its folder, then moves the app to the Trash. Logins stay in the Keychain
    /// unless the accounts are forgotten, which signs each out through its own CLI first.
    func uninstall(forgetAccounts: Bool) async {
        preferences?.deleteFiles()
        await setHostTerminal(false)
        await setShellSwitching(false)
        await setLiveLimits(false)
        await setLimitHook(false)
        await setIsland(nil, "off")
        await remote.uninstall()
        await keepAwake.uninstall()
        if SMAppService.mainApp.status == .enabled { try? await SMAppService.mainApp.unregister() }
        await sessions.deleteIndex()
        await setPool(false)
        // The login backups are Side A's own copies; they go even when the logins stay.
        for account in config.accounts where account.provider == .claude { _ = try? await bridgeOutput(["forget", account.id]) }
        let files = FileManager.default
        if forgetAccounts {
            for account in config.accounts where account.ready && !isActive(account) {
                _ = try? await bridgeOutput(["logout", account.id])
            }
            try? files.removeItem(at: root)
            if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        } else {
            for name in ["runtime/report.json", "runtime/report-cache.json", "runtime/usage-cache.json", "runtime/queued-followups.json",
                         "runtime/queued-followups.unread.json", "runtime/dropped-followups.json"] {
                try? files.removeItem(at: root.appendingPathComponent(name))
            }
        }
        if let id = Bundle.main.bundleIdentifier {
            try? files.removeItem(at: files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/\(id)"))
        }
        if Bundle.main.bundleURL.pathExtension == "app" { try? files.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil) }
        NSApp.terminate(nil)
    }
}
