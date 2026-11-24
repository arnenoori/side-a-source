import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

/// A Codex session outside Codex's shared server has no turn id; its rollout's newest typed message, as the bridge
/// reads it, is what says someone wrote to it.
private func codex(prompt: Double?) throws -> LiveSession {
    var object: [String: Any] = ["pid": Int(getpid()), "id": "thread-1", "status": "idle", "cwd": "/tmp/app", "started": 1_700_000_000, "agent": "codex"]
    object["promptAt"] = prompt
    return try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: object))
}

@MainActor
@Test func aMessageTypedAtACodexTerminalWakesItsSnoozeOnce() throws {
    let store = AccountStore(demo: true)
    let before = Date().timeIntervalSince1970 - 600
    var live = try codex(prompt: before)
    store.sessions.live = [live]
    let row = WireBuilders.session(live, store: store, finished: [])
    #expect(row.turnID == nil, "outside the shared server it names no turn")
    store.remote.snoozes.snooze(row, .threeHours, until: Date().timeIntervalSince1970 + 3 * 3600)
    // The message that was already there when it was snoozed, and the agent's own output after it, wake nothing.
    #expect(WireBuilders.session(live, store: store, finished: []).snooze != nil)
    live = try codex(prompt: before)
    #expect(WireBuilders.session(live, store: store, finished: []).snooze != nil)

    live = try codex(prompt: Date().timeIntervalSince1970 + 1)
    store.sessions.live = [live]
    #expect(WireBuilders.session(live, store: store, finished: []).snooze == nil, "a new typed message wakes it")
    #expect(store.remote.snoozes.entries.isEmpty)
    #expect(WireBuilders.session(live, store: store, finished: []).snooze == nil, "once, and it stays awake")
}

@MainActor
@Test func aRestartDoesNotWakeASnoozeForAnOldCodexMessage() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("snoozes-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let now = Date()
    let row = RemoteSession(id: "s1", agent: .codex, title: "Fix", project: "app", status: .idle)
    Snoozes(url: url).snooze(row, .hour, until: now.timeIntervalSince1970 + 3600, now: now)
    let restarted = Snoozes(url: url)
    #expect(restarted.current(row, prompt: now.timeIntervalSince1970 - 5, now: now) != nil)
    #expect(restarted.current(row, prompt: nil, now: now) != nil)
    #expect(restarted.current(row, prompt: now.timeIntervalSince1970 + 5, now: now) == nil)
}
