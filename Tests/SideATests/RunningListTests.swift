import Foundation
@testable import SideA
import SideAProtocol
import Testing

@Test func worktreesGroupUnderTheirMainCheckout() {
    #expect(SessionStore.projectName(cwd: "/r/frisco-wt-l4", gitLink: "gitdir: /r/frisco/.git/worktrees/frisco-wt-l4\n") == "frisco")
    #expect(SessionStore.projectName(cwd: "/r/side-a/.claude/worktrees/lane", gitLink: "gitdir: /r/side-a/.git/worktrees/lane") == "side-a")
    #expect(SessionStore.projectName(cwd: "/r/apps", gitLink: nil) == "apps")
    #expect(SessionStore.projectName(cwd: "/r/sub", gitLink: "gitdir: ../.git/modules/sub") == "sub")
}

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
    #expect(abilities(nil, "busy").isSuperset(of: [.note, .interrupt]) && abilities("claude", "busy").contains(.note))
    #expect(!abilities("claude", "idle").contains(.note) && !abilities("codex", "busy").contains(.note) && !abilities("codex", "busy").contains(.interrupt))
    #expect(abilities("codex", "busy", hosted: "sa-app-1a2b").isSuperset(of: [.interrupt, .type]))
    #expect(!abilities("codex", "unknown", hosted: "sa-app-1a2b").contains(.interrupt))
    store.island.installed[.codex] = true
    #expect(abilities("codex", "busy").contains(.note) && abilities("codex", "busy").isDisjoint(with: [.interrupt, .followUp]))
    var threadless = LiveSession(pid: 9, sessionID: nil, name: nil, title: nil, cost: nil, cwd: "/r/app", status: "busy", waitingFor: nil, since: nil)
    threadless.agent = "codex"
    #expect(!commands.abilities(threadless, status: .working).contains(.note))
    var gemini = LiveSession(pid: 8, sessionID: nil, name: nil, title: nil, cost: nil, cwd: nil, status: "busy", waitingFor: nil, since: nil)
    gemini.agent = "gemini"
    #expect(gemini.provider == .claude)
}

@MainActor @Test func theUsualTerminalAsksEachProcessOnceAndSurvivesOneThatExits() throws {
    func live(_ pid: Int) throws -> LiveSession {
        try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: ["pid": pid, "status": "busy", "cwd": "/tmp"]))
    }
    var asked: [Int: Int] = [:]
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
