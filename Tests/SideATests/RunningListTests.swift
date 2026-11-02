import Foundation
@testable import SideA
import SideAProtocol
import Testing

@Test func worktreesGroupUnderTheirMainCheckout() {
    #expect(SessionStore.projectName(cwd: "/r/frisco-wt-l4", gitLink: "gitdir: /r/frisco/.git/worktrees/frisco-wt-l4\n") == "frisco")
    #expect(SessionStore.projectName(cwd: "/r/side-a/.claude/worktrees/lane", gitLink: "gitdir: /r/side-a/.git/worktrees/lane") == "side-a")
    // A plain checkout, or a folder that isn't in git, is its own project.
    #expect(SessionStore.projectName(cwd: "/r/apps", gitLink: nil) == "apps")
    #expect(SessionStore.projectName(cwd: "/r/sub", gitLink: "gitdir: ../.git/modules/sub") == "sub")
}

/// The rows offer what the phone offers: notes and stops by mail only for Claude with its hooks on, Esc for a hosted pane.
@MainActor @Test func runningRowsTakeWhatThePhoneTakes() throws {
    let store = AccountStore(demo: true)
    let commands = SessionCommands(store: store)
    func abilities(_ agent: String?, _ status: String, hosted: String? = nil) -> Set<SessionAbility> {
        var session = LiveSession(pid: 7, sessionID: "s", name: nil, title: nil, cost: nil, cwd: "/r/app", status: status, waitingFor: nil, since: nil)
        session.agent = agent; session.hosted = hosted
        return commands.abilities(session, status: commands.status(session))
    }
    #expect(!abilities("claude", "busy").contains(.note))
    store.island.installed[.claude] = true
    // Rows from before the bridge named agents are Claude's.
    #expect(abilities(nil, "busy").isSuperset(of: [.note, .interrupt]) && abilities("claude", "busy").contains(.note))
    #expect(!abilities("claude", "idle").contains(.note) && !abilities("codex", "busy").contains(.note) && !abilities("codex", "busy").contains(.interrupt))
    #expect(abilities("codex", "busy", hosted: "sa-app-1a2b").isSuperset(of: [.interrupt, .type]))
    #expect(!abilities("codex", "unknown", hosted: "sa-app-1a2b").contains(.interrupt))
    // Codex off its app server takes notes once the island's Codex hooks are on, by thread id: none without one.
    store.island.installed[.codex] = true
    #expect(abilities("codex", "busy").contains(.note) && abilities("codex", "busy").isDisjoint(with: [.interrupt, .followUp]))
    var threadless = LiveSession(pid: 9, sessionID: nil, name: nil, title: nil, cost: nil, cwd: "/r/app", status: "busy", waitingFor: nil, since: nil)
    threadless.agent = "codex"
    #expect(!commands.abilities(threadless, status: .working).contains(.note))
    // An agent this build doesn't know counts as Claude rather than spoiling the list.
    var gemini = LiveSession(pid: 8, sessionID: nil, name: nil, title: nil, cost: nil, cwd: nil, status: "busy", waitingFor: nil, since: nil)
    gemini.agent = "gemini"
    #expect(gemini.provider == .claude)
}

/// The live list's terminal is found asking each process once. The crash this replaces: a lazy compactMap asked twice,
/// the session's terminal had exited by the second ask, and the force-unwrap inside compactMap trapped.
@MainActor @Test func theUsualTerminalAsksEachProcessOnceAndSurvivesOneThatExits() throws {
    func live(_ pid: Int) throws -> LiveSession {
        try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: ["pid": pid, "status": "busy", "cwd": "/tmp"]))
    }
    var asked: [Int: Int] = [:]
    // pid 1 answers once, then is gone; pid 2 runs in iTerm.
    let host = { (pid: Int) -> TerminalFocus.Host? in
        asked[pid, default: 0] += 1
        if pid == 1 { return asked[pid] == 1 ? TerminalFocus.Host(app: "Unknown", bundleID: "com.example.other", pid: 9, tty: nil) : nil }
        return TerminalFocus.Host(app: "iTerm2", bundleID: TerminalApp.iterm.bundleID, pid: 10, tty: nil)
    }
    #expect(SessionStore.terminal(of: [try live(1), try live(2)], host: host) == .iterm)
    #expect(asked == [1: 1, 2: 1])
    asked = [:]
    #expect(SessionStore.terminal(of: [try live(1)], host: host) == nil)
    #expect(SessionStore.terminal(of: [try live(1)], host: host) == nil)
}
