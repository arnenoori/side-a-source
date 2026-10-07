import Foundation
import SideACore

struct DependencyReport: Sendable {
    var python = Dependency(name: "Python 3.9+")
    var claude = Dependency(name: "Claude Code")
    var codex = Dependency(name: "Codex CLI")
    func agent(_ provider: AgentProvider) -> Dependency { provider == .claude ? claude : codex }
    func ready(for provider: AgentProvider) -> Bool { python.state == .ready && agent(provider).state == .ready }
}

enum DependencyCheck {
    static func scan() async -> DependencyReport {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            func paths(_ name: String) -> [String] { ["\(home)/.local/bin/\(name)", "\(home)/.npm-global/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] }
            return DependencyReport(
                python: probe("Python 3.9+", paths: paths("python3") + ["/Library/Developer/CommandLineTools/usr/bin/python3", "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"], python: true),
                claude: probe("Claude Code", paths: paths("claude")),
                codex: probe("Codex CLI", paths: paths("codex")))
        }.value
    }
    private static func probe(_ name: String, paths: [String], python: Bool = false) -> Dependency {
        var found = false
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            found = true
            guard let output = versionOutput(path), let version = Dependency.version(in: output),
                  !python || Dependency.supportsPython(version) else { continue }
            return Dependency(name: name, path: path, version: version, state: .ready)
        }
        return Dependency(name: name, state: found ? .incompatible : .missing)
    }
    private static func versionOutput(_ executable: String) -> String? {
        // A bounded probe off the main actor. A file avoids a full stdout pipe blocking exit.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forUpdating: file) else { return nil }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:\(home)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = handle; process.standardError = handle
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.1); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; return nil }
        guard process.terminationStatus == 0 else { return nil }
        try? handle.seek(toOffset: 0)
        return (try? handle.read(upToCount: 1024)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
