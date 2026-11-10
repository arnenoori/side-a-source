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
                python: await probe("Python 3.9+", paths: paths("python3") + (9...16).reversed().flatMap { paths("python3.\($0)") }
                    + ["/Library/Developer/CommandLineTools/usr/bin/python3", "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"], python: true),
                claude: await probe("Claude Code", paths: paths("claude")),
                codex: await probe("Codex CLI", paths: paths("codex")),
                tmux: await probe("tmux", paths: [bundledTmux, "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux"], argument: "-V"))
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
    private static func probe(_ name: String, paths: [String], python: Bool = false, argument: String = "--version") async -> Dependency {
        var found = false
        var fallback: Dependency?
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            found = true
            guard let output = await versionOutput(path, argument), let version = Dependency.version(in: output),
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
    private static func versionOutput(_ executable: String, _ argument: String) async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.local/bin:\(home)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let run = await ProcessRunner.run(executable, [argument], environment: ["PATH": path], timeout: 10)
        guard run.launchError == nil, !run.timedOut, run.status == 0 else { return nil }
        return String(data: (run.output + run.errors).prefix(1024), encoding: .utf8)
    }
}
