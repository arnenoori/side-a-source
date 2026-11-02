import Foundation
import SideACore

struct DependencyReport: Sendable {
    var python = Dependency(name: "Python 3.9+")
    var claude = Dependency(name: "Claude Code")
    var codex = Dependency(name: "Codex CLI")
    /// Optional: hosted sessions need it, nothing else does. The app ships its own (Contents/Helpers/tmux).
    var tmux = Dependency(name: "tmux")
    func agent(_ provider: AgentProvider) -> Dependency { provider == .claude ? claude : codex }
    func ready(for provider: AgentProvider) -> Bool { python.state == .ready && agent(provider).state == .ready }
}

enum DependencyCheck {
    static let bundledTmux = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tmux").path
    static func scan() async -> DependencyReport {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            func paths(_ name: String) -> [String] { ["\(home)/.local/bin/\(name)", "\(home)/.npm-global/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] }
            return DependencyReport(
                // A Homebrew upgrade can leave only the versioned link (python3.14) until `brew link` runs again.
                python: probe("Python 3.9+", paths: paths("python3") + (9...16).reversed().flatMap { paths("python3.\($0)") }
                    + ["/Library/Developer/CommandLineTools/usr/bin/python3", "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"], python: true),
                claude: probe("Claude Code", paths: paths("claude")),
                codex: probe("Codex CLI", paths: paths("codex")),
                tmux: probe("tmux", paths: [bundledTmux, "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux"], argument: "-V"))
        }.value
    }
    /// A tool that answered before and is still on disk stays usable: on a busy Mac `--version` can
    /// outlast the probe, and losing Python would stop every reading until the next scan.
    static func keepingWorking(_ old: DependencyReport, _ new: DependencyReport) -> DependencyReport {
        func keep(_ old: Dependency, _ new: Dependency) -> Dependency {
            guard new.state != .ready, old.state == .ready, let path = old.path,
                  FileManager.default.isExecutableFile(atPath: path) else { return new }
            return old
        }
        return DependencyReport(python: keep(old.python, new.python), claude: keep(old.claude, new.claude), codex: keep(old.codex, new.codex),
                                tmux: keep(old.tmux, new.tmux))
    }
    /// The first that answers; for Python, the first 3.11 or later, else the first 3.9 or later (macOS's own is 3.9).
    private static func probe(_ name: String, paths: [String], python: Bool = false, argument: String = "--version") -> Dependency {
        var found = false
        var fallback: Dependency?
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            found = true
            guard let output = versionOutput(path, argument), let version = Dependency.version(in: output),
                  !python || Dependency.supportsPython(version) else { continue }
            let dependency = Dependency(name: name, path: path, version: version, state: .ready)
            if !python || Dependency.prefersPython(version) { return dependency }
            fallback = fallback ?? dependency
        }
        return fallback ?? Dependency(name: name, state: found ? .incompatible : .missing)
    }
    /// Apple's installer for the Command Line Tools, which include Python 3.9 or later.
    static func installCommandLineTools() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
    private static func versionOutput(_ executable: String, _ argument: String) -> String? {
        // A bounded probe off the main actor. A file avoids a full stdout pipe blocking exit.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forUpdating: file) else { return nil }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [argument]
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:\(home)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = handle; process.standardError = handle
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.1); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; return nil }
        guard process.terminationStatus == 0 else { return nil }
        try? handle.seek(toOffset: 0)
        return (try? handle.read(upToCount: 1024)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
