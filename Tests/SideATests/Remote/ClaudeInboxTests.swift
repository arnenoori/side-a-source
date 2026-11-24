import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

@MainActor @Test func aClaudeInboxNobodyReadsIsTakenBackAndFlagged() async throws {
    let store = AccountStore(demo: true)
    let folder = store.root.appendingPathComponent("runtime/inbox")
    let live = try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: [
        "pid": Int(getpid()), "id": "s", "status": "idle", "cwd": "/tmp/app", "started": 1_700_000_000, "agent": "claude"]))
    store.sessions.live = [live]
    #expect(!store.remote.inbox.watching(live))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "1".write(to: folder.appendingPathComponent("\(getpid()).watcher"), atomically: true, encoding: .utf8)
    #expect(!store.remote.inbox.watching(live))
    #expect(store.remote.inbox.leave("hello", to: live))
    await eventually { store.remote.inbox.unsent(live) != nil }
    #expect(store.remote.inbox.unsent(live) == "hello")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(getpid()).json").path))
    #expect(WireBuilders.session(live, store: store, finished: []).flag?.kind == .unsent)
}
