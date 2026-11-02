import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

/// Stop hooks talk to a real IslandServer over its socket, so a release or follow-up is what the hook would read.
@MainActor private final class Hooks {
    let store: AccountStore
    var island: Island { store.island }
    private var fds: [String: Int32] = [:]

    init() {
        store = AccountStore(demo: true, root: FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))"))
        store.island.keepsFinished = { true }
        store.island.start()
    }

    /// A Stop hook arriving.
    func stop(_ session: String, waits: Bool = true, agent: String = "claude") throws {
        let path = store.root.appendingPathComponent("runtime/island.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(connected == 0)
        fds[session] = fd
        let message = try JSONSerialization.data(withJSONObject: ["v": 1, "agent": agent, "slot": "mac", "wait": waits, "request": [
            "hook_event_name": "Stop", "session_id": session, "cwd": "/tmp/app", "last_assistant_message": "done",
        ]]) + Data("\n".utf8)
        _ = message.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// What the hook for `session` has been told, once it has.
    func answer(_ session: String) async throws -> String? {
        let fd = try #require(fds[session])
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<300 {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let object = try JSONSerialization.jsonObject(with: Data(buffer[0..<count]).split(separator: 10).first ?? Data()) as? [String: Any]
                return object?["followUp"] as? String ?? ""
            }
            if count == 0 { return nil }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the hook for \(session) heard nothing")
        return nil
    }

    func settle(_ done: () -> Bool) async throws {
        for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done())
    }
}

@MainActor private final class Heard: Island.Watcher {
    var reasons: [Island.ReadyReason] = []
    var queued: [(String, Island.QueuedFollowUp)] = []
    func requestAdded(_ item: Island.Pending) {}
    func requestResolved(_ item: Island.Pending, by: Island.Resolution, answer: IslandAnswer?) {}
    func readyChanged(from old: [Island.Ready], to new: [Island.Ready], reason: Island.ReadyReason) {
        if new.count < old.count { reasons.append(reason) }
    }
    func queued(session: String, text: String, became outcome: Island.QueuedFollowUp) { queued.append((text, outcome)) }
}

@MainActor struct IslandFinishedTests {
    /// ⌃⌥G used to take the row and leave its hook waiting: the phone offered a follow-up that was then refused.
    @Test func goingToAFinishedSessionEndsItsStopHook() async throws {
        let hooks = Hooks()
        try hooks.stop("s1")
        try await hooks.settle { hooks.island.hasWaiter("s1") }
        let row = try #require(hooks.island.ready.first)
        #expect(hooks.island.canReply(row))
        hooks.island.go()
        #expect(try await hooks.answer("s1") == "")
        #expect(!hooks.island.hasWaiter("s1") && hooks.island.ready.isEmpty)
        #expect(hooks.island.remoteFollowUp(session: "s1", turnID: nil, text: "next") == .noWaiter)
    }

    /// Finishing again used to leave `.expired` set for the next change, whatever made it.
    @Test func aRowSaysWhyItLeftAndNotWhyTheOneBeforeIt() async throws {
        let hooks = Hooks()
        let heard = Heard()
        hooks.island.watcher = heard
        try hooks.stop("s1")
        try await hooks.settle { hooks.island.hasWaiter("s1") }
        hooks.island.go()
        #expect(heard.reasons == [.released])
        try hooks.stop("s2")
        try await hooks.settle { hooks.island.hasWaiter("s2") }
        hooks.island.resumed(["s2"])
        #expect(try await hooks.answer("s2") == "")
        #expect(heard.reasons == [.released, .resumed])
    }

    @Test func aReplyWakesTheHookWithItsText() async throws {
        let hooks = Hooks()
        try hooks.stop("s1")
        try await hooks.settle { hooks.island.hasWaiter("s1") }
        #expect(hooks.island.remoteFollowUp(session: "s1", turnID: nil, text: "next task") == .sent)
        #expect(try await hooks.answer("s1") == "next task")
    }

    @Test func aQueuedFollowUpGoesWhenTheTurnEnds() async throws {
        let hooks = Hooks()
        let heard = Heard()
        hooks.island.watcher = heard
        #expect(hooks.island.queue("s1", "after this"))
        try hooks.stop("s1")
        #expect(try await hooks.answer("s1") == "after this")
        #expect(hooks.island.queued["s1"] == nil)
        #expect(heard.queued.map(\.1) == [.delivered])
    }

    /// A Stop hook that doesn't wait can't take it, and saying nothing would leave the phone showing Queued for good.
    @Test func aTurnEndingWithAHookThatCantWaitDropsWhatWasQueued() async throws {
        let hooks = Hooks()
        let heard = Heard()
        hooks.island.watcher = heard
        #expect(hooks.island.queue("c1", "after this"))
        try hooks.stop("c1", waits: false)
        try await hooks.settle { hooks.island.queued["c1"] == nil }
        #expect(heard.queued.map(\.0) == ["after this"] && heard.queued.map(\.1) == [.dropped(.cannotWait)])
    }

    @Test func aSessionThatStaysGoneDropsWhatWasQueued() {
        let island = AccountStore(demo: true).island
        let heard = Heard()
        island.watcher = heard
        #expect(island.queue("s1", "one") && island.queue("s1", "two") && island.queue("s2", "kept"))
        let start = Date()
        island.liveSessions(["s2"], now: start)
        // A blip off the list isn't the session ending.
        island.liveSessions(["s1", "s2"], now: start + 30)
        island.liveSessions(["s2"], now: start + 40)
        island.liveSessions(["s2"], now: start + 40 + Island.queuedGrace - 1)
        #expect(island.queued["s1"]?.count == 2 && heard.queued.isEmpty)
        island.liveSessions(["s2"], now: start + 40 + Island.queuedGrace)
        #expect(island.queued["s1"] == nil && island.queued["s2"] == [.waiting("kept")])
        #expect(heard.queued.map(\.0) == ["one", "two"] && heard.queued.allSatisfy { $0.1 == .dropped(.sessionEnded) })
    }

    /// What a phone queued is only as good as what it proved: a removed phone's goes, and so does one the session has outgrown.
    @Test func aQueuedFollowUpOutlivesNeitherItsPhoneNorItsProof() async throws {
        let hooks = Hooks()
        let heard = Heard()
        hooks.island.watcher = heard
        let phone = Island.QueuedFollowUp.Origin(device: "d1", proven: .unlock), other = Island.QueuedFollowUp.Origin(device: "d2", proven: .biometric)
        #expect(hooks.island.queue("s1", "from the phone", from: phone) && hooks.island.queue("s1", "from the other", from: other) && hooks.island.queue("s2", "from the Mac"))
        hooks.island.dropQueued(device: "d1")
        #expect(hooks.island.queued["s1"] == [.waiting("from the other", from: other)] && hooks.island.queued["s2"] == [.waiting("from the Mac")])
        #expect(heard.queued.map(\.0) == ["from the phone"] && heard.queued.map(\.1) == [.dropped(.revoked)])

        // A session whose mode can't be read asks Face ID: an unlock's proof is too little, Face ID's enough.
        #expect(hooks.island.queue("s3", "unlocked", from: phone) && hooks.island.queue("s3", "faced", from: other))
        try hooks.stop("s3")
        #expect(try await hooks.answer("s3") == "faced")
        #expect(heard.queued.map(\.1).contains(.dropped(.outranked)) && heard.queued.map(\.0).contains("unlocked") && !heard.queued.contains { $0.0 == "unlocked" && $0.1 == .delivered })
    }

    /// A file from before follow-ups said who sent them can't say who authorized them, so none of it is sent.
    @Test func anOldQueueFileIsDropped() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidea-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("queued-followups.json")
        try JSONEncoder().encode(["s1": ["after this"]]).write(to: file)
        let island = AccountStore(demo: true).island
        island.queuedFile = file
        island.loadQueued()
        #expect(island.queued.isEmpty && !FileManager.default.fileExists(atPath: file.path))
    }

    /// The Stop hook outlasts the app, so what's queued does too, only readable by this user, and gone once settled.
    @Test func theQueueSurvivesARelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidea-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("queued-followups.json")
        let before = AccountStore(demo: true).island
        before.queuedFile = file
        #expect(before.queue("s1", "after this"))
        let phone = Island.QueuedFollowUp.Origin(device: "d1", proven: .unlock)
        #expect(before.queue("s9", "from the phone", from: phone))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)

        let after = AccountStore(demo: true).island
        after.queuedFile = file
        after.loadQueued()
        #expect(after.queued["s1"] == [.waiting("after this")] && after.queued["s9"] == [.waiting("from the phone", from: phone)])
        // It keeps its promise after the relaunch too: lost means reported, not forgotten.
        let heard = Heard()
        after.watcher = heard
        let start = Date()
        after.liveSessions([], now: start)
        after.liveSessions([], now: start + Island.queuedGrace)
        #expect(heard.queued.map(\.1) == [.dropped(.sessionEnded), .dropped(.sessionEnded)])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Old phones must keep decoding the event and the push that say so.
    @Test func aDropIsSaidInWordsEveryPhoneDecodes() throws {
        let event = ServerEvent.finishedResolve(sessionID: "s1", reason: Island.ReadyReason.queueDropped.rawValue)
        let decoded = try JSONDecoder().decode(ServerEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
        let payload = RemotePushPayload.queuedDropped(session: "s1", title: "App", text: "after this", mac: "m", now: 1)
        #expect(payload.t == "health" && payload.sid == "s1" && payload.body?.contains("after this") == true)
    }
}
