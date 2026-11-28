import Foundation
import SideACore
import SideAProtocol

/// Moving between conversations from the keyboard, and what the Session menu does to the open one.
extension SessionStore {
    /// Conversation ids in the order the list shows them, top to bottom.
    var orderedIDs: [String] {
        if searching { return results.map(\.id) }
        let done = Set(listed.finished.compactMap(\.finish.sessionID))
        let history = self.history()
        let rest = (history.recent + (desk.earlierOpen ? history.earlier : [])).flatMap { $0.rows.map(\.session.id) }.filter { !done.contains($0) }
        guard showsSections else { return rest }
        return runningIDs + visiblePins.map(\.id).filter { !done.contains($0) } + rest
    }

    /// The sessions at the top of the list (needs you, ready, working, idle and snoozed when unfolded), which ⌘1…⌘9 number.
    var runningIDs: [String] {
        guard showsSections, !searching else { return [] }
        let side = sidebar
        let listed = side.listed
        let running = (byProject(listed.working) + (idleOpen ? byProject(listed.idle) : [])).flatMap(\.sessions) + (desk.snoozedOpen ? side.asleep : [])
        return Self.unique(listed.waiting.compactMap(\.sessionID) + listed.finished.compactMap(\.finish.sessionID) + running.compactMap(\.sessionID))
    }

    /// Sessions waiting on the user, then the ones that finished and haven't been looked at.
    var attentionIDs: [String] {
        let listed = self.listed
        return Self.unique(listed.waiting.compactMap(\.sessionID) + listed.finished.compactMap(\.finish.sessionID))
    }

    /// The number a row shows while ⌘ is held, 1 to 9.
    func number(of id: String) -> Int? {
        runningIDs.prefix(9).firstIndex(of: id).map { $0 + 1 }
    }

    func jump(to number: Int) {
        let ids = runningIDs
        guard ids.indices.contains(number - 1) else { return }
        go(ids[number - 1])
    }

    /// The next session that needs the user after the open one, wrapping; nil when none does.
    func nextNeedingYou() {
        guard let id = Self.next(after: selectedID, in: attentionIDs) else { return }
        go(id)
    }

    func goBack() { if let id = desk.back() { open(id) } }
    func goForward() { if let id = desk.forward() { open(id) } }
    func goPrevious() { if let id = desk.previous { go(id) } }

    /// Opens a conversation and hands the keyboard to its composer: for a deliberate jump, not for arrowing past.
    func go(_ id: String) {
        open(id)
        desk.composerFocus += 1
    }

    /// The open conversation, once it is the one on screen.
    var openSession: SessionInfo? {
        guard let session = detail?.session, session.id == selectedID else { return nil }
        return session
    }

    var openLive: LiveSession? {
        guard let id = selectedID else { return nil }
        return liveByID[id] ?? live.first { $0.sessionID == id }
    }

    /// What the viewer's main button does: go to the tab a hosted session runs in, branch one running out of reach,
    /// or resume one that has ended.
    func showOrResume(_ session: SessionInfo) {
        let live = liveByID[session.id] ?? self.live.first { $0.sessionID == session.id }
        if let live, hostName(live) != nil { return show(live) }
        resume(session, fork: live != nil, in: resumeTerminal)
    }

    nonisolated static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// The id after `current` in `ids`, wrapping to the first; the first when `current` isn't among them. With only
    /// `current` in the list there is nowhere else to go.
    nonisolated static func next(after current: String?, in ids: [String]) -> String? {
        guard let first = ids.first else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return first }
        let next = ids[(index + 1) % ids.count]
        return next == current ? nil : next
    }

    /// A Codex conversation's file, in Codex's own folder or in Side A's for an account that isn't the default.
    /// Codex keeps no registry of running sessions, so a new one of these is how a new session shows up.
    nonisolated static func rollout(_ path: String) -> Bool {
        path.contains("/.codex/sessions/") || path.contains("/codex-conversations/sessions/")
    }
}
