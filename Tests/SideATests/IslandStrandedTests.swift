import Foundation
@testable import SideA
import SideACore
import Testing

@MainActor private final class Heard: Island.Watcher {
    var queued: [(String, Island.QueuedFollowUp)] = []
    func requestAdded(_ item: Island.Pending) {}
    func requestResolved(_ item: Island.Pending, by: Island.Resolution, answer: IslandAnswer?) {}
    func readyChanged(from old: [Island.Ready], to new: [Island.Ready], reason: Island.ReadyReason) {}
    func queued(session: String, text: String, became outcome: Island.QueuedFollowUp) { queued.append((text, outcome)) }
}

private func session(_ id: String, status: String = "idle", running tasks: Int = 0) -> LiveSession {
    var live = LiveSession(pid: 4242, sessionID: id, name: nil, title: nil, cost: nil, cwd: "/tmp", status: status, waitingFor: nil, since: 0)
    live.agent = "claude"
    live.backgroundTasks = (0..<tasks).map { LiveSession.BackgroundTask(id: "t\($0)", type: "shell", status: "running", description: nil) }
    return live
}

@MainActor private func mailText(_ store: AccountStore) -> String? {
    let file = store.root.appendingPathComponent("runtime/mail/4242.json")
    guard let data = try? Data(contentsOf: file) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String
}

@MainActor struct IslandStrandedTests {
    private func fresh() -> (AccountStore, Island, Heard) {
        let store = AccountStore(demo: true, root: FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))"))
        let heard = Heard()
        store.island.watcher = heard
        return (store, store.island, heard)
    }

    @Test func aTurnPausedOnBackgroundWorkGetsItsQueueAsOneNote() {
        let (store, island, heard) = fresh()
        #expect(island.queue("s1", "first") && island.queue("s1", "second"))
        let start = Date()
        island.observeLive([session("s1", running: 8)], now: start)
        island.observeLive([session("s1", running: 8)], now: start + Island.pausedAfter - 1)
        #expect(island.queued["s1"]?.count == 2 && heard.queued.isEmpty)
        island.observeLive([session("s1", running: 8)], now: start + Island.pausedAfter)
        #expect(island.queued["s1"] == nil)
        #expect(mailText(store) == "first\n\nsecond")
        #expect(heard.queued.map(\.0) == ["first", "second"] && heard.queued.allSatisfy { $0.1 == .delivered })
    }

    @Test func aQueueFilledWhileOnlyBackgroundWorkRunsStillGoes() {
        let (store, island, _) = fresh()
        let start = Date()
        island.observeLive([session("s1", running: 2)], now: start)
        #expect(island.queue("s1", "later"))
        island.observeLive([session("s1", running: 2)], now: start + 10)
        island.observeLive([session("s1", running: 2)], now: start + 10 + Island.pausedAfter)
        #expect(island.queued["s1"] == nil && mailText(store) == "later")
    }

    @Test func aSessionThatWorksAgainKeepsItsQueue() {
        let (_, island, heard) = fresh()
        #expect(island.queue("s1", "wait"))
        let start = Date()
        island.observeLive([session("s1", running: 1)], now: start)
        island.observeLive([session("s1", status: "working", running: 1)], now: start + 4)
        island.observeLive([session("s1", running: 1)], now: start + 5)
        island.observeLive([session("s1", running: 1)], now: start + 5 + Island.pausedAfter - 1)
        #expect(island.queued["s1"]?.count == 1 && heard.queued.isEmpty)
    }

    @Test func aQueueLeftWithNoHookToTakeItIsGivenBack() {
        let (_, island, heard) = fresh()
        #expect(island.queue("s1", "held across the update"))
        let start = Date()
        island.observeLive([session("s1")], now: start)
        island.observeLive([session("s1")], now: start + Island.strandedAfter - 1)
        #expect(island.queued["s1"]?.count == 1)
        island.observeLive([session("s1")], now: start + Island.strandedAfter)
        #expect(island.queued["s1"] == nil)
        #expect(heard.queued.map(\.1) == [.dropped(.cannotWait)])
    }

    @Test func aQueuePersistedBeforeARelaunchIsReleasedAfterIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))")
        let beforeStore = AccountStore(demo: true, root: root)
        let before = beforeStore.island
        let file = root.appendingPathComponent("runtime/queued-followups.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        before.queuedFile = file
        #expect(before.queue("s1", "survives"))
        let afterStore = AccountStore(demo: true, root: root)
        let after = afterStore.island
        let heard = Heard()
        after.watcher = heard
        after.queuedFile = file
        after.loadQueued()
        #expect(after.queued["s1"]?.count == 1)
        let start = Date()
        after.observeLive([session("s1", running: 3)], now: start)
        after.observeLive([session("s1", running: 3)], now: start + Island.pausedAfter)
        #expect(after.queued["s1"] == nil)
        #expect(heard.queued.map(\.1) == [.delivered])
    }
}
