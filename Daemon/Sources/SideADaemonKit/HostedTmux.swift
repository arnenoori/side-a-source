import Foundation
import SideACore
import SideAProtocol

/// Side A's own tmux server (`tmux -L sidea`) and what the daemon does in it: start an agent in a pane, list the panes it
/// owns, type a reply, press keys, stop one. The Mac does the same from `HostedSessions` with a zsh launcher; Linux has no
/// zsh to count on, so the daemon starts the session itself, with the same options (`@sidea_*`) on it so `bridge/hosting.py`
/// and the Mac's list read it alike. What to type and when is `Hosting` in SideACore, shared with the Mac.
public actor HostedTmux {
    public struct Pane: Sendable, Equatable {
        public let name: String
        public let dead: Bool
        public let exitStatus: Int?
        public let agent: String
        public let cwd: String
        public let created: Double
        public let session: String
        public let attached: Int
        public let pid: Int
        public let worktree: String
        public let branch: String
    }

    public struct Start: Sendable {
        public var agent: Hosting.Agent
        public var cwd: String
        public var mode: Hosting.Mode
        public var arguments: [String] = []
        public var prompt: String?
        public var key: String?
        public var pin: String?
        public var origin = "phone"
        /// Variables the agent starts with, such as the folder of the account it runs as.
        public var environment: [String: String] = [:]
        public var account: String?
        public init(agent: Hosting.Agent, cwd: String, mode: Hosting.Mode) { self.agent = agent; self.cwd = cwd; self.mode = mode }
    }

    public enum Failure: Error, Equatable, Sendable {
        case unavailable
        case refused(String)
        case failed(String)
        case waiting
    }

    public static let minimum = (3, 4)

    private let root: URL
    private let environment: [String: String]
    private let agents: [Hosting.Agent: String]
    private var tmux: String?
    private var counter = 0
    private let socket: String?
    private let shell: String

    /// `root` holds `runtime/` (the bridge's `hosting install` writes `tmux.conf` and `tmux-path` there). `agents` maps an
    /// agent to the command that starts it; the default is its own name, looked up on the login shell's `PATH`.
    public init(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment, agents: [Hosting.Agent: String] = [:]) {
        self.root = root
        self.environment = environment
        self.agents = agents
        socket = environment["SIDE_A_TMUX_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        shell = [environment["SHELL"], "/bin/bash", "/bin/sh"].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/sh"
    }

    var runtime: URL { root.appendingPathComponent("runtime") }
    public var available: Bool { tmux != nil }

    /// Reads the tmux the bridge settled on (`hosting install`), or looks for one.
    public func prepare() async -> Bool {
        let recorded = (try? String(contentsOf: runtime.appendingPathComponent("tmux-path"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let recorded, FileManager.default.isExecutableFile(atPath: recorded) { tmux = recorded } else { tmux = nil }
        return tmux != nil
    }

    private func base() -> [String] {
        ["-u"] + (socket.map { ["-S", $0] } ?? ["-L", "sidea"]) + ["-f", runtime.appendingPathComponent("tmux.conf").path]
    }

    private func env() -> [String: String] {
        var copy = environment
        for name in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] { copy[name] = nil }
        return copy
    }

    @discardableResult
    func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 10) async -> ProcessResult {
        guard let tmux else { return ProcessResult(status: 127, output: "", errors: "tmux is missing", timedOut: false) }
        return await Run.process(tmux, base() + arguments, environment: env(), input: input, timeout: timeout)
    }

    static func target(_ name: String) -> String { "=\(name):" }

    // MARK: Listing

    static let fields = ["session_name", "pane_dead", "pane_dead_status", "@sidea_agent", "@sidea_cwd", "@sidea_created", "@sidea_session",
                         "session_attached", "pane_pid", "@sidea_worktree", "@sidea_branch", "@sidea_v"]

    public func list() async -> [Pane] {
        guard tmux != nil else { return [] }
        let format = Self.fields.map { "#{\($0)}" }.joined(separator: "\t")
        let result = await run(["list-panes", "-a", "-F", format], timeout: 5)
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == Self.fields.count, parts[0].hasPrefix("sa-"), !parts[3].isEmpty else { return nil }
            return Pane(name: parts[0], dead: parts[1] == "1", exitStatus: Int(parts[2]), agent: parts[3], cwd: parts[4], created: Double(parts[5]) ?? 0,
                        session: parts[6], attached: Int(parts[7]) ?? 0, pid: Int(parts[8]) ?? 0, worktree: parts[9], branch: parts[10])
        }
    }

    public func screen(_ name: String, colors: Bool = false) async -> String {
        await run(["capture-pane", "-p"] + (colors ? ["-e"] : []) + ["-J", "-t", Self.target(name), "-S", "-200"], timeout: 5).output
    }

    // MARK: Starting

    /// `sa-<project>-<4 hex>`, the project being the repository's name (a worktree's main one) or the folder's.
    static func project(_ cwd: String) async -> String {
        var name = (cwd as NSString).lastPathComponent
        let git = await Run.process("/usr/bin/env", ["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"], timeout: 5)
        if git.status == 0 {
            let common = git.output.trimmingCharacters(in: .whitespacesAndNewlines)
            name = ((common.hasSuffix("/.git") ? String(common.dropLast(5)) : common) as NSString).lastPathComponent
        }
        let slug = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        let squeezed = slug.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let trimmed = String(squeezed.prefix(24)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "session" : trimmed
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Starts the agent in a new detached session and returns its name. A start with the same `key`, or one resuming a
    /// conversation that already has a live pane, returns that pane's name instead of a second one.
    public func start(_ request: Start) async throws -> String {
        guard tmux != nil else { throw Failure.unavailable }
        guard FileManager.default.fileExists(atPath: request.cwd) else { throw Failure.refused("That folder no longer exists.") }
        let existing = await list()
        if let key = request.key, let found = existing.first(where: { !$0.dead && keyOf($0.name) == key }) { return found.name }
        if let id = request.mode.resumes, let found = existing.first(where: { !$0.dead && $0.session == id }) { return found.name }
        let project = await Self.project(request.cwd)
        var name = ""
        for _ in 0..<20 {
            let candidate = "sa-\(project)-" + String(format: "%04x", UInt16.random(in: .min ... .max))
            if !existing.contains(where: { $0.name == candidate }) { name = candidate; break }
        }
        guard !name.isEmpty else { throw Failure.failed("No free session name.") }
        let folder = runtime.appendingPathComponent("hosted/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let key = request.key { try Data(key.utf8).write(to: folder.appendingPathComponent("key"), options: .atomic) }
        let command = agents[request.agent] ?? request.agent.rawValue
        var line = "exec \(command) " + request.arguments.map(Self.quote).joined(separator: " ")
        var script = "#!/bin/sh\ncd -- \(Self.quote(request.cwd)) || exit 66\n"
        if let prompt = request.prompt, !prompt.isEmpty {
            let file = folder.appendingPathComponent("prompt.txt")
            try Data(Hosting.promptArgument(prompt).utf8).write(to: file, options: .atomic)
            script += "_side_a_prompt=$(cat \(Self.quote(file.path))); rm -f -- \(Self.quote(file.path))\n"
            // Both CLIs end their options at --, so the prompt is never read as a flag.
            line += " -- \"$_side_a_prompt\""
        }
        script += line + "\n"
        let launch = folder.appendingPathComponent("launch.sh")
        try Data(script.utf8).write(to: launch, options: .atomic)
        chmod(launch.path, 0o700)
        let target = Self.target(name)
        func option(_ key: String, _ value: String) -> [String] { [";", "set", "-t", target, key, value] }
        var arguments = ["new-session", "-d", "-s", name, "-c", request.cwd, "-x", "120", "-y", "40", "-e", "SIDE_A_HOSTED=\(name)"]
        if let pin = request.pin { arguments += ["-e", "SIDE_A_PIN=\(pin)"] }
        for (name, value) in request.environment.sorted(by: { $0.key < $1.key }) { arguments += ["-e", "\(name)=\(value)"] }
        arguments += ["--", shell, "-lic", ". \"$1\"", "sh", launch.path]
        arguments += option("@sidea_v", "1") + option("@sidea_agent", request.agent.rawValue) + option("@sidea_cwd", request.cwd)
        arguments += option("@sidea_origin", request.origin) + option("@sidea_session", request.mode.resumes ?? "") + option("@sidea_account", request.account ?? request.pin ?? "")
        arguments += option("@sidea_key", request.key ?? "") + option("@sidea_repo", "") + option("@sidea_worktree", "") + option("@sidea_branch", "")
        arguments += option("@sidea_created", String(Int(Date().timeIntervalSince1970)))
        arguments += [";", "set", "-F", "-t", target, "@sidea_pane", "#{pane_id}"]
        let result = await run(arguments, timeout: 20)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw Failure.failed(result.errors.isEmpty ? "tmux couldn't start the session (\(result.status))." : result.errors.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return name
    }

    private func keyOf(_ name: String) -> String? {
        (try? String(contentsOf: runtime.appendingPathComponent("hosted/\(name)/key"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Typing

    /// docs/remote/hosting.md, Reply text: a dialog on screen refuses (Enter would confirm the highlighted option); one
    /// character is sent as a key; longer text is pasted with brackets when the pane asked for them, then Enter 60 ms later.
    public func type(_ name: String, agent: Hosting.Agent, text raw: String) async throws {
        guard tmux != nil else { throw Failure.unavailable }
        let text = Hosting.clean(raw)
        guard !text.isEmpty else { throw Failure.refused("There's nothing to send.") }
        if Hosting.dialog(agent, screen: await screen(name, colors: true)) { throw Failure.waiting }
        if text.count == 1 {
            guard await run(["send-keys", "-t", Self.target(name), "-l", text == ";" ? "\\;" : text]).status == 0 else { throw Failure.failed("It couldn't be typed.") }
        } else {
            counter += 1
            let buffer = "sidea-in-\(getpid())-\(counter)"
            let pasted = await run(["load-buffer", "-b", buffer, "-", ";", "paste-buffer", "-p", "-d", "-b", buffer, "-t", Self.target(name)], input: Data(text.utf8))
            guard pasted.status == 0 else {
                await run(["delete-buffer", "-b", buffer])
                throw Failure.failed("It couldn't be pasted.")
            }
        }
        // Ink treats an Enter that arrives with the text as a newline, and Codex folds it into a paste burst.
        try? await Task.sleep(for: .milliseconds(60))
        guard await run(["send-keys", "-t", Self.target(name), "Enter"]).status == 0 else { throw Failure.failed("It's typed in but wasn't sent.") }
    }

    public func press(_ name: String, keys: [String]) async throws {
        for key in keys {
            guard let arguments = Hosting.keyArguments(key) else { throw Failure.refused("That key can't be sent.") }
            guard await run(["send-keys", "-t", Self.target(name)] + arguments).status == 0 else { throw Failure.failed("A key couldn't be sent.") }
        }
    }

    public func interrupt(_ name: String) async throws {
        guard await run(["send-keys", "-t", Self.target(name), "Escape"]).status == 0 else { throw Failure.failed("Esc couldn't be sent.") }
    }

    public func end(_ name: String) async -> Bool {
        let removed = await run(["kill-session", "-t", Self.target(name)]).status == 0
        try? FileManager.default.removeItem(at: runtime.appendingPathComponent("hosted/\(name)"))
        return removed
    }

    /// Stops the server this daemon started, for tests that own their socket.
    public func shutdown() async { await run(["kill-server"]) }
}
