import AppKit
import Darwin
import SideACore

/// Types a message into a session's own terminal tab: the last way in for a session idle in a terminal Side A doesn't
/// host, with no hook waiting and no app server to reach it through. What's typed is the user's own message to the
/// agent, the same as if they had typed it there.
enum TerminalTyping {
    enum Reach: Equatable, Sendable {
        /// A pane on the user's own tmux server: its screen can be read, so the composer is checked first.
        case tmux
        /// Ghostty's own scripting, which finds the tab by its tty and takes text and keys.
        case ghostty
    }

    struct Failure: Error, Equatable { let message: String }

    /// The first Ghostty whose scripting names each terminal's tty and takes typed text.
    static let ghostty = [1, 4]

    /// How the session's terminal takes typed text, or nil when it takes none. Looks only at processes, so a listing
    /// can ask it of every session.
    static func reach(pid: Int) -> Reach? {
        if TerminalFocus.inTmux(pid) { return .tmux }
        guard let host = TerminalFocus.host(of: pid), host.bundleID == "com.mitchellh.ghostty", host.tty != nil,
              let version = NSRunningApplication(processIdentifier: host.pid)?.bundleURL.flatMap({ Bundle(url: $0) })?
                  .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
        return atLeast(version, ghostty) ? .ghostty : nil
    }

    static func atLeast(_ version: String, _ floor: [Int]) -> Bool {
        let parts = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for (index, wanted) in floor.enumerated() {
            let have = index < parts.count ? parts[index] : 0
            if have != wanted { return have > wanted }
        }
        return true
    }

    /// Types the text and presses Enter. Refused unless the session is what its terminal shows in front, so nothing
    /// is typed at a shell or into a program the session started.
    /// `transcript`: the session's own, when known; a tab whose screen can't be read is checked against it.
    static func type(_ text: String, into pid: Int, agent: Hosting.Agent, transcript: URL? = nil) async throws(Failure) {
        let text = Hosting.clean(text)
        guard !text.isEmpty else { return }
        guard let reach = reach(pid: pid) else { throw Failure(message: "Side A can't type into this session's terminal.") }
        guard inFront(pid) else { throw Failure(message: "The session isn't what its terminal shows right now.") }
        switch reach {
        case .tmux: try await tmux(text, pid: pid, agent: agent)
        case .ghostty: try await ghostty(text, pid: pid, transcript: transcript)
        }
    }

    /// The session's process group is the one its terminal reads keys for.
    static func inFront(_ pid: Int) -> Bool { TerminalFocus.inFront(pid) }


    @MainActor private static var held: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// One at a time per pane, as hosted sessions' composer lock: a reply typed while a settings change walks a
    /// picker would land in the picker, and two replies would paste into each other.
    @MainActor static func lock(_ pane: TerminalFocus.TmuxPane) async {
        let key = pane.socket + " " + pane.pane
        if held[key] == nil { held[key] = []; return }
        await withCheckedContinuation { held[key, default: []].append($0) }
    }

    @MainActor static func unlock(_ pane: TerminalFocus.TmuxPane) {
        let key = pane.socket + " " + pane.pane
        guard var waiting = held[key], !waiting.isEmpty else { held[key] = nil; return }
        let next = waiting.removeFirst()
        held[key] = waiting
        next.resume()
    }

    /// As a hosted reply goes: refused over a dialog or someone's draft, pasted, and Enter only once the composer
    /// shows what was pasted.
    @MainActor private static func tmux(_ text: String, pid: Int, agent: Hosting.Agent) async throws(Failure) {
        guard let pane = await TerminalFocus.tmuxPane(of: pid) else { throw Failure(message: "The session's tmux pane could not be found.") }
        await lock(pane)
        defer { unlock(pane) }
        let run = { (args: [String], input: Data?) in
            await HostedSessions.process(pane.tmux, ["-u", "-S", pane.socket] + args, input: input, timeout: 5)
        }
        let screen = { await run(["capture-pane", "-p", "-e", "-J", "-t", pane.pane], nil).output }
        let before = await screen()
        if Hosting.dialog(agent, screen: before) { throw Failure(message: "The session is asking something; answer it first.") }
        switch Hosting.composer(agent, screen: before) {
        case .none: throw Failure(message: "That session isn't ready for a message yet.")
        case .text: throw Failure(message: "The session's message field already holds a draft.")
        case .empty: break
        }
        let buffer = "sidea-type-\(getpid())-\(pid)"
        let pasted = await run(HostedSessions.paste(buffer: buffer, into: pane.pane), Data(text.utf8))
        guard pasted.status == 0 else {
            _ = await run(["delete-buffer", "-b", buffer], nil)
            throw Failure(message: "The text could not be typed into that session.")
        }
        var owned: String?
        for _ in 0..<8 where owned == nil {
            try? await Task.sleep(for: .milliseconds(60))
            owned = Hosting.owned(sent: text, agent: agent, screen: await screen())
        }
        // Not its own text in the composer: Enter could send someone else's words or answer a dialog that just opened.
        guard let expected = owned else { throw Failure(message: "It's typed in but wasn't sent.") }
        // Claude Code can swallow an Enter that comes right after a paste: pressed again only while the composer
        // still shows exactly what was pasted, and never over a dialog.
        var waited = 0.0
        for at in [0.0, 0.7, 2, 5] {
            try? await Task.sleep(for: .seconds(at - waited))
            waited = at
            switch at == 0 ? .pressEnter : Hosting.verdict(agent, expected: expected, screen: await screen()) {
            case .taken, .stop: return
            case .unsent: throw Failure(message: "It may not have been sent.")
            case .pressEnter:
                guard await run(["send-keys", "-t", pane.pane, "Enter"], nil).status == 0 else { throw Failure(message: "It's typed in but wasn't sent.") }
            }
        }
        if Hosting.verdict(agent, expected: expected, screen: await screen()) == .pressEnter { throw Failure(message: "It's typed in but wasn't sent.") }
    }


    /// Finds the tab by its tty. With text, pastes it and presses Enter a moment later: sent together, Claude Code
    /// reads the Enter as a line break and Codex folds it into the paste. Without, only presses Enter.
    static let ghosttyScript = """
    on run argv
        tell application "Ghostty"
            repeat with t in terminals
                if tty of t is (item 1 of argv) then
                    if (count of argv) > 1 then
                        input text (item 2 of argv) to t
                        delay 0.4
                    end if
                    send key "enter" to t
                    return
                end if
            end repeat
        end tell
        error "no terminal has that tty" number 1000
    end run
    """

    /// Ghostty's screen can't be read, so the session's transcript says whether the message went in: it grows the
    /// moment a prompt is taken. Enter is pressed once more only while it hasn't, when no turn can have opened a dialog.
    private static func ghostty(_ text: String, pid: Int, transcript: URL?) async throws(Failure) {
        guard let tty = TerminalFocus.host(of: pid)?.tty else { throw Failure(message: "The session's terminal tab could not be found.") }
        let size = { transcript.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int } }
        let before = size()
        try await script([tty, text])
        guard let before else { return }
        for attempt in 0..<2 {
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(250))
                if size() != before { return }
            }
            if attempt == 0, inFront(pid) { try await script([tty]) }
        }
        throw Failure(message: "It's typed in but may not have been sent.")
    }

    private static func script(_ arguments: [String]) async throws(Failure) {
        let run = await ProcessRunner.run("/usr/bin/osascript", ["-e", ghosttyScript] + arguments, timeout: 30)
        if run.launchError != nil { throw Failure(message: "The terminal could not be reached.") }
        guard run.status != 0 else { return }
        let message = String(data: run.errors, encoding: .utf8) ?? ""
        throw Failure(message: message.contains("-1743") ? TerminalFocus.automationDenied : "The session's terminal tab could not be found.")
    }
}

/// A store's way to type into terminals: what each running session's terminal takes, remembered for a moment so a
/// listing of every session doesn't walk the process table each time.
@MainActor final class TerminalTyper {
    private var known: [Int: (reach: TerminalTyping.Reach?, at: Date)] = [:]

    #if DEBUG
    /// Tests: these pids count as reachable, and what's typed to one is kept here instead.
    var staged: [Int: TerminalTyping.Reach]?
    private(set) var typed: [(pid: Int, text: String)] = []
    #endif

    func reach(_ live: LiveSession) -> TerminalTyping.Reach? {
        guard live.hosted == nil else { return nil }
        #if DEBUG
        if let staged { return staged[live.pid] }
        #endif
        if let found = known[live.pid], Date().timeIntervalSince(found.at) < 30 { return found.reach }
        let reach = TerminalTyping.reach(pid: live.pid)
        known = known.filter { Date().timeIntervalSince($0.value.at) < 300 }
        known[live.pid] = (reach, Date())
        return reach
    }

    func type(_ text: String, into live: LiveSession, transcript: URL? = nil) async throws(TerminalTyping.Failure) {
        #if DEBUG
        if staged != nil { typed.append((live.pid, text)); return }
        #endif
        try await TerminalTyping.type(text, into: live.pid, agent: live.provider == .codex ? .codex : .claude, transcript: transcript)
    }
}
