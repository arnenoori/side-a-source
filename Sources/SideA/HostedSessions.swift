import Foundation
import os
import SideACore
import SideAProtocol

enum HostedError: LocalizedError {
    /// No tmux 3.4 or later; callers fall back to an unhosted launch.
    case unavailable
    /// The conversation runs already; two processes on one transcript corrupt it.
    case alreadyLive(LiveSession)
    /// A selection is on screen, so Enter would pick an option.
    case sessionWaiting
    /// The composer holds someone's draft, so Enter would send it.
    case composerBusy
    case notHosted
    case refused(String)
    case failed(String)
    /// Continue on phone ended the Mac process, but the agent didn't come back up under this session within 20 s.
    case notResumed(name: String, command: String)

    /// protocol.md's error code for the phone.
    var code: String {
        switch self {
        case .unavailable: "tmux_missing"
        case .alreadyLive: "already_live"
        case .sessionWaiting: "session_waiting"
        case .composerBusy: "composer_busy"
        case .notHosted: "not_hosted"
        case .refused: "cannot_deliver"
        case .failed: "internal"
        case .notResumed: "not_resumed"
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable: "Hosted sessions need tmux 3.4 or later (brew install tmux)."
        case .alreadyLive: "That session is already running."
        case .sessionWaiting: "A question is open in that session; answer it first."
        case .composerBusy: "Something is already typed in that session's prompt."
        case .notHosted: "That session isn't hosted by Side A."
        case .refused(let message), .failed(let message): message
        case .notResumed(_, let command): "It ended on the Mac but didn't start again here. Try again, or run \(command) on the Mac."
        }
    }
}

/// Side A's own tmux server (`tmux -L sidea`): starts sessions through runtime/sidea-tmux, types
/// into them, and cleans up after them. tmux holds the metadata, so a restart adopts what runs.
/// See docs/remote/hosting.md.
@MainActor @Observable
final class HostedSessions {
    struct Session: Identifiable, Hashable, Sendable {
        let name: String
        /// nil for a session someone made by hand on the socket; it is listed but never typed into.
        let agent: Hosting.Agent?
        let cwd: String
        let worktree: String
        let sessionID: String
        let origin: String
        let created: Double
        /// The agent's own pane, `%N`: tmux never reuses one while its server runs, so typing aimed at it can't land in
        /// a pane someone split, swapped or selected since.
        var pane: String = ""
        var id: String { name }
    }

    struct Client: Sendable {
        let pid: pid_t
        let tty: String
        let activity: Double
        /// A phone viewer (`attach -f ignore-size`); never a Mac tab.
        let phone: Bool
    }

    struct Start: Sendable {
        var agent: Hosting.Agent
        var cwd: String
        var mode: Hosting.Mode
        var origin = "mac"
        /// The `sidea use` pin for Claude; follows Side A when nil.
        var pin: String?
        var codexAccount: String?
        /// Checked against the model by the caller; Codex accepts any string and sends it on.
        var effort: String?
        /// The protocol's PermissionMode; one `Hosting.permissionArguments` has no flags for is refused.
        var permissionMode: String?
        var prompt: String?
        var images: [String] = []
        /// A start retried with the same key returns the first session, even after an app restart.
        var key: String?
        /// A new worktree at <repo>/.sidea-worktrees/<name> on sidea/<name>, from this base
        /// ("HEAD" for the folder's current commit). Gitignored .env files are copied into it.
        var worktree: String?
    }

    /// Something on a session's screen the user should decide about.
    struct Attention: Sendable, Equatable {
        /// "unsent": a reply may not have gone in.
        let kind: String
        let text: String
    }

    /// protocol's ReplySubmit. Claude queues a message submitted mid-turn either way.
    enum Submit: Sendable {
        /// Codex while working: Tab, which queues it for the next turn (Codex 0.163). Otherwise Enter.
        case queue
        /// Codex while working: Enter, which adds it to the running turn.
        case steer
    }

    let root: URL
    /// Overrides for every tmux and launcher run, for tests: SIDE_A_TMUX_SOCKET (a socket path in
    /// place of `-L sidea`) and HOME.
    private let environment: [String: String]
    private let bridge: @MainActor ([String]) async throws -> Data
    private let changed: @MainActor () async -> Void
    /// A fresh `sessions.py live`: every live process, idle ones included.
    private let live: @MainActor () async -> [LiveSession]?
    /// Raised for the phone (hosted.attention).
    @ObservationIgnored var onAttention: (@MainActor (String, Attention) -> Void)?
    /// After every reading of the server, for the phone's terminals (window size, copy mode).
    @ObservationIgnored var onRefresh: (@MainActor () -> Void)?
    /// A session's agent exited, before the session goes: its exit status (nil when a signal ended it), and killed
    /// when `end` asked for it.
    @ObservationIgnored var onEnded: (@MainActor (String, Int?, TermExitReason) -> Void)?
    @ObservationIgnored private var ending: Set<String> = []
    private(set) var tmux: String?
    private(set) var sessions: [Session] = []
    /// The Mac tab most recently typed in, per session; phones are left out.
    private(set) var macClients: [String: Client] = [:]
    var available: Bool { tmux != nil }
    @ObservationIgnored private var verifiers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var interrupted: [String: Date] = [:]
    @ObservationIgnored private var finishing: Set<String> = []
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var serverPID: pid_t = 0
    @ObservationIgnored private var buffers = 0
    @ObservationIgnored private var refreshes = 0
    @ObservationIgnored private var applied = 0
    @ObservationIgnored private var conversations: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Conversations Continue on phone is moving; one at a time each.
    @ObservationIgnored private var continuing: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: "com.arnenoori.sidea", category: "hosted")

    /// Each `install` and `stop` counts here; an install that wakes to a newer count stands down.
    @ObservationIgnored private var installs = 0

    init(root: URL, environment: [String: String] = [:], bridge: @escaping @MainActor ([String]) async throws -> Data,
         live: @escaping @MainActor () async -> [LiveSession]? = { [] }, changed: @escaping @MainActor () async -> Void = {}) {
        self.root = root
        self.environment = environment
        self.bridge = bridge
        self.live = live
        self.changed = changed
    }

    var runtime: URL { root.appendingPathComponent("runtime") }
    var launcher: URL { runtime.appendingPathComponent("sidea-tmux") }

    /// The command a terminal tab runs to join a session; a full path, so it works without the .zshrc line.
    func attachCommand(_ name: String) -> String { "\(Shell.quote(launcher.path)) attach \(name)" }

    /// What a phone's terminal view runs in its PTY: a client that never sizes the window by itself.
    func viewer(_ name: String) -> (path: String, args: [String], environment: [String: String])? {
        guard let tmux, sessions.contains(where: { $0.name == name && $0.agent != nil }) else { return nil }
        var environment = ProcessInfo.processInfo.environment
        for key in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] { environment.removeValue(forKey: key) }
        environment.merge(self.environment) { $1 }
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        let conf = runtime.appendingPathComponent("tmux.conf").path
        return (tmux, [tmux] + server + ["-f", conf, "attach-session", "-f", "ignore-size", "-t", "=\(name)"], environment)
    }

    /// Runs one tmux command on Side A's server, for the terminal's window size.
    func command(_ args: [String]) async -> (status: Int32, output: String) { await run(args) }

    /// Writes the config and launcher, finds tmux, reloads a running server and starts watching it.
    func install() async {
        struct Installed: Decodable { let tmux: String? }
        installs += 1
        let current = installs
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tmux").path
        let args = ["hosting", "install"] + (FileManager.default.isExecutableFile(atPath: bundled) ? ["--bundled", bundled] : [])
        let found: String?
        do {
            found = try JSONDecoder().decode(Installed.self, from: try await bridge(args)).tmux
        } catch {
            log.error("hosting install failed: \(error.localizedDescription, privacy: .public)")
            found = nil
        }
        guard current == installs else { return }
        tmux = found
        // The watcher ends by itself once tmux is gone; dropping it here lets the next install start one.
        if tmux == nil {
            watcher?.cancel()
            watcher = nil
        }
        pruneFolders()
        await refresh()
        guard current == installs else { return }
        if tmux != nil, watcher == nil { watch() }
    }

    /// Nothing watches or starts in tmux until `install` runs again.
    func stop() {
        installs += 1
        watcher?.cancel()
        watcher = nil
        tmux = nil
        sessions = []
    }

    // MARK: Starting

    /// Starts a hosted session and returns its name. A resume of a conversation that already runs
    /// throws `alreadyLive`; the check and the launch happen under one lock per conversation, so a
    /// second resume (or Continue on phone) waits and then finds the first. Forks only read the
    /// parent (Claude, and Codex: checked on 0.156.1), so they may start while it runs.
    func start(_ request: Start) async throws -> String {
        guard available else { throw HostedError.unavailable }
        guard FileManager.default.fileExists(atPath: request.cwd) else { throw HostedError.refused("That folder no longer exists.") }
        let permission: [String] = try request.permissionMode.map { mode in
            guard let args = Hosting.permissionArguments(request.agent, mode: mode) else {
                throw HostedError.refused("\(request.agent == .codex ? "Codex" : "Claude") can't start in that mode.")
            }
            return args
        } ?? []
        let conversation: String? = switch request.mode { case .resume(let id), .fork(let id): id; case .new: nil }
        if let conversation { await lock(conversation) }
        defer { if let conversation { unlock(conversation) } }
        // A Codex fork of a live thread waits until `codex fork` is known never to write the parent's rollout (hosting.md).
        let checked: String? = switch (request.agent, request.mode) {
        case (_, .resume(let id)), (.codex, .fork(let id)): id
        default: nil
        }
        if let id = checked {
            guard let fresh = await live() else { throw HostedError.failed("Side A couldn't check whether that session is still running.") }
            if let running = fresh.first(where: { $0.sessionID == id }) { throw HostedError.alreadyLive(running) }
        }
        var args = ["host", request.agent.rawValue, "--detach", "--cwd", request.cwd, "--origin", request.origin]
        if let base = request.worktree { args += ["--worktree", base] }
        if let id = request.mode.resumes { args += ["--session", id] }
        if let pin = request.pin { args += ["--pin", pin] }
        if let key = request.key { args += ["--key", key] }
        var agentArgs: [String] = []
        if request.agent == .codex, let account = request.codexAccount {
            // The same home and flags Side A runs that Codex account with everywhere else.
            struct Launch: Decodable { let args: [String]; let env: [String: String] }
            let launch = try JSONDecoder().decode(Launch.self, from: try await bridge(["hosting", "codex-env", account]))
            agentArgs += launch.args
            args += launch.env.sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
        }
        // Nobody may be at the terminal to skip Codex's update prompt, and Enter there runs brew.
        if request.agent == .codex { agentArgs += ["-c", "check_for_update_on_startup=false"] }
        if request.agent == .codex, let effort = request.effort { agentArgs += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        agentArgs += Hosting.arguments(request.agent, request.mode, images: request.agent == .codex ? request.images : [])
        if request.agent == .claude, let effort = request.effort { agentArgs += ["--effort", effort] }
        // After `resume <id>` and `fork <id>` too: both take -a and -s as their own (Codex 0.163).
        agentArgs += permission
        // Claude has no image flag; quoted paths in the prompt become attachments (checked on 2.1.302).
        let images = request.agent == .claude ? request.images.map { Shell.quote($0) }.joined(separator: " ") : ""
        let prompt = Hosting.clean([request.prompt ?? "", images].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        var later: String?
        if !prompt.isEmpty {
            if prompt.utf8.count <= Hosting.promptArgumentLimit {
                let file = runtime.appendingPathComponent("hosted/.prompt-\(UUID().uuidString)")
                try PrivateFile.writeText(Hosting.promptArgument(prompt), to: file)
                args += ["--prompt-file", file.path]
            } else {
                later = prompt
            }
        }
        let result = await Self.process(launcher.path, args + ["--"] + agentArgs, environment: environment, timeout: 45)
        guard result.status == 0, let name = result.output.split(separator: "\n").last.map(String.init), name.hasPrefix("sa-") else {
            throw HostedError.failed(result.errors.isEmpty ? "The session could not be started (\(result.status))." : result.errors)
        }
        await refresh()
        watchDialogs(name, agent: request.agent)
        if let later {
            Task { [weak self] in try? await self?.reply(name, text: later, waitForComposer: .seconds(60)) }
        }
        return name
    }

    private func lock(_ conversation: String) async {
        if conversations[conversation] == nil { conversations[conversation] = []; return }
        await withCheckedContinuation { conversations[conversation, default: []].append($0) }
    }

    private func unlock(_ conversation: String) {
        guard var waiting = conversations[conversation], !waiting.isEmpty else { conversations[conversation] = nil; return }
        let next = waiting.removeFirst()
        conversations[conversation] = waiting
        next.resume()
    }

    // MARK: Continue on phone

    /// Why a live session can't move into tmux now, or nil when it can (hosting.md, Continue on phone).
    nonisolated static func continueRefusal(_ session: LiveSession) -> String? {
        guard session.sessionID?.isEmpty == false else { return "That session has no conversation to continue." }
        guard session.hosted == nil else { return "That session already runs in Side A." }
        if let kind = session.kind, kind != "interactive" { return "That's an automated run, so it can't move to the phone." }
        switch (session.provider, session.status) {
        case (.claude, "idle"), (.claude, "waiting"), (.codex, "idle"): return nil
        // Ending it would kill a background shell's job, or a Codex turn still running.
        case (_, "busy"), (_, "shell"), (.codex, "waiting"): return "It's working. Continue it here once it's idle."
        default: return "Side A can't tell what that session is doing, so it was left running."
        }
    }

    /// Ends an unhosted session with SIGTERM (Claude Code saves on it) and resumes its conversation here, on the
    /// same account. Returns the hosted session's name once the agent shows up under its pane. `registry` is
    /// Claude Code's `~/.claude/sessions`; `codexAccount` names the account a Codex process's environment runs on.
    func continueHere(_ session: LiveSession, transcript: URL?, registry: URL, verify: Duration = .seconds(20),
                      codexAccount: @MainActor ([String: String]) -> String? = { _ in nil }) async throws -> String {
        guard available else { throw HostedError.unavailable }
        guard let id = session.sessionID, let cwd = session.cwd, Self.continueRefusal(session) == nil else {
            throw HostedError.refused(Self.continueRefusal(session) ?? "That session has no folder to continue in.")
        }
        guard FileManager.default.fileExists(atPath: cwd) else { throw HostedError.refused("That folder no longer exists.") }
        guard !continuing.contains(id) else { throw HostedError.refused("That session is already moving here.") }
        continuing.insert(id)
        defer { continuing.remove(id) }
        guard let fresh = await live() else { throw HostedError.failed("Side A couldn't check whether that session is still running.") }
        guard let now = fresh.first(where: { $0.pid == session.pid && $0.sessionID == id && $0.started == session.started }),
              ProcessCheck.maySignal(pid: now.pid, started: now.started) else {
            throw HostedError.refused("That session has already ended on the Mac.")
        }
        guard Self.continueRefusal(now) == nil else { throw HostedError.refused("It started working again, so it was left running.") }
        let agent: Hosting.Agent = now.provider == .codex ? .codex : .claude
        var request = Start(agent: agent, cwd: cwd, mode: .resume(id))
        request.origin = "continue"
        let environment = ProcessEnvironment.read(pid: pid_t(now.pid)) ?? [:]
        if agent == .claude { request.pin = environment["SIDE_A_PIN"].flatMap { $0.isEmpty ? nil : $0 } } else { request.codexAccount = codexAccount(environment) }

        kill(pid_t(now.pid), SIGTERM)
        guard await Self.exited(now, registry: registry.appendingPathComponent("\(now.pid).json")) else {
            throw HostedError.refused("It didn't quit, so it's still running on the Mac.")
        }
        if let transcript { await Self.settled(transcript) }
        let name = try await start(request)
        let command = agent == .codex ? "codex resume \(id)" : "claude --resume \(id)"
        let end = ContinuousClock.now + verify
        while ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
            guard sessions.contains(where: { $0.name == name }) else { throw HostedError.notResumed(name: name, command: command) }
            if await live()?.contains(where: { $0.hosted == name && $0.sessionID == id }) == true { return name }
        }
        throw HostedError.notResumed(name: name, command: command)
    }

    /// Up to 5 s for the process to go, its registry file with it.
    private static func exited(_ session: LiveSession, registry: URL) async -> Bool {
        for _ in 0..<100 {
            let gone = !ProcessCheck.maySignal(pid: session.pid, started: session.started)
            if gone, !FileManager.default.fileExists(atPath: registry.path) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Until the transcript's size holds for 300 ms, at most 3 s.
    private static func settled(_ transcript: URL) async {
        var last = -1, steady = 0
        for _ in 0..<30 where steady < 3 {
            let size = ((try? FileManager.default.attributesOfItem(atPath: transcript.path))?[.size] as? Int) ?? 0
            steady = size == last ? steady + 1 : 0
            last = size
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Gitignored .env files the launcher copied into a session's worktree, relative to it.
    func copiedFiles(_ name: String) -> [String] {
        ((try? String(contentsOf: runtime.appendingPathComponent("hosted/\(name)/copied.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    // MARK: Typing

    /// Pastes text into the composer and presses Enter, then watches whether Enter was taken.
    /// Refused while a selection is on screen (Enter would pick an option) or while the composer
    /// holds someone else's draft (Enter would send it).
    /// Images go first, each path pasted single-quoted with a space after it: both CLIs turn that into
    /// an attachment, and Codex needs the quotes for a path with spaces (checked on 0.156.1). A path
    /// that stays plain text still works; the agent reads the file.
    /// One at a time per pane, from looking at the composer to arming the verifier: two phones' replies would
    /// otherwise both find it empty and paste into each other.
    func reply(_ name: String, text raw: String, images: [String] = [], submit: Submit = .queue, working: Bool = false, waitForComposer: Duration = .seconds(5)) async throws {
        await lock(Self.composer(name))
        defer { unlock(Self.composer(name)) }
        try await type(name, text: raw, images: images, submit: submit, working: working, waitForComposer: waitForComposer)
    }

    /// A pane's composer lock shares the conversation locks' table; conversation ids never start with "composer ".
    private static func composer(_ name: String) -> String { "composer " + name }

    private func type(_ name: String, text raw: String, images: [String], submit: Submit, working: Bool, waitForComposer: Duration) async throws {
        guard let agent = sessions.first(where: { $0.name == name })?.agent else { throw HostedError.notHosted }
        let text = Hosting.clean(raw)
        guard !text.isEmpty || !images.isEmpty else { return }
        // The previous reply may still be in the composer, waiting for its verifier's second Enter: give it the time.
        func settled(_ screen: String) -> Bool {
            guard Hosting.ready(agent, screen: screen) || Hosting.dialog(agent, screen: screen) else { return false }
            if verifiers[name] != nil, case .text = Hosting.composer(agent, screen: screen) { return false }
            return true
        }
        var screen = await capture(name)
        let deadline = ContinuousClock.now + waitForComposer
        while !settled(screen) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            screen = await capture(name)
        }
        if Hosting.dialog(agent, screen: screen) { throw HostedError.sessionWaiting }
        switch Hosting.composer(agent, screen: screen) {
        case .none: throw HostedError.refused("That session isn't ready for a message yet.")
        case .text: throw HostedError.composerBusy
        case .empty: break
        }
        // Only now: refused, the previous reply keeps its verifier.
        cancelVerifier(name)
        let activity = await macActivity(name)
        for image in images {
            try await paste(Hosting.clean(Shell.quote(image)), into: name)
            try? await Task.sleep(for: .milliseconds(200))
            _ = await run(["send-keys", "-t", pane(name), "-l", " "])
        }
        if text.count == 1 {
            // A lone ';' would end the tmux command.
            _ = await run(["send-keys", "-t", pane(name), "-l", text == ";" ? "\\;" : text])
        } else if !text.isEmpty {
            try await paste(text, into: name)
        }
        // Enter goes separately: with the text, Claude reads it as a newline and Codex folds it into the paste.
        var expected: String?
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(60))
            expected = Hosting.owned(sent: text, composer: Hosting.composer(agent, screen: await capture(name)))
            if expected != nil { break }
        }
        guard let expected else {
            // Its own text isn't what the composer shows, so neither Enter nor Tab: either could submit someone else's
            // words or answer a dialog that just opened.
            onAttention?(name, Attention(kind: "unsent", text: "It's typed in but wasn't sent."))
            return
        }
        // Tab only queues during a turn; on an idle Codex composer Enter is what submits.
        let key = agent == .codex && working && submit == .queue ? "Tab" : "Enter"
        _ = await run(["send-keys", "-t", pane(name), key])
        arm(name, agent: agent, expected: expected, activity: activity, key: key)
    }

    private func paste(_ text: String, into name: String) async throws {
        buffers += 1
        let buffer = "sidea-in-\(getpid())-\(buffers)"
        // One invocation, the text on stdin: tmux's own argv parsing would drop a trailing ';'.
        let pasted = await run(["load-buffer", "-b", buffer, "-", ";", "paste-buffer", "-p", "-d", "-b", buffer, "-t", pane(name)], input: Data(text.utf8))
        guard pasted.status == 0 else {
            _ = await run(["delete-buffer", "-b", buffer])
            throw HostedError.failed("The text could not be typed into that session.")
        }
    }

    /// Allowlisted single keys, one `send-keys` each, for dialogs and mode cycling.
    func keys(_ name: String, _ keys: [String]) async throws {
        guard sessions.contains(where: { $0.name == name && $0.agent != nil }) else { throw HostedError.notHosted }
        let mapped = try keys.map { key in
            guard let args = Hosting.keyArguments(key) else { throw HostedError.refused("\(key) can't be sent.") }
            return args
        }
        await lock(Self.composer(name))
        defer { unlock(Self.composer(name)) }
        cancelVerifier(name)
        for args in mapped { _ = await run(["send-keys", "-t", pane(name)] + args) }
    }

    /// Esc, sent server-side so no client holds it. Only while the agent works: a second Esc on an
    /// idle Claude opens the rewind menu. At most one per 1.5 s.
    func interrupt(_ name: String, working: Bool) async throws {
        guard working else { throw HostedError.refused("That session isn't working.") }
        if let last = interrupted[name], Date().timeIntervalSince(last) < 1.5 { return }
        interrupted[name] = Date()
        cancelVerifier(name)
        _ = await run(["send-keys", "-t", pane(name), "Escape"])
    }

    // MARK: Settings

    /// What a hosted Claude runs with after `change`, as its screens confirmed it.
    struct Settings: Sendable, Equatable {
        var model: String?
        var effort: String?
        var mode: String?
    }

    /// Types one of Side A's own slash commands into an idle hosted Claude: Enter only once the slash list highlights
    /// that very command (Enter runs whatever it highlights), then the verifier watches it go, as for a reply.
    func command(_ name: String, _ command: String) async throws {
        guard Hosting.typedCommands.contains(command) else { throw HostedError.refused("\(command) can't be sent.") }
        guard let agent = sessions.first(where: { $0.name == name })?.agent else { throw HostedError.notHosted }
        guard agent == .claude else { throw HostedError.refused("Side A types \(command) only into Claude.") }
        await lock(Self.composer(name))
        defer { unlock(Self.composer(name)) }
        guard Hosting.composer(.claude, screen: try await composerScreen(name)) == .empty else { throw HostedError.composerBusy }
        cancelVerifier(name)
        let activity = await macActivity(name)
        _ = await run(["send-keys", "-t", pane(name), "-l", command])
        let typed = await waitFor(name) { screen in
            Hosting.composer(.claude, screen: screen) == .text(command) && Hosting.slashSuggestion(screen: screen) == command ? true : nil
        }
        guard typed != nil else {
            _ = await run(["send-keys", "-t", pane(name), "C-u"])
            throw HostedError.refused("Claude didn't offer \(command) here.")
        }
        _ = await run(["send-keys", "-t", pane(name), "Enter"])
        arm(name, agent: .claude, expected: command, activity: activity, key: "Enter")
    }

    // MARK: Before the composer

    /// While a new session has no composer, a look every second for up to two minutes: a folder-trust question
    /// raises hosted.attention "trust" (the phone's Trust and start), any other screen that sits unchanged for 20 s
    /// "screen". Each once.
    private func watchDialogs(_ name: String, agent: Hosting.Agent) {
        Task { [weak self] in
            var trust = false, stuck = false, last = "", since = Date()
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.sessions.contains(where: { $0.name == name }) else { return }
                let screen = await self.capture(name)
                if Hosting.ready(agent, screen: screen) { return }
                if Hosting.trust(agent, screen: screen) != nil {
                    if !trust { self.onAttention?(name, Attention(kind: "trust", text: Self.trustQuestion(screen))) }
                    trust = true
                    continue
                }
                if screen != last { last = screen; since = Date() }
                if !stuck, Date().timeIntervalSince(since) >= 20 {
                    stuck = true
                    let lines = Hosting.plainLines(screen).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    self.onAttention?(name, Attention(kind: "screen", text: lines.suffix(6).joined(separator: "\n")))
                }
            }
        }
    }

    private nonisolated static func trustQuestion(_ screen: String) -> String {
        Hosting.plainLines(screen).map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.contains("trust?") || $0.hasPrefix("Do you trust") }
            ?? "Do you trust the files in this folder?"
    }

    /// Trust and start (the phone, after Face ID): answers a hosted Claude's folder-trust question with "Yes, I trust
    /// this folder", only while that question is on screen and names the session's own folder. "No, exit" is the
    /// default, so the selection moves down, a reading after each key, and Enter goes only once Yes is highlighted.
    /// A question for another folder gets no key (Esc would answer No and end the session); another dialog gets Esc.
    func trust(_ name: String) async throws {
        guard let session = sessions.first(where: { $0.name == name }), let agent = session.agent else { throw HostedError.notHosted }
        // Codex's question doesn't name its folder on the versions checked, so it's trusted in the terminal.
        guard agent == .claude else { throw HostedError.refused("Trust this folder in the terminal.") }
        await lock(Self.composer(name))
        defer { unlock(Self.composer(name)) }
        let screen = await capture(name)
        guard var state = Hosting.trust(.claude, screen: screen) else {
            if Hosting.dialog(.claude, screen: screen) { _ = await run(["send-keys", "-t", pane(name), "Escape"]) }
            throw HostedError.refused("There's no trust question on that session's screen.")
        }
        guard let folder = Hosting.trustFolder(screen: screen), Self.sameFolder(folder, session.cwd) else {
            throw HostedError.refused("The trust question on screen isn't for this session's folder.")
        }
        for _ in 0..<3 where state != .trustSelected {
            let before = state
            _ = await run(["send-keys", "-t", pane(name), "Down"])
            guard let next = await waitFor(name, { Hosting.trust(.claude, screen: $0).flatMap { $0 == before ? nil : $0 } }) else { break }
            state = next
        }
        guard state == .trustSelected else { throw HostedError.refused("Side A couldn't select \"Yes, I trust this folder\".") }
        // A fresh look just before Enter: still the question, still Yes.
        guard Hosting.trust(.claude, screen: await capture(name)) == .trustSelected else {
            throw HostedError.refused("The trust question changed before Side A could answer it.")
        }
        _ = await run(["send-keys", "-t", pane(name), "Enter"])
        _ = await waitFor(name, seconds: 5) { Hosting.trust(.claude, screen: $0) == nil ? true : nil }
    }

    /// One folder spelled two ways: /tmp and /private/tmp, a trailing slash, a symlink.
    nonisolated static func sameFolder(_ a: String, _ b: String) -> Bool {
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        return a == b || real(a) == real(b)
    }

    /// After `/compact`, which takes Claude a while: hosted.attention when `compacted` hasn't turned true within
    /// `seconds`, or nothing once the session is gone.
    func expectCompaction(_ name: String, within seconds: Double = 120, every poll: Duration = .seconds(2),
                          _ compacted: @escaping @MainActor () -> Bool) {
        Task { [weak self] in
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                try? await Task.sleep(for: poll)
                guard let self, self.sessions.contains(where: { $0.name == name }) else { return }
                if compacted() { return }
            }
            self?.onAttention?(name, Attention(kind: "screen", text: "It may not have compacted. Look at the session."))
        }
    }

    /// Changes a hosted Claude's model, effort and mode for this session only. Model and effort go through `/model`'s
    /// picker and `/effort`'s slider and are applied with `s` ("use this session only"): the typed forms (`/model X`,
    /// `/effort X`) save the pick as the user's default for every session (Claude Code 2.1.303). The mode is Shift+Tab
    /// until the footer shows it. Every key follows a reading of the screen and nothing is typed to search; a screen
    /// Side A doesn't expect is cancelled with Esc and left for the Mac. Idle sessions only, under the composer lock
    /// replies take, so nothing is typed into it meanwhile.
    func change(_ name: String, model: String?, effort: String?, mode: String?) async throws -> Settings {
        guard let agent = sessions.first(where: { $0.name == name })?.agent else { throw HostedError.notHosted }
        guard agent == .claude else { throw HostedError.refused("Side A changes settings this way only in Claude.") }
        let match = try model.map { model in
            guard let match = Hosting.pickerMatch(model) else { throw HostedError.refused("Claude's model list can't pick \(model) for one session.") }
            return match
        }
        if let effort, !Hosting.claudeEfforts.contains(effort) { throw HostedError.refused("Claude has no \(effort) effort.") }
        await lock(Self.composer(name))
        defer { unlock(Self.composer(name)) }
        cancelVerifier(name)
        var done = Settings()
        if let match {
            (done.model, done.effort) = (model, try await pickModel(name, match: match, effort: effort))
        } else if let effort {
            done.effort = try await pickEffort(name, effort)
        }
        if let mode { done.mode = try await cycleMode(name, to: mode) }
        return done
    }

    /// The model, and the effort with it when asked, from `/model`'s list; returns the effort it shows after.
    private func pickModel(_ name: String, match: (String) -> Bool, effort: String?) async throws -> String? {
        var shown = try await open(name, "/model") { Hosting.modelPicker(screen: $0) }
        func down() async throws {
            let before = shown.row
            shown = try await step(name, "Down") { Hosting.modelPicker(screen: $0).flatMap { $0.row == before ? nil : $0 } }
        }
        // Once round the list, which wraps: an alias stands for its family's first row, the newest.
        var rows = [shown.row: shown.label]
        while rows.count < 50 {
            try await down()
            guard rows[shown.row] == nil else { break }
            rows[shown.row] = shown.label
        }
        guard let wanted = rows.keys.sorted().first(where: { match(rows[$0]!) }) else {
            throw await cancel(name, "Claude's model list doesn't have that model.")
        }
        while shown.row != wanted { try await down() }
        if let effort {
            let target = Hosting.claudeEfforts.firstIndex(of: effort)!
            var tried: Set<String> = []
            while shown.effort != effort {
                guard let now = shown.effort, let at = Hosting.claudeEfforts.firstIndex(of: now) else {
                    throw await cancel(name, "\(shown.label) takes no effort setting.")
                }
                // A model without the level steps over it; back where it was means it can't have it.
                guard tried.insert(now).inserted else { throw await cancel(name, "\(shown.label) doesn't take \(effort) effort.") }
                let label = shown.label
                shown = try await step(name, at < target ? "Right" : "Left", or: "\(shown.label) doesn't take \(effort) effort.") {
                    Hosting.modelPicker(screen: $0).flatMap { $0.label == label && $0.effort != now ? $0 : nil }
                }
            }
        }
        try await apply(name, done: "Set model to \(shown.label)", confirming: shown.label)
        return shown.effort
    }

    private func pickEffort(_ name: String, _ effort: String) async throws -> String {
        var now = try await open(name, "/effort") { Hosting.effortSlider(screen: $0) }
        let target = Hosting.claudeEfforts.firstIndex(of: effort)!
        var tried: Set<String> = []
        while now != effort {
            guard tried.insert(now).inserted, let at = Hosting.claudeEfforts.firstIndex(of: now) else {
                throw await cancel(name, "This model doesn't take \(effort) effort.")
            }
            let from = now
            now = try await step(name, at < target ? "Right" : "Left", or: "This model doesn't take \(effort) effort.") {
                Hosting.effortSlider(screen: $0).flatMap { $0 == from ? nil : $0 }
            }
        }
        try await apply(name, done: "Set effort level to \(effort)", confirming: effort)
        return effort
    }

    /// Shift+Tab until the footer names the mode. A mode outside the session's cycle (bypass in a session not started
    /// with it) brings it round to where it was.
    private func cycleMode(_ name: String, to mode: String) async throws -> String {
        let screen = try await composerScreen(name)
        guard var now = Hosting.claudeMode(screen: screen) else { throw HostedError.refused("Side A can't read this session's mode.") }
        let start = now
        while now != mode {
            let from = now
            _ = await run(["send-keys", "-t", pane(name), "BTab"])
            let next = await waitFor(name) { screen in
                Hosting.dialog(.claude, screen: screen) ? "" : Hosting.claudeMode(screen: screen).flatMap { $0 == from ? nil : $0 }
            }
            guard let next, !next.isEmpty else {
                throw await cancel(name, next == nil ? "Shift+Tab didn't change this session's mode." : "Claude asked something on the way to that mode.")
            }
            if next == start { throw HostedError.refused("This session's Shift+Tab doesn't reach that mode.") }
            now = next
        }
        return now
    }

    /// The screen while the session can take a command: no question open, the composer up.
    private func composerScreen(_ name: String) async throws -> String {
        let screen = await capture(name)
        if Hosting.dialog(.claude, screen: screen) { throw HostedError.sessionWaiting }
        guard Hosting.ready(.claude, screen: screen) else { throw HostedError.refused("That session isn't ready yet.") }
        return screen
    }

    /// Types a slash command into the empty composer and presses Enter once the list highlights that very command,
    /// then waits for the screen it opens.
    private func open<Shown>(_ name: String, _ command: String, _ read: @escaping (String) -> Shown?) async throws -> Shown {
        guard Hosting.composer(.claude, screen: try await composerScreen(name)) == .empty else { throw HostedError.composerBusy }
        _ = await run(["send-keys", "-t", pane(name), "-l", command])
        let typed = await waitFor(name) { screen in
            Hosting.composer(.claude, screen: screen) == .text(command) && Hosting.slashSuggestion(screen: screen) == command ? true : nil
        }
        guard typed != nil else {
            _ = await run(["send-keys", "-t", pane(name), "C-u"])
            throw HostedError.refused("Claude didn't offer \(command) here.")
        }
        _ = await run(["send-keys", "-t", pane(name), "Enter"])
        guard let shown = await waitFor(name, seconds: 5, read) else { throw await cancel(name, "Claude's \(command) didn't open as expected.") }
        return shown
    }

    /// One key, then the screen `read` accepts; cancelled with `failure` when it doesn't come.
    private func step<Shown>(_ name: String, _ key: String, or failure: String = "Claude's screen changed unexpectedly.",
                             _ read: @escaping (String) -> Shown?) async throws -> Shown {
        _ = await run(["send-keys", "-t", pane(name), key])
        guard let shown = await waitFor(name, read) else { throw await cancel(name, failure) }
        return shown
    }

    /// `s`, then the warm-cache confirm when it comes for exactly this target, then the composer and Claude's
    /// "… this session only" line. A hook's confirm, or any other screen, is cancelled.
    private func apply(_ name: String, done: String, confirming target: String) async throws {
        // The same words may be in the conversation already: only a new line counts.
        let before = await said(name, done).count
        _ = await run(["send-keys", "-t", pane(name), "-l", "s"])
        enum Next { case confirm(Hosting.SwitchConfirm), back }
        let next = await waitFor(name) { screen -> Next? in
            if let confirm = Hosting.switchConfirm(screen: screen) { return .confirm(confirm) }
            return Hosting.ready(.claude, screen: screen) ? .back : nil
        }
        switch next {
        case .confirm(.yesSelected(let to))? where to.lowercased() == target.lowercased():
            _ = await run(["send-keys", "-t", pane(name), "Enter"])
        case .back?: break
        case .confirm?: throw await cancel(name, "Claude asks to confirm this switch. Confirm it on the Mac.")
        case nil: throw await cancel(name, "Claude's screen changed unexpectedly.")
        }
        var line: String?
        for _ in 0..<25 where line == nil {
            let lines = await said(name, done)
            if lines.count > before { line = lines.last } else { try? await Task.sleep(for: .milliseconds(80)) }
        }
        guard let line else { throw HostedError.failed("Side A couldn't tell whether Claude took the change.") }
        if !line.contains("this session only") {
            log.error("a session-only pick in \(name, privacy: .public) didn't say so: \(line, privacy: .public)")
            throw HostedError.failed("Claude didn't confirm the change was for this session only.")
        }
        // The confirm can outlast the line by a moment; the next change starts from the composer.
        _ = await waitFor(name, seconds: 3) { Hosting.ready(.claude, screen: $0) ? true : nil }
    }

    /// The lines holding `words` in the pane and the 300 lines above it.
    private func said(_ name: String, _ words: String) async -> [String] {
        Hosting.plainLines(await run(["capture-pane", "-p", "-J", "-t", pane(name), "-S", "-300"]).output).filter { $0.contains(words) }
    }

    /// Esc closes a picker, slider or confirm without picking, once per layer ("No, go back" returns to the picker);
    /// returns the error to throw.
    private func cancel(_ name: String, _ message: String) async -> HostedError {
        func open(_ screen: String) -> Bool {
            Hosting.modelPicker(screen: screen) != nil || Hosting.effortSlider(screen: screen) != nil
                || Hosting.switchConfirm(screen: screen) != nil || Hosting.dialog(.claude, screen: screen)
        }
        for _ in 0..<3 {
            let screen = await capture(name)
            guard open(screen) else { break }
            _ = await run(["send-keys", "-t", pane(name), "Escape"])
            _ = await waitFor(name, seconds: 1) { $0 != screen ? true : nil }
        }
        return .refused(message)
    }

    /// The first non-nil reading of the screen within `seconds`.
    private func waitFor<Shown>(_ name: String, seconds: Double = 2, _ read: (String) -> Shown?) async -> Shown? {
        let end = ContinuousClock.now + .seconds(seconds)
        while true {
            if let shown = read(await capture(name)) { return shown }
            if ContinuousClock.now >= end { return nil }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    /// The phone's End: the agent gets the hangup a closed terminal sends, and its pane then goes the way of any
    /// session that ends (last screen kept, Side A's clean worktree removed). Claude and Codex exit on it. The
    /// pane's shell exits whatever the agent does, so one that outlived it would run on unseen: its process
    /// group is noted first, then sent SIGTERM after 3 s and SIGKILL after 2 more.
    func end(_ name: String) async throws {
        guard sessions.contains(where: { $0.name == name }) else { throw HostedError.notHosted }
        cancelVerifier(name)
        let listed = await run(["display-message", "-p", "-t", pane(name), "#{pane_pid}"])
        guard let pid = listed.output.split(separator: "\n").first.flatMap({ pid_t($0) }), pid > 1 else {
            throw HostedError.failed("Side A couldn't find that session's process.")
        }
        ending.insert(name)
        let groups = Set(Self.children(of: pid).map { getpgid($0) }).subtracting([-1, 0, 1, getpgrp()])
        kill(pid, SIGHUP)
        for (signal, wait) in [(SIGTERM, 3.0), (SIGKILL, 2.0)] {
            guard await Self.running(groups, within: wait) else { break }
            for group in groups { killpg(group, signal) }
        }
        await refresh()
    }

    private nonisolated static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(0, Int(count))))
    }

    /// Whether any of these process groups still has a process `seconds` from now; false as soon as none has.
    private static func running(_ groups: Set<pid_t>, within seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while true {
            let left = groups.contains { killpg($0, 0) == 0 }
            if !left || Date() >= end { return left }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Someone typed into the session another way (the phone's terminal); a pending re-press must not fire.
    func cancelVerifier(_ name: String) {
        verifiers.removeValue(forKey: name)?.cancel()
    }

    /// Port of Codeman's submit verifier, stricter: presses again only while the composer shows
    /// exactly what was recorded after Side A's paste. It stops for good when the prompt is gone,
    /// when anyone else could have typed (a Mac tab, the phone's terminal, another send), and on
    /// anything ambiguous, which it raises as "unsent" for the user to decide.
    private func arm(_ name: String, agent: Hosting.Agent, expected: String, activity: Double, key: String) {
        verifiers[name] = Task { [weak self] in
            var elapsed = 0.0
            for at in Hosting.verifySchedule {
                try? await Task.sleep(for: .seconds(at - elapsed))
                elapsed = at
                guard !Task.isCancelled, let self else { return }
                if await self.macActivity(name) > activity { return }
                let verdict = Hosting.verdict(agent, expected: expected, screen: await self.capture(name))
                guard !Task.isCancelled else { return }
                switch verdict {
                case .pressEnter:
                    _ = await self.run(["send-keys", "-t", pane(name), key])
                    self.log.info("pressed \(key, privacy: .public) again in \(name, privacy: .public) after \(Int(at)) s")
                case .taken, .stop:
                    return
                case .unsent:
                    self.onAttention?(name, Attention(kind: "unsent", text: "It may not have been sent."))
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.onAttention?(name, Attention(kind: "unsent", text: "It may not have been sent."))
        }
    }

    /// Where typing for a session goes: its agent's pane, never whichever pane is active in it now.
    private func pane(_ name: String) -> String {
        sessions.first { $0.name == name }.map(\.pane).flatMap { $0.isEmpty ? nil : $0 } ?? "=\(name):"
    }

    func capture(_ name: String) async -> String {
        await run(["capture-pane", "-p", "-e", "-J", "-t", pane(name)]).output
    }

    // MARK: Clients

    /// Mac tabs and phone viewers attached to a session, most recently active first.
    func clients(_ name: String) async -> [Client] {
        await allClients(["-t", "=\(name)"]).map(\.1)
    }

    private func allClients(_ target: [String] = []) async -> [(String, Client)] {
        let listed = await run(["list-clients"] + target + ["-F", "#{session_name}\t#{client_pid}\t#{client_tty}\t#{client_activity}\t#{client_flags}"])
        return listed.output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 5, let pid = pid_t(parts[1]) else { return nil }
            return (String(parts[0]), Client(pid: pid, tty: String(parts[2]), activity: Double(parts[3]) ?? 0, phone: parts[4].contains("ignore-size")))
        }.sorted { $0.1.activity > $1.1.activity }
    }

    private func macActivity(_ name: String) async -> Double {
        await clients(name).filter { !$0.phone }.map(\.activity).max() ?? 0
    }

    // MARK: Watching

    private func watch() {
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let tmux = await self?.tmux else { return }
                // Hooks signal sidea-changed; a signal sent between two waits is kept, so nothing is
                // missed. The 5 s timeout doubles as the poll.
                guard let server = self?.server else { return }
                let waited = await Self.process(tmux, server + ["wait-for", "sidea-changed"], environment: self?.environment ?? [:], timeout: 5)
                await self?.refresh()
                if waited.status != 0 && waited.elapsed < 1 { try? await Task.sleep(for: .seconds(5)) }
            }
        }
    }

    /// Reads every session and handles panes that died: their agent exited.
    func refresh() async {
        guard tmux != nil else { sessions = []; return }
        let format = ["session_name", "pane_dead", "pane_dead_status", "pane_dead_signal", "@sidea_v", "@sidea_agent", "@sidea_cwd",
                      "@sidea_worktree", "@sidea_session", "@sidea_origin", "session_created", "pid", "@sidea_pane", "pane_id"].map { "#{\($0)}" }.joined(separator: "\t")
        refreshes += 1
        let generation = refreshes
        let listed = await run(["list-panes", "-a", "-F", format])
        // The watcher and a start can refresh at once; a reading taken earlier never replaces a later one.
        guard generation > applied else { return }
        applied = generation
        guard listed.status == 0 else {
            recoverSocket()
            if !sessions.isEmpty { sessions = [] }
            return
        }
        var found: [Session] = []
        var dead: [(Session, String)] = []
        for line in listed.output.split(separator: "\n") {
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count == 14 else { continue }
            serverPID = pid_t(p[11]) ?? serverPID
            // Sessions from before @sidea_pane: their first pane is the one the agent started in.
            if !p[12].isEmpty, p[12] != p[13] { continue }
            let session = Session(name: p[0], agent: p[4] == "1" ? Hosting.Agent(rawValue: p[5]) : nil, cwd: p[6], worktree: p[7],
                                  sessionID: p[8], origin: p[9], created: Double(p[10]) ?? 0, pane: p[13])
            guard !found.contains(where: { $0.name == session.name }) else { continue }
            if p[1] == "1", session.agent != nil {
                dead.append((session, p[2].isEmpty ? "signal \(p[3])" : "status \(p[2])"))
            } else {
                found.append(session)
            }
        }
        if found != sessions { sessions = found }
        var tabs: [String: Client] = [:]
        for (name, client) in await allClients() where !client.phone && tabs[name] == nil { tabs[name] = client }
        if tabs.mapValues(\.pid) != macClients.mapValues(\.pid) { macClients = tabs }
        for (session, ended) in dead where !finishing.contains(session.name) {
            finishing.insert(session.name)
            onEnded?(session.name, ended.hasPrefix("status ") ? Int(ended.dropFirst(7)) : nil, ending.remove(session.name) != nil ? .killed : .ended)
            await finish(session, ended: ended)
            finishing.remove(session.name)
        }
        onRefresh?()
    }

    /// The last screen is kept, then the session goes: an attached Mac tab returns to its prompt,
    /// as when Claude exits in a plain tab. A clean worktree Side A made goes with it.
    private func finish(_ session: Session, ended: String) async {
        cancelVerifier(session.name)
        let folder = runtime.appendingPathComponent("hosted/\(session.name)")
        let screen = await run(["capture-pane", "-p", "-J", "-t", pane(session.name), "-S", "-200"]).output
        try? PrivateFile.writeText(screen + "\n" + "Session ended (\(ended)).\n", to: folder.appendingPathComponent("last.txt"))
        _ = await run(["kill-session", "-t", "=\(session.name)"])
        log.info("\(session.name, privacy: .public) ended (\(ended, privacy: .public))")
        if !session.worktree.isEmpty {
            removeUnchangedCopies(session)
            // Never forced: a worktree with changes, untracked files or a process in it stays for Cleanup.
            struct Removed: Decodable { let removed: Bool }
            if let data = try? await bridge(["cleanup", "remove-worktree", session.worktree]),
               (try? JSONDecoder().decode(Removed.self, from: data))?.removed == true, let repo = Self.repository(of: session.worktree) {
                _ = await Self.process("/usr/bin/git", ["-C", repo, "branch", "-d", "sidea/\(session.name)"], timeout: 10)
            }
        }
        await changed()
    }

    /// The .env files copied in at the start are ignored files, which keep a worktree from being
    /// removed; a copy still identical to its source is Side A's to delete. Edited ones stay.
    private func removeUnchangedCopies(_ session: Session) {
        let folder = runtime.appendingPathComponent("hosted/\(session.name)")
        guard let source = try? String(contentsOf: folder.appendingPathComponent("copied-from"), encoding: .utf8)
            .trimmingCharacters(in: .newlines), !source.isEmpty else { return }
        for path in copiedFiles(session.name) where !path.contains("..") {
            let copy = URL(fileURLWithPath: session.worktree).appendingPathComponent(path)
            let original = URL(fileURLWithPath: source).appendingPathComponent(path)
            if let a = try? Data(contentsOf: copy), let b = try? Data(contentsOf: original), a == b {
                try? FileManager.default.removeItem(at: copy)
            }
        }
    }

    nonisolated static func repository(of worktree: String) -> String? {
        // <repo>/.sidea-worktrees/<name>
        let url = URL(fileURLWithPath: worktree)
        return url.deletingLastPathComponent().lastPathComponent == ".sidea-worktrees" ? url.deletingLastPathComponent().deletingLastPathComponent().path : nil
    }

    /// macOS may clean the socket out of /private/tmp under a long-lived server; SIGUSR1 makes tmux recreate it.
    private func recoverSocket() {
        guard serverPID > 1, !FileManager.default.fileExists(atPath: "/private/tmp/tmux-\(getuid())/sidea"),
              kill(serverPID, 0) == 0, Self.executable(of: serverPID)?.hasSuffix("/tmux") == true else { return }
        kill(serverPID, SIGUSR1)
    }

    private nonisolated static func executable(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Folders of sessions that ended more than a week ago.
    private func pruneFolders() {
        let folder = runtime.appendingPathComponent("hosted")
        let files = FileManager.default
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("sa-") {
            let url = folder.appendingPathComponent(name)
            guard let changed = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(changed) > 7 * 86_400, !sessions.contains(where: { $0.name == name }) else { continue }
            try? files.removeItem(at: url)
        }
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(".prompt-") {
            try? files.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: Running tmux

    /// -u: without a UTF-8 locale (an app started by launchd has none) tmux prints tabs in formats as '_'.
    private var server: [String] { ["-u"] + (environment["SIDE_A_TMUX_SOCKET"].map { ["-S", $0] } ?? ["-L", "sidea"]) }

    private func run(_ args: [String], input: Data? = nil) async -> (status: Int32, output: String) {
        guard let tmux else { return (-1, "") }
        let result = await Self.process(tmux, server + args, input: input, environment: environment, timeout: 10)
        return (result.status, result.output)
    }

    /// Runs a program with an argument array (no shell). TMUX and TMUX_TMPDIR are dropped so every
    /// client finds the same socket.
    nonisolated static func process(_ path: String, _ args: [String], input: Data? = nil, environment overrides: [String: String] = [:], timeout: TimeInterval)
        async -> (status: Int32, output: String, errors: String, elapsed: TimeInterval) {
        await Task.detached {
            let started = Date()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            var environment = ProcessInfo.processInfo.environment
            for key in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] { environment.removeValue(forKey: key) }
            environment.merge(overrides) { $1 }
            process.environment = environment
            let output = Pipe(), errors = Pipe(), stdin = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            do { try process.run() } catch { return (-1, "", error.localizedDescription, 0) }
            if let input {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            defer { watchdog.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let problems = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self),
                    String(decoding: problems, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), Date().timeIntervalSince(started))
        }.value
    }
}
