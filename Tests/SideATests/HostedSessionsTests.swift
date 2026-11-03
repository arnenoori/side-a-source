import Foundation
@testable import SideA
import SideACore
import Testing

/// A stand-in for Claude Code's TUI: its composer row (`❯` and a no-break space, a dim placeholder),
/// bracketed paste with a placeholder for long text, and an Enter it ignores once, as recent
/// Claude Code does just after its composer appears. It notes its pid, arguments and SIDE_A_PIN; started with
/// `--model stubborn` it ignores SIGHUP and SIGTERM, as an agent that outlives its pane would.
/// Like 2.1.303 it lists the slash command being typed, opens `/model`'s picker and `/effort`'s slider (`s` applies a
/// pick to this session, Enter saves it as the default, noted as DEFAULT), asks before switching a conversation it has
/// answered in (as a PreModelSwitch hook when started with `hooked`), and cycles its mode with Shift+Tab. Started with
/// `untrusted` it first asks to trust its folder, "No, exit" selected (with `elsewhere`, for another folder).
let fakeClaude = #"""
#!/usr/bin/env python3
import os, signal, sys, time, tty
out = sys.argv[1]
open(out + ".pid", "w").write(str(os.getpid()))
open(out + ".args", "w").write(repr(sys.argv[1:]))
open(out + ".pin", "w").write(os.environ.get("SIDE_A_PIN", ""))
if "stubborn" in sys.argv:
    signal.signal(signal.SIGHUP, signal.SIG_IGN); signal.signal(signal.SIGTERM, signal.SIG_IGN)
tty.setraw(0)
echoed, buffer, shown, ignore_enter = [], "", None, True
MODELS = [("Default (recommended)", ["low", "medium", "high", "xhigh", "max"]), ("Opus 5.5", ["low", "medium", "high", "xhigh", "max"]),
          ("Sonnet 5.5", ["low", "medium", "high", "max"]), ("Haiku 5.5", []), ("Opus 5", ["low", "medium", "high", "max"])]
MODES = ["⏸ manual mode on", "⏵⏵ accept edits on", "⏸ plan mode on", "⏵⏵ auto mode on"]
model, effort, mode, screen, selected, pending = 1, "medium", 3, None, 1, "medium"
trusting = False
if "untrusted" in sys.argv or "elsewhere" in sys.argv: screen = "trust"
def note(line):
    with open(out, "a") as f: f.write(line + "\n")
def draw():
    w = lambda s: os.write(1, s.encode())
    w("\x1b[2J\x1b[H\x1b[?2004h")
    for line in echoed[-5:]:
        w("❯ " + line + "\r\n")
    if screen == "trust":
        w(" Accessing workspace:\r\n " + ("/somewhere/else" if "elsewhere" in sys.argv else os.getcwd()) + "\r\n")
        w(" Quick safety check: Is this a project you created or one you trust?\r\n")
        w(("   No, exit\r\n ❯ Yes, I trust this folder" if trusting else " ❯ No, exit\r\n   Yes, I trust this folder") + "\r\n")
        w(" Enter to confirm · Esc to cancel")
        return
    if screen == "picker":
        w("   Select model\r\n")
        for i, (name, _) in enumerate(MODELS):
            w(("   ❯ " if i == selected else "     ") + "%d.  %-22s Fast for tests\r\n" % (i + 1, name + (" ✔" if i == model else "")))
        levels = MODELS[selected][1]
        w(("   ● %s effort ←/→ to adjust\r\n" % pending.capitalize()) if levels else "   Effort not supported\r\n")
        w("   Enter to set as default · s to use this session only · Esc to cancel")
        return
    if screen == "slider":
        levels = MODELS[model][1]
        cols = {"low": 0, "medium": 8, "high": 19, "xhigh": 28, "max": 39}
        w("   Effort\r\n" + " " * 29 + "─" * (cols[pending] + len(pending) // 2) + "▲" + "─" * 10 + "\r\n")
        w(" " * 29 + "low     medium     high     xhigh      max\r\n")
        w("   ←/→ to adjust · Enter to confirm · s for this session only · Esc to cancel")
        return
    if screen and screen.startswith("confirm"):
        target = screen.split(":", 1)[1]
        w("   Switch model?\r\n   " + ("A PreModelSwitch hook asked you to confirm" if "hooked" in sys.argv else "Your next response will be slower") + "\r\n")
        w("   ❯ 1. Yes, switch to " + target + "\r\n     2. No, go back")
        return
    if buffer.startswith("/") and " " not in buffer:
        w("  ❯ " + buffer + "      Run " + buffer[1:] + "\r\n")
    w("─" * 40 + "\r\n")
    w("❯\u00a0" + (shown or buffer) if (shown or buffer) else "❯\u00a0\x1b[2mTry \"refactor <filepath>\"\x1b[0m")
    w("\r\n" + "─" * 40 + "\r\n  \x1b[2m" + MODES[mode] + ("" if mode == 0 else " (shift+tab to cycle)") + "\x1b[0m")
def apply_model():
    global model, effort, screen
    model, effort, screen = selected, pending if MODELS[selected][1] else None, None
    note("MODEL %s %s" % (MODELS[model][0], effort)); echoed.append("⎿ Set model to %s for this session only" % MODELS[model][0])
def key(name):
    global screen, selected, pending, effort, mode, trusting
    if screen == "trust":
        if name in ("Up", "Down"): trusting = not trusting
        elif name == "Enter" and trusting: note("TRUSTED"); screen = None
        elif name in ("Enter", "Escape"): note("TRUST " + name); sys.exit(0)
    elif screen == "picker":
        levels = MODELS[selected][1]
        if name in ("Up", "Down"):
            selected = (selected + (1 if name == "Down" else -1)) % len(MODELS)
            levels = MODELS[selected][1]
            if levels and pending not in levels: pending = "high"
        elif name in ("Left", "Right") and levels:
            pending = levels[max(0, min(len(levels) - 1, levels.index(pending) + (1 if name == "Right" else -1)))]
        elif name == "s":
            if any(not line.startswith("⎿") for line in echoed) and selected != model: screen = "confirm:" + MODELS[selected][0]
            else: apply_model()
        elif name == "Enter": note("DEFAULT"); screen = None
        elif name == "Escape": screen = None; echoed.append("⎿ Cancelled")
    elif screen == "slider":
        levels = MODELS[model][1]
        if name in ("Left", "Right"):
            pending = levels[max(0, min(len(levels) - 1, levels.index(pending) + (1 if name == "Right" else -1)))]
        elif name == "s":
            effort, screen = pending, None
            note("EFFORT " + effort); echoed.append("⎿ Set effort level to %s (this session only): ok" % effort)
        elif name == "Enter": note("DEFAULT"); screen = None
        elif name == "Escape": screen = None; echoed.append("⎿ Cancelled")
    elif screen and screen.startswith("confirm"):
        if name == "Enter": apply_model()
        elif name == "Escape": screen = "picker"
    elif name == "BTab":
        mode = (mode + 1) % len(MODES); note("MODE " + MODES[mode])
    elif name == "Escape": note("ESC")
draw()
data = b""
while True:
    try: chunk = os.read(0, 65536)
    except OSError: chunk = b""
    # The terminal goes when the pane's shell exits; a stubborn agent carries on regardless.
    if not chunk: time.sleep(60) if "stubborn" in sys.argv else sys.exit(1)
    data += chunk
    while data:
        if data.startswith(b"\x1b[200~"):
            end = data.find(b"\x1b[201~")
            if end < 0: break
            text = data[6:end].decode().replace("\r", "\n")
            buffer += text
            if "\n" in text or len(text) > 200: shown = "[Pasted text #1 +%d lines]" % (text.count("\n") + 1)
            data = data[end + 6:]
        elif data[:3] in (b"\x1b[Z", b"\x1b[A", b"\x1b[B", b"\x1b[C", b"\x1b[D", b"\x1bOA", b"\x1bOB", b"\x1bOC", b"\x1bOD"):
            key({"Z": "BTab", "A": "Up", "B": "Down", "C": "Right", "D": "Left"}[chr(data[2])]); data = data[3:]
        elif screen and data[:1] in (b"\r", b"s", b"\x1b"):
            key({b"\r": "Enter", b"s": "s", b"\x1b": "Escape"}[data[:1]]); data = data[1:]
        elif screen:
            data = data[1:]
        elif data[:1] == b"\r":
            data = data[1:]
            if buffer in ("/model", "/effort"):
                screen, buffer = ("picker" if buffer == "/model" else "slider"), ""
                selected, pending = model, effort or "medium"
                continue
            if ignore_enter or buffer.startswith("STICKY"): ignore_enter = False; continue
            if buffer == "/exit": sys.exit(0)
            with open(out, "a") as f: f.write(repr(buffer) + "\n")
            echoed.append(buffer.split("\n")[0]); buffer, shown = "", None
        elif data[:1] == b"\x15":
            data = data[1:]; buffer, shown = "", None
        elif data[:1] == b"\x1b":
            data = data[1:]
            key("Escape")
        else:
            buffer += data[:1].decode(errors="replace"); data = data[1:]
    draw()
"""#

struct HostedFixture {
    let base: URL
    let root: URL
    let project: URL
    let submitted: URL
    let tmux: String
    let socket: String

    init() throws {
        base = URL(fileURLWithPath: "/tmp").appendingPathComponent("sa-\(UUID().uuidString.prefix(8))")
        root = base.appendingPathComponent("Side A")
        project = base.appendingPathComponent("app")
        submitted = base.appendingPathComponent("submitted")
        socket = base.appendingPathComponent("s").path
        let home = base.appendingPathComponent("home"), bin = base.appendingPathComponent("bin")
        for folder in [root.appendingPathComponent("runtime"), project, home, bin] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let fake = bin.appendingPathComponent("claude")
        try fakeClaude.replacingOccurrences(of: "sys.argv[1]", with: "'\(submitted.path)'").write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        // The pane's login shell reads this, never the real ~/.zshrc.
        try "export PATH=\(bin.path):$PATH\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }

    var environment: [String: String] { ["SIDE_A_TMUX_SOCKET": socket, "HOME": base.appendingPathComponent("home").path] }

    func bridge(_ args: [String]) async throws -> Data {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("bridge/sidea_bridge.py").path
        let result = await HostedSessions.process("/usr/bin/python3", [script, "--root", root.path] + args, environment: environment, timeout: 30)
        return Data(result.output.utf8)
    }

    func lines() -> [String] { ((try? String(contentsOf: submitted, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    /// `cleanUp` for a signal handler, which can't wait.
    func stop() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["-S", socket, "kill-server"]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: base)
    }

    func cleanUp() async {
        _ = await HostedSessions.process(tmux, ["-S", socket, "kill-server"], timeout: 5)
        try? FileManager.default.removeItem(at: base)
    }
}

@MainActor
private func waitFor(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return false
}

@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func repliesGoInAsOnePasteAndEnterIsPressedAgainOnlyForSideAsText() async throws {
    let fixture = try HostedFixture()
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge)
    await hosted.install()
    do { try await exercise(hosted, fixture) } catch { Issue.record(error) }
    await fixture.cleanUp()
}

@MainActor
private func exercise(_ hosted: HostedSessions, _ fixture: HostedFixture) async throws {
    try #require(hosted.available)
    let name = try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .new(model: nil)))
    #expect(name.hasPrefix("sa-app-"))
    #expect(hosted.sessions.map(\.name) == [name] && hosted.sessions.first?.agent == .claude)
    #expect(await waitFor { Hosting.ready(.claude, screen: await hosted.capture(name)) })
    // The mouse scrolls and selects, but no right-click menu can kill or swap a pane.
    let root = await HostedSessions.process(fixture.tmux, ["-S", fixture.socket, "list-keys", "-T", "root"], timeout: 5).output
    #expect(root.contains("WheelUpPane") && !root.contains("MouseDown3"))

    // The first Enter is ignored; the verifier sees the reply still there, photo paths and all, and presses again at 2 s.
    let photos = ["/tmp/Side A/uploads/one.jpg", "/tmp/Side A/uploads/two.jpg"]
    try await hosted.reply(name, text: "What's in these photos?", images: photos)
    #expect(await waitFor(5) { fixture.lines() == ["\"'\(photos[0])' '\(photos[1])' What's in these photos?\""] }, "\(fixture.lines())")

    try await hosted.reply(name, text: "Fix the build; then run the tests again")
    #expect(await waitFor(5) { fixture.lines().last == "'Fix the build; then run the tests again'" })

    // Long text shows as a placeholder and still arrives whole, trailing ';' and all.
    let long = (1...12).map { "line \($0) of the plan;" }.joined(separator: "\n")
    try await hosted.reply(name, text: long)
    #expect(await waitFor(5) { fixture.lines().count == 3 })
    #expect(fixture.lines().last == String(reflecting: long).replacingOccurrences(of: "\"", with: "'"))

    // Two phones at once: each message goes in whole, one after the other, though the fake ignores each first Enter.
    async let first: Void = hosted.reply(name, text: "first from one phone")
    async let second: Void = hosted.reply(name, text: "second from another")
    _ = try await (first, second)
    #expect(await waitFor(10) { fixture.lines().count == 5 })
    #expect(Set(fixture.lines().suffix(2)) == ["'first from one phone'", "'second from another'"])

    // Someone splits the window and the new pane is the active one: the reply still goes to the agent's pane.
    let stray = fixture.root.appendingPathComponent("stray.txt")
    let split = await HostedSessions.process(fixture.tmux, ["-S", fixture.socket, "split-window", "-P", "-F", "#{pane_id}", "-t", "=\(name):",
                                                            "cat > " + Shell.quote(stray.path)], timeout: 5)
    let strayPane = split.output.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(strayPane.hasPrefix("%"))
    await hosted.refresh()
    #expect(hosted.sessions.map(\.name) == [name] && hosted.sessions.first?.pane != strayPane)
    try await hosted.reply(name, text: "after a split")
    #expect(await waitFor(5) { fixture.lines().last == "'after a split'" })
    #expect(((try? String(contentsOf: stray, encoding: .utf8)) ?? "").isEmpty)
    _ = await HostedSessions.process(fixture.tmux, ["-S", fixture.socket, "kill-pane", "-t", strayPane], timeout: 5)

    // A draft typed at the Mac is never sent by Side A.
    _ = await HostedSessions.process(fixture.tmux, ["-S", fixture.socket, "send-keys", "-t", hosted.sessions[0].pane, "-l", "my draft"], timeout: 5)
    #expect(await waitFor { Hosting.composer(.claude, screen: await hosted.capture(name)) == .text("my draft") })
    await #expect(throws: HostedError.self) { try await hosted.reply(name, text: "from the phone") }
    _ = await HostedSessions.process(fixture.tmux, ["-S", fixture.socket, "send-keys", "-t", "=\(name):", "C-u"], timeout: 5)

    // Keys are allowlisted; Esc interrupts only while working.
    await #expect(throws: HostedError.self) { try await hosted.keys(name, ["C-d"]) }
    await #expect(throws: HostedError.self) { try await hosted.interrupt(name, working: false) }
    try await hosted.interrupt(name, working: true)
    #expect(await waitFor { fixture.lines().last == "ESC" })

    // The agent exits: its last screen is kept and the session goes.
    try await hosted.reply(name, text: "/exit")
    // The list empties as soon as the pane is dead; the last screen is written just after.
    let saved = fixture.root.appendingPathComponent("runtime/hosted/\(name)/last.txt")
    #expect(await waitFor(8) { await hosted.refresh(); return hosted.sessions.isEmpty && FileManager.default.fileExists(atPath: saved.path) })
    let last = try String(contentsOf: saved, encoding: .utf8)
    #expect(last.contains("Session ended (status 0)."))
}

@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func worktreeSessionsCleanUpAfterThemselvesAndAmbiguityIsRaisedNotPressed() async throws {
    let fixture = try HostedFixture()
    let running = LiveSession(pid: 1, sessionID: "S-live", name: nil, title: nil, cost: nil, cwd: fixture.project.path, status: "idle", waitingFor: nil, since: nil)
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge, live: { [running] })
    var attention: [(String, HostedSessions.Attention)] = []
    hosted.onAttention = { attention.append(($0, $1)) }
    await hosted.install()
    do {
        try #require(hosted.available)
        // A resume of a conversation that runs, idle or not, is never started twice.
        await #expect(throws: HostedError.self) { try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .resume("S-live"))) }
        // Nor is a Codex fork of it, until `codex fork` is known to leave the parent's rollout alone.
        await #expect(throws: HostedError.self) { try await hosted.start(.init(agent: .codex, cwd: fixture.project.path, mode: .fork("S-live"))) }
        #expect(hosted.sessions.isEmpty)

        let git = { (args: [String]) async in _ = await HostedSessions.process("/usr/bin/git", ["-C", fixture.project.path] + args, timeout: 10) }
        await git(["init", "-q", "-b", "main"])
        try ".env\n".write(to: fixture.project.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        await git(["add", "-A"])
        await git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"])
        try "KEY=1\n".write(to: fixture.project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let name = try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .new(model: nil), worktree: "HEAD"))
        // git reports the resolved path (/private/tmp); Foundation's resolving drops /private instead.
        let real = realpath(fixture.project.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? fixture.project.path
        let tree = real + "/.sidea-worktrees/\(name)"
        #expect(hosted.sessions.first?.worktree == tree)
        #expect(hosted.copiedFiles(name) == [".env"])
        #expect(await waitFor { Hosting.ready(.claude, screen: await hosted.capture(name)) })

        // The fake never takes this one; someone then types after it, so whose text it is is unclear.
        try await hosted.reply(name, text: "STICKY: hold on to this message for a while")
        _ = await HostedSessions.process(fixture.tmux, ["-S", fixture.socket, "send-keys", "-t", "=\(name):", "-l", " and more"], timeout: 5)
        #expect(await waitFor(5) { attention.contains { $0.0 == name && $0.1.kind == "unsent" } })
        #expect(fixture.lines().isEmpty)
        _ = await HostedSessions.process(fixture.tmux, ["-S", fixture.socket, "send-keys", "-t", "=\(name):", "C-u"], timeout: 5)

        // The session ends: the unchanged .env copy goes, so the clean worktree and its branch go too.
        _ = try? await hosted.reply(name, text: "/exit")
        #expect(await waitFor(8) { await hosted.refresh(); return hosted.sessions.isEmpty && !FileManager.default.fileExists(atPath: tree) })
        let branches = await HostedSessions.process("/usr/bin/git", ["-C", fixture.project.path, "branch", "--list", "sidea/*"], timeout: 10)
        #expect(branches.output.isEmpty)
    } catch { Issue.record(error) }
    await fixture.cleanUp()
}

@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func tmuxIsWatchedAgainAfterAnInstallThatFailed() async throws {
    let fixture = try HostedFixture()
    var failing = false
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: { args in
        if failing { throw BridgeFailure(message: "the helper didn't finish within 60s") }
        return try await fixture.bridge(args)
    })
    await hosted.install()
    failing = true
    await hosted.install()
    #expect(!hosted.available)
    // The watcher sees tmux gone once its wait ends, within 5 s.
    try await Task.sleep(for: .seconds(6))
    failing = false
    await hosted.install()
    #expect(hosted.available)
    let made = await HostedSessions.process(fixture.tmux, ["-S", fixture.socket, "new-session", "-d", "-s", "by-hand", "sleep 60"],
                                            environment: fixture.environment, timeout: 5)
    #expect(made.status == 0)
    #expect(await waitFor(15) { hosted.sessions.map(\.name) == ["by-hand"] }, "\(hosted.sessions.map(\.name))")
    hosted.stop()
    await fixture.cleanUp()
}

@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func endStopsAnAgentThatOutlivesTheHangup() async throws {
    let fixture = try HostedFixture()
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge)
    var ended: [String] = []
    hosted.onEnded = { name, _, _ in ended.append(name) }
    await hosted.install()
    do {
        try #require(hosted.available)
        let name = try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .new(model: "stubborn")))
        #expect(await waitFor { Hosting.ready(.claude, screen: await hosted.capture(name)) })
        let agent = try #require(pid_t(String(contentsOf: fixture.submitted.appendingPathExtension("pid"), encoding: .utf8)))
        // The hangup ends the pane's shell but not this agent; SIGTERM is ignored too, so it takes SIGKILL.
        let started = Date()
        try await hosted.end(name)
        #expect(Date().timeIntervalSince(started) > 3)
        #expect(await waitFor(3) { kill(agent, 0) == -1 })
        #expect(await waitFor(5) { await hosted.refresh(); return hosted.sessions.isEmpty })
        #expect(ended == [name])
        await #expect(throws: HostedError.self) { try await hosted.end(name) }
    } catch { Issue.record(error) }
    await fixture.cleanUp()
}

/// Continue on phone is offered only for an idle or waiting terminal session; never busy, a background shell,
/// unknown, headless, hosted, or a Codex turn that hasn't finished.
@Test func continueOnPhoneIsOfferedOnlyWhenEndingItLosesNothing() {
    func session(_ status: String, agent: String = "claude", kind: String? = "interactive", hosted: String? = nil, id: String? = "S1") -> LiveSession {
        var live = LiveSession(pid: 10, sessionID: id, name: nil, title: nil, cost: nil, cwd: "/tmp", status: status, waitingFor: nil, since: nil)
        live.agent = agent; live.kind = kind; live.hosted = hosted
        return live
    }
    #expect(HostedSessions.continueRefusal(session("idle")) == nil)
    #expect(HostedSessions.continueRefusal(session("waiting")) == nil)
    #expect(HostedSessions.continueRefusal(session("idle", agent: "codex", kind: nil)) == nil)
    for refused in [session("busy"), session("shell"), session("unknown"), session("waiting", agent: "codex", kind: nil),
                    session("idle", kind: "sdk"), session("idle", hosted: "sa-app-1"), session("idle", id: nil)] {
        #expect(HostedSessions.continueRefusal(refused) != nil)
    }
}

/// A terminal Claude session as Continue on phone finds it: a registry file named by its pid that goes on
/// SIGTERM, after one last transcript line. Started as `stubborn` it ignores SIGTERM. Detached, so it
/// isn't the test's child and leaves no zombie behind.
let macSession = #"""
import os, signal, sys, time
registry, transcript = sys.argv[1], sys.argv[2]
entry = os.path.join(registry, "%d.json" % os.getpid())
open(entry, "w").write("{}")
def term(*_):
    open(transcript, "a").write('{"type":"saved"}\n'); os.remove(entry); sys.exit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN if "stubborn" in sys.argv else term)
while True: time.sleep(1)
"""#

@MainActor
private final class ContinueScene {
    let fixture: HostedFixture
    let registry: URL
    let transcript: URL
    var hosted: HostedSessions!
    var mac: LiveSession!

    init() throws {
        fixture = try HostedFixture()
        registry = fixture.base.appendingPathComponent("home/.claude/sessions")
        transcript = fixture.base.appendingPathComponent("S1.jsonl")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)
        hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge, live: { [unowned self] in self.live() })
    }

    /// The Mac process while it runs, then the hosted agent once it's up under its pane with the conversation.
    func live() -> [LiveSession] {
        var rows: [LiveSession] = []
        if let mac, ProcessCheck.alive(mac.pid) { rows.append(mac) }
        let submitted = fixture.submitted
        if let args = try? String(contentsOf: submitted.appendingPathExtension("args"), encoding: .utf8), args.contains("'S1'"),
           let pid = (try? String(contentsOf: submitted.appendingPathExtension("pid"), encoding: .utf8)).flatMap(Int.init),
           let name = hosted.sessions.first?.name {
            var row = LiveSession(pid: pid, sessionID: "S1", name: nil, title: nil, cost: nil, cwd: fixture.project.path, status: "idle", waitingFor: nil, since: nil)
            row.hosted = name
            rows.append(row)
        }
        return rows
    }

    func startMac(stubborn: Bool = false) async throws {
        let script = fixture.base.appendingPathComponent("mac.py")
        try macSession.write(to: script, atomically: true, encoding: .utf8)
        let command = "SIDE_A_PIN=work nohup /usr/bin/python3 \(Shell.quote(script.path)) \(Shell.quote(registry.path)) \(Shell.quote(transcript.path))"
            + (stubborn ? " stubborn" : "") + " >/dev/null 2>&1 & echo $!"
        let pid = try #require(Int(await HostedSessions.process("/bin/sh", ["-c", command], timeout: 5).output.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await waitFor { FileManager.default.fileExists(atPath: self.registry.appendingPathComponent("\(pid).json").path) })
        mac = LiveSession(pid: pid, sessionID: "S1", name: nil, title: nil, cost: nil, cwd: fixture.project.path, status: "idle", waitingFor: nil, since: nil)
        mac.agent = "claude"; mac.kind = "interactive"
        mac.started = ProcessCheck.startTime(pid)?.rounded(.down)
    }

    func cleanUp() async {
        if let mac { kill(pid_t(mac.pid), SIGKILL) }
        await fixture.cleanUp()
    }
}

/// The Mac process gets SIGTERM, its last transcript line lands, and the same conversation comes back up in tmux
/// on the same pinned account; Continue then answers with the hosted session's name.
@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func continueOnPhoneEndsTheMacProcessAndResumesItInTmux() async throws {
    let scene = try ContinueScene()
    await scene.hosted.install()
    do {
        try #require(scene.hosted.available)
        try await scene.startMac()
        let name = try await scene.hosted.continueHere(scene.mac, transcript: scene.transcript, registry: scene.registry)
        #expect(name.hasPrefix("sa-app-") && scene.hosted.sessions.map(\.name) == [name])
        #expect(!ProcessCheck.alive(scene.mac.pid))
        #expect((try String(contentsOf: scene.transcript, encoding: .utf8)).hasSuffix("{\"type\":\"saved\"}\n"))
        let submitted = scene.fixture.submitted
        #expect(try String(contentsOf: submitted.appendingPathExtension("args"), encoding: .utf8) == "['--resume', 'S1']")
        #expect(try String(contentsOf: submitted.appendingPathExtension("pin"), encoding: .utf8) == "work")
        let origin = await HostedSessions.process(scene.fixture.tmux, ["-S", scene.fixture.socket, "show-options", "-v", "-t", "=\(name):", "@sidea_origin"], timeout: 5)
        #expect(origin.output.trimmingCharacters(in: .newlines) == "continue")

        // Now hosted, it can't be moved again; the route answers that case with the session itself.
        await #expect(throws: HostedError.self) { try await scene.hosted.continueHere(scene.live().last!, transcript: nil, registry: scene.registry) }
    } catch { Issue.record(error) }
    await scene.cleanUp()
}

/// A process that ignores SIGTERM keeps running on the Mac, and nothing starts in tmux.
@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func continueOnPhoneLeavesASessionThatDidntQuit() async throws {
    let scene = try ContinueScene()
    await scene.hosted.install()
    do {
        try #require(scene.hosted.available)
        try await scene.startMac(stubborn: true)
        do {
            _ = try await scene.hosted.continueHere(scene.mac, transcript: scene.transcript, registry: scene.registry)
            Issue.record("It continued a session that didn't quit.")
        } catch HostedError.refused(let message) {
            #expect(message.contains("didn't quit"))
        }
        #expect(ProcessCheck.alive(scene.mac.pid))
        #expect(scene.hosted.sessions.isEmpty)
    } catch { Issue.record(error) }
    await scene.cleanUp()
}

@Test func aWorktreeBelongsToTheRepoItCameFrom() {
    #expect(HostedSessions.repository(of: "/r/app/.sidea-worktrees/sa-app-1c2d") == "/r/app")
    #expect(HostedSessions.repository(of: "/r/app") == nil)
}

@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func settingsGoThroughClaudesPickersForThisSessionOnly() async throws {
    let fixture = try HostedFixture()
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge)
    await hosted.install()
    do {
        try #require(hosted.available)
        let name = try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .new(model: nil)))
        #expect(await waitFor { Hosting.ready(.claude, screen: await hosted.capture(name)) })

        // Model and effort in one pick, applied with s; never Enter, which saves the default.
        var done = try await hosted.change(name, model: "claude-sonnet-5-5", effort: "high", mode: nil)
        #expect(done == .init(model: "claude-sonnet-5-5", effort: "high"))
        #expect(fixture.lines() == ["MODEL Sonnet 5.5 high"])
        // Sonnet has no xhigh: the slider steps over it and back, and Esc leaves everything as it was.
        await #expect(throws: HostedError.self) { try await hosted.change(name, model: nil, effort: "xhigh", mode: nil) }
        #expect(fixture.lines() == ["MODEL Sonnet 5.5 high"])
        let after = await hosted.capture(name)
        #expect(Hosting.ready(.claude, screen: after))
        done = try await hosted.change(name, model: nil, effort: "max", mode: nil)
        #expect(done.effort == "max" && fixture.lines().last == "EFFORT max")

        // Once it has answered, a switch asks first; Yes for exactly that model is pressed. "opus" is the newest Opus,
        // though Opus 5 comes first going down from Sonnet.
        try await hosted.reply(name, text: "hello")
        #expect(await waitFor(5) { fixture.lines().last == "'hello'" })
        done = try await hosted.change(name, model: "opus", effort: nil, mode: nil)
        #expect(done.model == "opus" && fixture.lines().last == "MODEL Opus 5.5 max")

        // Shift+Tab until the footer says plan, through manual mode's footer; bypass isn't in the cycle, so it comes round.
        done = try await hosted.change(name, model: nil, effort: nil, mode: "plan")
        var footer = await hosted.capture(name)
        #expect(done.mode == "plan" && Hosting.claudeMode(screen: footer) == "plan")
        await #expect(throws: HostedError.self) { try await hosted.change(name, model: nil, effort: nil, mode: "bypassPermissions") }
        footer = await hosted.capture(name)
        #expect(Hosting.claudeMode(screen: footer) == "plan")

        // What the list can't pick is refused before any key.
        let count = fixture.lines().count
        await #expect(throws: HostedError.self) { try await hosted.change(name, model: "opus[1m]", effort: nil, mode: nil) }
        #expect(fixture.lines().count == count && !fixture.lines().contains("DEFAULT"))

        // /compact goes in once the list offers it, and the verifier presses again past the Enter the fake ignores;
        // nothing off the allowlist is typed.
        try await hosted.command(name, "/compact")
        #expect(await waitFor(5) { fixture.lines().last == "'/compact'" }, "\(fixture.lines())")
        await #expect(throws: HostedError.self) { try await hosted.command(name, "/clear") }

        // A compaction that never shows raises attention; one that does, nothing.
        var raised: [String] = []
        hosted.onAttention = { _, attention in raised.append(attention.kind) }
        hosted.expectCompaction(name, within: 0.3, every: .milliseconds(50)) { true }
        hosted.expectCompaction(name, within: 0.3, every: .milliseconds(50)) { false }
        #expect(await waitFor(3) { raised == ["screen"] })
        try await Task.sleep(for: .milliseconds(400))
        #expect(raised == ["screen"])
    } catch { Issue.record(error) }
    await fixture.cleanUp()
}

@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func aHooksConfirmIsLeftForTheMac() async throws {
    let fixture = try HostedFixture()
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge)
    await hosted.install()
    do {
        try #require(hosted.available)
        let name = try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .new(model: "hooked")))
        #expect(await waitFor { Hosting.ready(.claude, screen: await hosted.capture(name)) })
        try await hosted.reply(name, text: "hello")
        #expect(await waitFor(5) { fixture.lines().last == "'hello'" })
        do {
            _ = try await hosted.change(name, model: "claude-sonnet-5-5", effort: nil, mode: nil)
            Issue.record("A hook's confirm was answered")
        } catch HostedError.refused(let message) {
            #expect(message.contains("Confirm it on the Mac"))
        }
        // Esc twice: the confirm, then the picker it went back to.
        #expect(await waitFor { Hosting.ready(.claude, screen: await hosted.capture(name)) })
        #expect(fixture.lines() == ["'hello'"])
    } catch { Issue.record(error) }
    await fixture.cleanUp()
}

@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func trustAnswersOnlyThisFoldersQuestion() async throws {
    let fixture = try HostedFixture()
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge)
    await hosted.install()
    var raised: [(String, String)] = []
    hosted.onAttention = { _, attention in raised.append((attention.kind, attention.text)) }
    do {
        try #require(hosted.available)
        let name = try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .new(model: "untrusted")))
        // The question raises attention for the phone's Trust and start.
        #expect(await waitFor(5) { raised.first?.0 == "trust" })
        #expect(raised.first?.1 == "Quick safety check: Is this a project you created or one you trust?")
        try await hosted.trust(name)
        #expect(fixture.lines() == ["TRUSTED"])
        #expect(await waitFor { Hosting.ready(.claude, screen: await hosted.capture(name)) })
        // Nothing to answer now: refused, nothing pressed.
        await #expect(throws: HostedError.self) { try await hosted.trust(name) }

        // A question for another folder gets no key at all: Esc or Enter there would end the session.
        let other = try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .new(model: "elsewhere")))
        #expect(await waitFor { Hosting.trust(.claude, screen: await hosted.capture(other)) != nil })
        await #expect(throws: HostedError.self) { try await hosted.trust(other) }
        let screen = await hosted.capture(other)
        #expect(Hosting.trust(.claude, screen: screen) == .otherSelected && fixture.lines() == ["TRUSTED"])
    } catch { Issue.record(error) }
    await fixture.cleanUp()
}
