import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import SideA
import SideACore
import SideAProtocol
import Testing

/// A demo store keeps everything in its temp folder; the scene is set by hand, with no hook server or tmux.
@MainActor
private final class Scene {
    let store = AccountStore(demo: true)

    /// A signed caller, for what these tests are about; SignedRoutesTests checks real signatures. Face ID on a start
    /// still reaches the scene's missing server, as `settings` does.
    init() {
        store.remote.confirmCheck = { _, _, purpose, _, needs in purpose == .settings && needs == .biometric ? RemoteRoutes.notReady : nil }
    }

    func live(pid: Int, id: String?, status: String, agent: String = "claude", hosted: String? = nil) throws {
        var object: [String: Any] = ["pid": pid, "status": status, "cwd": "/tmp/app", "started": 1_700_000_000, "agent": agent]
        if let id { object["id"] = id }
        if let hosted { object["hosted"] = hosted }
        store.sessions.live.append(try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    @discardableResult
    func pending(session: String, pid: Int, command: String) throws -> Island.Pending {
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "agent": "claude", "pid": pid, "slot": "mac", "request": [
            "session_id": session, "tool_name": "Bash", "cwd": "/tmp/app", "tool_input": ["command": command],
        ]])
        let item = Island.Pending(connection: nil, request: try #require(IslandRequest(message: data)), title: "app", account: nil, handBackAt: nil)
        store.island.pending.append(item)
        return item
    }

    func call(_ method: String, _ path: String, _ body: Any? = nil, headers: [(String, String)] = [], device: String? = "d1") async throws -> (Int, [String: Any]) {
        let data = try body.map { try ($0 as? Data) ?? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let parts = URLComponents(string: "/" + path)
        let query = Dictionary((parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let route = (parts?.path ?? path).split(separator: "/").map(String.init)
        let request = HTTPRequest(method: method, target: "/" + path, path: route, query: query,
                                  headers: HTTPHeaders(headers), body: data)
        let response = await RemoteRoutes.route(request, RemoteServer.Caller(device: device, connection: 1), store.remote)
        let object = response.body.isEmpty ? [:] : try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        return (response.status, object)
    }

    func mail(_ pid: Int) -> [String: String]? {
        let url = store.root.appendingPathComponent("runtime/mail/\(pid).json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }
}

private func code(_ object: [String: Any]) -> String? { (object["error"] as? [String: Any])?["code"] as? String }
private func hint(_ object: [String: Any]) -> String? { ((object["error"] as? [String: Any])?["details"] as? [String: String])?["hint"] }

/// A hosted pane reaches the phone as it starts and ends, in the event stream and in a snapshot.
@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func hostedSessionsAreRecordedAndInTheSnapshot() async throws {
    let scene = Scene()
    let fixture = try HostedFixture()
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge)
    scene.store.hosted = hosted
    await hosted.install()
    let queue = DispatchQueue(label: "test.hub")
    let hub = EventHub(queue: queue, epoch: "e1", snapshot: { { seq, epoch in StateSnapshot(seq: seq, epoch: epoch) } }, hello: {
        Hello(app: "", build: 0, mac: MacInfo(id: "", name: ""), capabilities: [], epoch: "e1", serverTime: 0, endpoints: Endpoints(tailnet: ""), keyID: "")
    })
    let events = RemoteEvents(store: scene.store, hub: hub, queue: queue)
    events.start()
    hosted.onRefresh = { events.hostedChanged() }
    defer { events.stop() }
    func soon(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(100)) }
        return condition()
    }
    do {
        let name = try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .new(model: nil)))
        #expect(await soon { hub.recorded(after: 0).contains { if case .hostedUpsert(let session) = $0 { session.name == name } else { false } } })
        #expect(events.snapshot()(hub.seq, "e1").hosted.map(\.name) == [name])
        try await hosted.end(name)
        await hosted.refresh()
        #expect(await soon { hub.recorded(after: 0).contains { if case .hostedRemove(name) = $0 { true } else { false } } })
        #expect(events.snapshot()(hub.seq, "e1").hosted.isEmpty)
    } catch { Issue.record(error) }
    await fixture.cleanUp()
}

@MainActor @Test func theApprovalsLogPagesNewestFirstAndOutlivesARelaunch() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("approvals-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("approvals.json")
    let now = Date()
    let log = ApprovalsLog(url: url)
    let asked = RequestSummary(tool: "Bash", headline: "Run a command", sessionTitle: "Fix the build", agent: .claude)
    log.add(.init(resolution: RequestResolution(requestID: "old", by: .mac, answer: .allow, at: now.timeIntervalSince1970 - 31 * 86_400), request: asked),
            now: now)
    for index in 0..<60 {
        log.add(.init(resolution: RequestResolution(requestID: String(format: "r%02d", index), by: .device, deviceID: "d1", deviceName: "iPhone",
                                                    answer: .deny, at: now.timeIntervalSince1970 - Double(60 - index)), request: asked), now: now)
    }
    let first = ApprovalsLog(url: url).page(after: nil, now: now)
    #expect(first.approvals.count == 50 && first.approvals.first?.resolution.requestID == "r59" && first.approvals.last?.resolution.requestID == "r10")
    #expect(first.approvals.first?.request == asked)
    let second = ApprovalsLog(url: url).page(after: first.next, now: now)
    #expect(second.approvals.map(\.resolution.requestID) == (0..<10).reversed().map { String(format: "r%02d", $0) } && second.next == nil)

    let scene = Scene()
    // A request answered while Remote records lands in the log with what it asked.
    let events = RemoteEvents(store: scene.store, hub: EventHub(queue: DispatchQueue(label: "test.hub"), epoch: "e1",
        snapshot: { { seq, epoch in StateSnapshot(seq: seq, epoch: epoch) } },
        hello: { Hello(app: "", build: 0, mac: MacInfo(id: "", name: ""), capabilities: [], epoch: "e1", serverTime: 0, endpoints: Endpoints(tailnet: ""), keyID: "") }),
        queue: DispatchQueue(label: "test.events"))
    events.start()
    defer { events.stop() }
    let item = try scene.pending(session: "s1", pid: 4242, command: "npm test")
    events.requestResolved(item, by: .terminal, answer: nil)
    let (status, page) = try await scene.call("GET", "v1/approvals")
    let row = (page["approvals"] as? [[String: Any]])?.first { ($0["resolution"] as? [String: Any])?["requestID"] as? String == item.id.uuidString.lowercased() }
    #expect(status == 200 && (row?["request"] as? [String: Any])?["tool"] as? String == "Bash" && (row?["request"] as? [String: Any])?["sessionTitle"] as? String == "app")
    scene.store.remote.approvals.forget()
}

/// Sparkle's check runs only where the app offers one, and the capability says so.
@MainActor @Test func anUpdateCheckGoesOnlyWhereTheAppOffersOne() async throws {
    let scene = Scene()
    #expect(try await scene.call("POST", "v1/update/check").0 == 503)
    #expect(!scene.store.remote.capabilities.contains(.updateCheck))
    var checked = 0
    scene.store.remote.checkForUpdates = { checked += 1; return true }
    #expect(try await scene.call("POST", "v1/update/check").0 == 202 && checked == 1)
    #expect(scene.store.remote.capabilities.contains(.updateCheck))
}

@MainActor @Test func worthIsTheReportsLastWeekAndMonthAtAPIPrices() throws {
    let today = MenuPlayer.day(0), old = MenuPlayer.day(-20)
    let rows = [TokenRow(date: today, model: "claude-opus-5-5", input: 1_000_000, output: 0, cacheWrite: 0, cacheRead: 0),
                TokenRow(date: old, model: "claude-opus-5-5", input: 1_000_000, output: 0, cacheWrite: 0, cacheRead: 0)]
    let worth = try #require(WireBuilders.worth(rows))
    #expect(worth.days7 > 0 && abs(worth.days30 - 2 * worth.days7) < 0.0001 && worth.currency == "USD")
    #expect(WireBuilders.worth([]) == nil)
    // Mac-wide: the demo's report, every account together.
    #expect(MacStats.state(AccountStore(demo: true)).worth != nil)
}

@MainActor @Test func helloWithoutATokenNamesNothingAboutTheMac() async throws {
    let scene = Scene()
    let (status, open) = try await scene.call("GET", "v1/hello", device: nil)
    #expect(status == 200 && open["paired"] == nil && open["protocolVersion"] as? Int == 1 && open["remoteOn"] != nil)
    #expect((open["mac"] as? [String: String]) == ["id": "", "name": ""] && (open["capabilities"] as? [String]) == [])
    #expect((open["endpoints"] as? [String: String]) == ["tailnet": ""] && open["keyID"] as? String == "")
    let (_, paired) = try await scene.call("GET", "v1/hello")
    #expect(paired["paired"] as? Bool == true && (paired["mac"] as? [String: String])?["name"]?.isEmpty == false)
    #expect((paired["capabilities"] as? [String])?.isEmpty == false)
}

@MainActor @Test func repliesFollowTheDeliveryTableForUnhostedClaude() async throws {
    let scene = Scene()
    scene.store.island.installed[.claude] = true
    try scene.live(pid: 101, id: "s-work", status: "busy")
    try scene.live(pid: 102, id: "s-wait", status: "busy")
    try scene.live(pid: 103, id: "s-idle", status: "idle")
    try scene.pending(session: "s-wait", pid: 102, command: "npm test")

    // Working: auto leaves a note, followUp queues until the turn ends, at most five.
    var (status, body) = try await scene.call("POST", "v1/sessions/s-work/reply", ["text": " check the logs ", "mode": "auto", "attachments": []])
    #expect(status == 200 && body["delivery"] as? String == "note" && body["sessionID"] as? String == "s-work")
    #expect(scene.mail(101) == ["kind": "note", "text": "check the logs"])
    for n in 1...5 {
        (status, body) = try await scene.call("POST", "v1/sessions/s-work/reply", ["text": "next \(n)", "mode": "followUp", "attachments": []])
        #expect(status == 200 && body["delivery"] as? String == "queued")
    }
    (status, body) = try await scene.call("POST", "v1/sessions/s-work/reply", ["text": "sixth", "mode": "followUp", "attachments": []])
    #expect(status == 409 && code(body) == "cannot_deliver" && hint(body) == "queueFull")
    #expect(scene.store.island.queued["s-work"]?.count == 5)

    // An open request blocks replies but takes a note; keys need a hosted session.
    (status, body) = try await scene.call("POST", "v1/sessions/s-wait/reply", ["text": "hi", "mode": "auto", "attachments": []])
    #expect(status == 409 && code(body) == "session_waiting")
    (status, body) = try await scene.call("POST", "v1/sessions/s-wait/reply", ["text": "", "mode": "keys", "keys": ["enter"], "attachments": []])
    #expect(status == 409 && code(body) == "not_hosted")

    (status, body) = try await scene.call("POST", "v1/sessions/s-idle/reply", ["text": "hi", "mode": "auto", "attachments": []])
    #expect(status == 409 && hint(body) == "continueOnPhone")
    (status, body) = try await scene.call("POST", "v1/sessions/nope/reply", ["text": "hi", "mode": "auto", "attachments": []])
    #expect(status == 404 && code(body) == "session_not_found")
    (status, body) = try await scene.call("POST", "v1/sessions/s-work/reply", ["text": "  ", "mode": "auto", "attachments": []])
    #expect(status == 422 && code(body) == "invalid_reply" && (body["error"] as? [String: Any])?["message"] as? String == "Write something to send.")
    (status, _) = try await scene.call("POST", "v1/sessions/s-work/reply", ["mode": "auto"])
    #expect(status == 400)
}

@MainActor @Test func interruptLeavesStopMailOnlyWhileWorkingAndMailCanBeTakenBack() async throws {
    let scene = Scene()
    scene.store.island.installed[.claude] = true
    try scene.live(pid: 201, id: "s-work", status: "busy")
    try scene.live(pid: 202, id: nil, status: "idle")

    let asked = Date().timeIntervalSince1970
    var (status, body) = try await scene.call("POST", "v1/sessions/s-work/interrupt")
    #expect(status == 200 && body["method"] as? String == "stop" && scene.mail(201) == ["kind": "stop"])
    let row = { WireBuilders.session(scene.store.sessions.live[0], store: scene.store, finished: []) }
    // Bounds rather than a window, which a loaded machine outlasts. A second's slack: file times can round down.
    let at = row().mail?.at ?? 0
    #expect(row().mail?.kind == .stop && at >= asked.rounded(.down) - 1 && at <= Date().timeIntervalSince1970 + 1)
    (status, _) = try await scene.call("DELETE", "v1/sessions/s-work/mail")
    #expect(status == 204 && scene.mail(201) == nil && row().mail == nil)
    // Nothing left to take back, or the session already took it: the phone says it was read.
    (status, body) = try await scene.call("DELETE", "v1/sessions/s-work/mail")
    #expect(status == 404 && code(body) == "not_found")
    (status, _) = try await scene.call("POST", "v1/sessions/s-work/reply", ["text": "check the logs", "mode": "note", "attachments": []])
    let file = scene.store.root.appendingPathComponent("runtime/mail/201.json")
    try #"{"kind": "note", "text": "check the logs", "since": 1}"#.write(to: file, atomically: true, encoding: .utf8)
    (status, body) = try await scene.call("DELETE", "v1/sessions/s-work/mail")
    #expect(status == 404 && code(body) == "not_found")

    // No conversation id yet: the session goes by its process and start time.
    (status, body) = try await scene.call("POST", "v1/sessions/pid-202-1700000000/interrupt", ["when": "nextStep"])
    #expect(status == 409 && code(body) == "cannot_deliver")
    (status, _) = try await scene.call("POST", "v1/sessions/s-work/interrupt", ["when": "later"])
    #expect(status == 400)
}

@MainActor @Test func requestsListAndFetchUncutAndAnswersSettleOnce() async throws {
    let scene = Scene()
    let item = try scene.pending(session: "s1", pid: 301, command: "npm test")
    let rid = item.id.uuidString.lowercased()

    var (status, body) = try await scene.call("GET", "v1/requests/\(rid)")
    #expect(status == 200 && body["id"] as? String == rid && body["truncated"] as? Bool == false)
    (status, body) = try await scene.call("GET", "v1/requests/\(UUID().uuidString)")
    #expect(status == 404 && code(body) == "request_not_found")

    let island = scene.store.island
    guard case .done(let resolution) = island.remoteAnswer(rid, .allow(confirmDestructive: false), device: "d1", name: "Pocket", proven: .unlock) else {
        Issue.record("Allow was refused"); return
    }
    #expect(resolution.by == .device && resolution.deviceName == "Pocket" && resolution.answer == .allow)
    #expect(island.pending.isEmpty)
    // The second answer learns who settled it.
    guard case .conflict(let first) = island.remoteAnswer(rid, .deny(message: nil), device: "d2", name: "Other", proven: .none) else {
        Issue.record("A second answer went through"); return
    }
    #expect(first.deviceID == "d1")

    // A destructive Allow needs Face ID's signature; the phone saying it confirmed counts for nothing.
    let rm = try scene.pending(session: "s1", pid: 301, command: "rm -rf build")
    #expect(island.remoteAnswer(rm.id.uuidString, .allow(confirmDestructive: true), device: "d1", name: "Pocket", proven: .unlock) == .refused("needs_confirm"))
    #expect(island.pending.count == 1)
    guard case .done = island.remoteAnswer(rm.id.uuidString, .allow(confirmDestructive: false), device: "d1", name: "Pocket", proven: .biometric) else {
        Issue.record("A confirmed destructive Allow was refused"); return
    }
}

@MainActor @Test func codexAndHostedSessionsTakeTheirOwnRows() async throws {
    let scene = Scene()
    scene.store.island.installed[.claude] = true
    scene.store.island.installed[.codex] = true
    try scene.live(pid: 401, id: "c-work", status: "busy", agent: "codex")
    try scene.live(pid: 402, id: "h-idle", status: "idle", hosted: "sa-app-1")

    // Codex: its Stop hook can't wait, so a reply is refused, not promised; a note goes to its mail hooks by thread id,
    // and a stop is refused (Codex runs the tool a stop's hook answer would hold back).
    var (status, body) = try await scene.call("POST", "v1/sessions/c-work/reply", ["text": "and the tests", "mode": "auto", "attachments": []])
    #expect(status == 409 && code(body) == "cannot_deliver" && scene.store.island.queued["c-work"] == nil)
    (status, body) = try await scene.call("POST", "v1/sessions/c-work/reply", ["text": "psst", "mode": "note", "attachments": []])
    #expect(status == 200 && body["delivery"] as? String == "note")
    let codexMail = scene.store.root.appendingPathComponent("runtime/mail/codex/c-work.json")
    #expect((try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: codexMail))) == ["kind": "note", "text": "psst"])
    (status, _) = try await scene.call("POST", "v1/sessions/c-work/interrupt")
    #expect(status == 409 && scene.mail(401) == nil)
    // Until the user trusts the mail hooks in Codex, notes are off and the row says why.
    scene.store.island.codexMail = "review"
    let row = try #require(WireBuilders.session(scene.store.sessions.live.first { $0.pid == 401 }!, store: scene.store, finished: []))
    #expect(!row.abilities.contains(.note) && row.reason(.note) == "Codex asks you to review Side A's two new hooks before notes reach it.")
    (status, body) = try await scene.call("POST", "v1/sessions/c-work/reply", ["text": "psst", "mode": "note", "attachments": []])
    #expect(status == 409 && code(body) == "cannot_deliver")
    scene.store.island.codexMail = "trusted"
    #expect(WireBuilders.session(scene.store.sessions.live.first { $0.pid == 401 }!, store: scene.store, finished: []).abilities.contains(.note))

    // A hosted idle session is typed into. This pane isn't one of HostedSessions', so the hosting lane refuses it.
    (status, body) = try await scene.call("POST", "v1/sessions/h-idle/reply", ["text": "go on", "mode": "auto", "attachments": []])
    #expect(status == 409 && code(body) == "not_hosted")
    (status, body) = try await scene.call("POST", "v1/sessions/h-idle/reply", ["text": "", "mode": "keys", "keys": ["esc"], "attachments": []])
    #expect(status == 409 && code(body) == "not_hosted")
    (status, body) = try await scene.call("POST", "v1/sessions/h-idle/reply", ["text": "", "mode": "keys", "attachments": []])
    #expect(status == 422 && code(body) == "invalid_reply")

    let wire = WireBuilders.session(scene.store.sessions.live[1], store: scene.store, finished: [])
    #expect(wire.hosted == "sa-app-1" && wire.abilities.isSuperset(of: [.type, .terminal]) && !wire.abilities.contains(.note))
    #expect(WireBuilders.session(scene.store.sessions.live[0], store: scene.store, finished: []).agent == .codex)
}

@MainActor @Test func aSessionRowCarriesTheSettingsTheBridgeRead() throws {
    let scene = Scene()
    let object: [String: Any] = ["pid": 301, "id": "s-set", "status": "busy", "cwd": "/tmp/app", "agent": "claude", "model": "claude-opus-5-5",
                                 "effort": "high", "mode": "acceptEdits", "fast": false, "contextPercent": 37, "cost": 1.25,
                                 "backgroundTasks": [["id": "b1", "type": "shell", "status": "running", "description": "npm run dev"],
                                                     ["id": "b2", "type": "subagent", "status": "completed"]]]
    scene.store.sessions.live.append(try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: object)))
    try scene.live(pid: 302, id: "s-bare", status: "idle")
    let wire = WireBuilders.session(scene.store.sessions.live[0], store: scene.store, finished: [])
    #expect(wire.settings == SessionSettings(model: "claude-opus-5-5", effort: .init(rawValue: "high"), mode: .acceptEdits, fast: false))
    #expect(wire.model == "claude-opus-5-5" && wire.effort == "high" && wire.contextPercent == 37 && wire.cost == 1.25 && wire.backgroundTasks == 1)
    // A session the bridge read nothing about says nothing, rather than "default".
    let bare = WireBuilders.session(scene.store.sessions.live[1], store: scene.store, finished: [])
    #expect(bare.settings == nil && bare.contextPercent == nil && bare.backgroundTasks == nil)
}

@MainActor @Test func aDemoStoreKeepsRemoteOutOfTheLoginKeychain() throws {
    #expect(AccountStore(demo: true).remote.devices.devices.isEmpty)
    let memory = RemoteKeychain.inMemory()
    #expect(try memory.readDevices() == nil && memory.keychain == nil)
    try memory.writeDevices(Data("[]".utf8))
    #expect(try memory.readDevices() == Data("[]".utf8))
    #expect(try memory.identity() == nil)
}

/// A JPEG that says where it was taken.
private func photoWithGPS() throws -> Data {
    let source = try #require(CGImageSourceCreateWithData(TranscriptFixture.image as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let out = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N"],
                                                    kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"]] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return out as Data
}

@MainActor @Test func uploadsDropWhereAPhotoWasTakenAndReachTheSessionAsPaths() async throws {
    let scene = Scene()
    scene.store.island.installed[.claude] = true
    try scene.live(pid: 501, id: "s-work", status: "busy")
    let photo = try photoWithGPS()
    let source = try #require(CGImageSourceCreateWithData(photo as CFData, nil))
    #expect((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyGPSDictionary] != nil)

    var (status, body) = try await scene.call("POST", "v1/uploads", photo)
    #expect(status == 201 && body["mime"] as? String == "image/jpeg", "\(status) \(body)")
    let id = try #require(body["id"] as? String)
    let path = try #require(body["path"] as? String)
    #expect(path.hasPrefix(scene.store.root.path + "/runtime/uploads/"))
    let stored = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(stored, 0, nil) as? [CFString: Any] ?? [:]
    #expect(properties[kCGImagePropertyGPSDictionary] == nil && (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] == nil)
    #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)

    (status, body) = try await scene.call("POST", "v1/uploads", Data("not a photo".utf8))
    #expect(status == 415 && code(body) == "unsupported_media")

    // Unhosted, the path goes into the note under the text.
    (status, body) = try await scene.call("POST", "v1/sessions/s-work/reply", ["text": "like this", "mode": "note", "attachments": [id]])
    #expect(status == 200 && scene.mail(501)?["text"] == "like this\n" + path)
    (status, body) = try await scene.call("POST", "v1/sessions/s-work/reply", ["text": "", "mode": "note", "attachments": ["0123456789ab"]])
    #expect(status == 422 && code(body) == "invalid_reply")

    // A week later it's gone.
    try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: path)
    RemoteUploads.sweep(root: scene.store.root)
    #expect(!FileManager.default.fileExists(atPath: path) && RemoteUploads.paths([id], root: scene.store.root) == nil)
}

@MainActor @Test func projectsComeFromRecentSessionsAndHostedNeedsTmux() async throws {
    let scene = Scene()
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sidea-projects-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = folder.appendingPathComponent("app")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = ["-C", project.path, "init", "-q", "-b", "main"]
    try git.run()
    git.waitUntilExit()
    let home = folder.appendingPathComponent("home")
    try TranscriptFixture.write(TranscriptFixture.lines(session: "p1", cwd: project.path, day: TranscriptFixture.today), session: "p1", home: home)
    let index = home.appendingPathComponent("Side A")
    TranscriptFixture.index(home: home, root: index)
    scene.store.sessions.transcriptSource = (home: home, bridge: TranscriptFixture.bridge, python: "/usr/bin/python3", root: index)

    var (status, body) = try await scene.call("GET", "v1/projects")
    let projects = try #require(body["projects"] as? [[String: Any]])
    #expect(status == 200 && projects.count == 1)
    #expect(projects.first?["path"] as? String == project.path && projects.first?["name"] as? String == "app")
    #expect(projects.first?["gitRoot"] as? String == project.path && projects.first?["branch"] as? String == "main")

    // The demo has no tmux server.
    (status, body) = try await scene.call("POST", "v1/hosted", ["cwd": project.path, "agent": "claude", "worktree": false, "attachments": [], "fork": false])
    #expect(status == 503 && code(body) == "tmux_missing")
    (status, _) = try await scene.call("GET", "v1/hosted")
    #expect(status == 503)
    #expect(RemoteProjects.pin("Work (2) Account") == "work-2-account" && RemoteProjects.pin("…") == "account")
}

@MainActor @Test func setupAndOptionsDescribeTheMacAndTheUsersOwnCommands() async throws {
    let scene = Scene()
    var (status, body) = try await scene.call("GET", "v1/setup")
    #expect(status == 200 && body["tmux"] as? String == "missing" && body["relay"] as? String == "unregistered")
    #expect((body["push"] as? [String: Any])?["registered"] as? Bool == false && body["onPower"] == nil)
    (status, body) = try await scene.call("GET", "v1/options")
    let agents = try #require(body["agents"] as? [[String: Any]])
    #expect(status == 200 && agents.map { $0["agent"] as? String } == ["claude", "codex"])

    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sidea-options-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    for folder in ["commands/frontend", "skills/ship", "skills/.hidden", "skills/.system/imagegen", "prompts"] {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    try "---\nname: tidy\ndescription: \"Tidy the imports\"\n---\nBody\n".write(to: home.appendingPathComponent("commands/tidy.md"), atomically: true, encoding: .utf8)
    try "# Review the UI\n\nSteps".write(to: home.appendingPathComponent("commands/frontend/review.md"), atomically: true, encoding: .utf8)
    try "---\ndescription: Ship it\n---\n".write(to: home.appendingPathComponent("skills/ship/SKILL.md"), atomically: true, encoding: .utf8)
    try "Explain the diff".write(to: home.appendingPathComponent("prompts/explain.md"), atomically: true, encoding: .utf8)
    try "model = \"gpt-6-astra\"\nmodel_reasoning_effort = \"high\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    let claude = RemoteOptions.claudeCommands(home: home)
    #expect(claude.first?.id == "/compact")
    #expect(claude.suffix(3).map(\.id) == ["/frontend:review", "/tidy", "/ship"])
    #expect(claude.suffix(3).map(\.label) == ["Review the UI", "Tidy the imports", "Ship it"])
    try "---\ndescription: Make an image\n---\n".write(to: home.appendingPathComponent("skills/.system/imagegen/SKILL.md"), atomically: true, encoding: .utf8)
    // Codex runs skills as $name: the user's own, then the ones it ships; never a dot folder itself.
    #expect(RemoteOptions.codexCommands(home: home).suffix(3) == [.init(id: "/prompts:explain", label: "Explain the diff"),
                                                                   .init(id: "$ship", label: "Ship it"), .init(id: "$imagegen", label: "Make an image")])
    #expect(!RemoteOptions.claudeCommands(home: home).contains { $0.id.contains("imagegen") || $0.id.contains("hidden") })
    // Without Codex to ask, the configured model, with no efforts to offer.
    #expect(await RemoteOptions.codexModels(codex: nil, home: home).map(\.id) == ["gpt-6-astra"])
    let models = RemoteOptions.claudeModels(used: ["claude-opus-5-5", "gpt-6-astra", "<synthetic>", "claude-opus-5-5", "claude-opus-4-5-20251101"])
    #expect(models.map(\.id) == ["opus", "sonnet", "haiku", "claude-opus-5-5", "claude-opus-4-5-20251101"] && models[3].title == "Opus 5.5")
    #expect(models[3].efforts == [.auto, .low, .medium, .high, .xhigh, .max] && models[4].efforts == [.auto, .low, .medium, .high])

    // Codex's own catalog: hidden models left out, none and minimal never offered, its own default.
    let catalog = try JSONDecoder().decode(RemoteOptions.CodexCatalog.self, from: Data(#"""
    {"models": [{"slug": "gpt-6.1-sol", "display_name": "GPT-6.1-Sol", "default_reasoning_level": "low", "visibility": "list",
                 "supports_reasoning_effort_updates": true, "supported_reasoning_levels": [{"effort": "minimal"}, {"effort": "low"}, {"effort": "ultra"}]},
                {"slug": "gpt-reserve", "visibility": "hide", "supported_reasoning_levels": [{"effort": "low"}]}]}
    """#.utf8))
    let codex = RemoteOptions.codexOptions(catalog)
    #expect(codex == [ModelOption(id: "gpt-6.1-sol", title: "GPT-6.1-Sol", agent: .codex, efforts: [.low, .ultra], defaultEffort: .low,
                                  canChangeEffortMidSession: true)])
    let options = [AgentOptions(agent: .claude, installed: true, models: models), AgentOptions(agent: .codex, installed: true, models: codex)]
    #expect(RemoteOptions.refusal(effort: "max", model: "claude-opus-5-5", agent: .claude, options: options) == nil)
    #expect(RemoteOptions.refusal(effort: "max", model: "claude-opus-4-5-20251101", agent: .claude, options: options) != nil)
    #expect(RemoteOptions.refusal(effort: "ultra", model: nil, agent: .codex, options: options) == nil)
    #expect(RemoteOptions.refusal(effort: "bogus", model: "gpt-6.1-sol", agent: .codex, options: options) != nil)
    #expect(RemoteOptions.refusal(effort: "high", model: "gpt-unknown", agent: .codex, options: options) != nil)
}

/// POST /v1/hosted end to end against real tmux and the fake Claude: what the phone sends becomes the
/// launcher's origin, idempotency key and first prompt, a retried request gets the same session, and DELETE ends it.
/// (GET needs the running server's event hub, which this scene doesn't start.)
@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func aPhoneStartsAHostedSessionOnceAndEndsIt() async throws {
    let scene = Scene()
    let fixture = try HostedFixture()
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge)
    scene.store.hosted = hosted
    await hosted.install()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let home = fixture.base.appendingPathComponent("transcripts")
    try TranscriptFixture.write(TranscriptFixture.lines(session: "p1", cwd: fixture.project.path, day: TranscriptFixture.today), session: "p1", home: home)
    let index = home.appendingPathComponent("Side A")
    TranscriptFixture.index(home: home, root: index)
    scene.store.sessions.transcriptSource = (home: home, bridge: TranscriptFixture.bridge, python: "/usr/bin/python3", root: index)
    do {
        try #require(hosted.available)
        let start: [String: Any] = ["cwd": fixture.project.path, "agent": "claude", "worktree": false, "attachments": [], "fork": false,
                                    "prompt": "Fix the build; then run the tests"]
        var (status, body) = try await scene.call("POST", "v1/hosted", start, headers: [("Idempotency-Key", "K1")])
        #expect(status == 201 && body["agent"] as? String == "claude" && body["cwd"] as? String == fixture.project.path, "\(body)")
        let name = try #require(body["name"] as? String)
        #expect(name.hasPrefix("sa-app-"))
        let option = { (key: String) async in
            await HostedSessions.process(fixture.tmux, ["-S", fixture.socket, "show-options", "-v", "-t", "=\(name):", key], timeout: 5)
                .output.trimmingCharacters(in: .newlines)
        }
        #expect(await option("@sidea_origin") == "phone")
        #expect(await option("@sidea_key") == "phone-d1-K1")
        #expect(await waitUntil { (try? String(contentsOf: fixture.submitted.appendingPathExtension("args"), encoding: .utf8)) == "['--', 'Fix the build; then run the tests']" })

        // A retry with the same key is the same session, not a second one.
        (status, body) = try await scene.call("POST", "v1/hosted", start, headers: [("Idempotency-Key", "K1")])
        #expect(status == 201 && body["name"] as? String == name && hosted.sessions.count == 1)

        (status, _) = try await scene.call("DELETE", "v1/hosted/\(name)")
        #expect(status == 204)
        #expect(await waitUntil { await hosted.refresh(); return hosted.sessions.isEmpty })
        (status, body) = try await scene.call("DELETE", "v1/hosted/\(name)")
        #expect(status == 404 && code(body) == "not_found")

        // A mode goes on the command line. One that raises needs Face ID, signed over the start; one the agent can't
        // start in is refused before anything runs.
        var moded = start
        moded["prompt"] = nil
        moded["permissionMode"] = "acceptEdits"
        (status, body) = try await scene.call("POST", "v1/hosted", moded, headers: [("Idempotency-Key", "K2")])
        #expect(status == 201, "\(body)")
        #expect(await waitUntil { (try? String(contentsOf: fixture.submitted.appendingPathExtension("args"), encoding: .utf8)) == "['--permission-mode', 'acceptEdits']" })
        moded["permissionMode"] = "bypassPermissions"
        (status, body) = try await scene.call("POST", "v1/hosted", moded, headers: [("Idempotency-Key", "K3")])
        // The scene has no server to check a signature with, so the confirm step answers not_ready (RemoteServerTests
        // covers the signature); what matters is that nothing started.
        #expect(status == 503 && code(body) == "not_ready", "\(body)")
        moded["agent"] = "codex"
        moded["permissionMode"] = "plan"
        (status, body) = try await scene.call("POST", "v1/hosted", moded, headers: [("Idempotency-Key", "K4")])
        #expect(status == 422 && code(body) == "invalid_option", "\(body)")
        #expect(hosted.sessions.count == 1)

        // Trust and start: an unknown name is 404; a known one goes to the confirm step before any key.
        (status, body) = try await scene.call("POST", "v1/hosted/sa-nope/trust", headers: [("Idempotency-Key", "K5")])
        #expect(status == 404 && code(body) == "not_found", "\(body)")
        let running = try #require(hosted.sessions.first?.name)
        (status, body) = try await scene.call("POST", "v1/hosted/\(running)/trust", headers: [("Idempotency-Key", "K6")])
        #expect(status == 503 && code(body) == "not_ready", "\(body)")
    } catch { Issue.record(error) }
    await fixture.cleanUp()
}

@MainActor
private func waitUntil(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return false
}

/// A pairing the phone never used (its Keychain save failed, or it was killed first) goes after ten minutes; one that
/// made a single authenticated request stays, and so does every older device.
@MainActor @Test func aPairingThePhoneNeverUsedIsSweptAfterTenMinutes() async throws {
    let remote = Scene().store.remote
    func device(_ id: String, created: Double, seen: Double?) -> RemoteDevice {
        RemoteDevice(id: id, name: id, model: "iPhone", system: "iOS", app: "1.0", build: 1, hash: Data(count: 32),
                     secretHash: Data(count: 32).base64URL, created: created, lastSeen: seen)
    }
    let now = Date()
    for device in remote.devices.devices { try remote.devices.remove(device.id) }
    try remote.devices.add(device("orphan", created: now.timeIntervalSince1970 - 700, seen: nil), replacing: nil)
    try remote.devices.add(device("claimed", created: now.timeIntervalSince1970 - 700, seen: nil), replacing: nil)
    try remote.devices.add(device("fresh", created: now.timeIntervalSince1970 - 60, seen: nil), replacing: nil)
    try remote.devices.add(device("old", created: 0, seen: 0), replacing: nil)
    remote.devices.seen("claimed")
    remote.sweepOrphans(now: now)
    #expect(remote.devices.devices.map(\.id).sorted() == ["claimed", "fresh", "old"])
    remote.sweepOrphans(now: now.addingTimeInterval(600))
    #expect(remote.devices.devices.map(\.id).sorted() == ["claimed", "old"])
    for device in remote.devices.devices { try remote.devices.remove(device.id) }
}

@MainActor @Test func aPhoneRegistersForPushRekeysAndHearsTheRelayIsDown() async throws {
    let scene = Scene()
    let remote = scene.store.remote
    // The demo has no relay unless one is named.
    var (status, body) = try await scene.call("POST", "v1/diagnostics/push")
    #expect(status == 503 && code(body) == "relay_unavailable")
    remote.relayURL = URL(string: "http://127.0.0.1:9")!
    let installID = try #require(remote.installID)
    try remote.devices.add(RemoteDevice(id: "d1", name: "iPhone", model: "iPhone", system: "iOS", app: "1.0", build: 1, hash: Data(count: 32),
                                        secretHash: Data(count: 32).base64URL, created: 0), replacing: nil)

    (status, body) = try await scene.call("POST", "v1/devices/push", ["apnsToken": "zz", "environment": "sandbox", "activityTokens": [:], "prefs": [:]])
    #expect(status == 400)
    let registration: [String: Any] = ["apnsToken": String(repeating: "ab", count: 32), "environment": "sandbox", "activityTokens": [:],
                                       "prefs": ["requests": true, "questions": true, "plans": true, "finished": false, "limits": true,
                                                 "timeSensitiveRequests": true, "liveActivity": true, "suppressWhileWatching": true]]
    (status, _) = try await scene.call("POST", "v1/devices/push", registration)
    #expect(status == 204)
    #expect(remote.devices.devices.first?.push?.prefs.finished == false)
    // Nothing listens on port 9.
    for _ in 0..<100 where remote.push.relayState != "unreachable" { try await Task.sleep(for: .milliseconds(20)) }
    (status, body) = try await scene.call("GET", "v1/setup")
    #expect(body["relay"] as? String == "unreachable" && (body["push"] as? [String: Any])?["registered"] as? Bool == true)

    // The phone derives the same new key from what the Mac answers.
    let phone = Curve25519.KeyAgreement.PrivateKey()
    (status, body) = try await scene.call("POST", "v1/devices/rekey", ["devicePublicKey": phone.publicKey.rawRepresentation.base64URL])
    let mac = try #require((body["macPublicKey"] as? String).flatMap { Data(base64URL: $0) })
    let key = try PushKey.derive(phone, peer: Curve25519.KeyAgreement.PublicKey(rawRepresentation: mac), macPublicKey: mac,
                                 devicePublicKey: phone.publicKey.rawRepresentation, installID: installID, deviceID: "d1")
    #expect(status == 200 && body["keyID"] as? String == key.keyID.base64URL)
    #expect(RemotePush.key(try #require(remote.devices.devices.first)) == key)

    (status, body) = try await scene.call("POST", "v1/diagnostics/push")
    #expect(status == 200 && body["relay"] as? String == "unreachable")
    (status, _) = try await scene.call("POST", "v1/diagnostics/push/diag-nothing/received")
    #expect(status == 404)
}

@MainActor @Test func aPreviewIsOnlyForAPortTheSessionListensOn() async throws {
    let scene = Scene()
    let object: [String: Any] = ["pid": 77, "status": "busy", "cwd": "/tmp/app", "started": 1_700_000_000, "agent": "claude", "id": "s77",
                                 "ports": [["port": 5173, "pid": 78, "command": "node"]]]
    scene.store.sessions.live.append(try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: object)))
    func call(_ method: String, _ path: String) async throws -> (Int, [String: Any]) {
        let parts = URLComponents(string: "/" + path)
        let query = Dictionary((parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let route = (parts?.path ?? path).split(separator: "/").map(String.init)
        let request = HTTPRequest(method: method, target: "/" + path, path: route, query: query,
                                  headers: HTTPHeaders([("Host", "100.64.0.1:47800")]), body: Data())
        let response = await RemoteRoutes.route(request, RemoteServer.Caller(device: "d1", connection: 1), scene.store.remote)
        return (response.status, response.body.isEmpty ? [:] : try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any]))
    }
    var (status, body) = try await call("POST", "v1/sessions/s77/ports/3000/preview")
    #expect(status == 404 && code(body) == "port_not_found")
    (status, body) = try await call("POST", "v1/sessions/s77/ports/5173/preview")
    let url = try #require(body["url"] as? String)
    #expect(status == 200 && url.hasPrefix("https://100.64.0.1:47800/v1/preview/") && url.hasSuffix("/"))
    // Opened again, a fresh credential replaces the last: each link opens one page load.
    let again = try #require(try await call("POST", "v1/sessions/s77/ports/5173/preview").1["url"] as? String)
    #expect(again != url && scene.store.remote.previews.previews.count == 1)
    #expect(scene.store.remote.previews.url(session: "s77", port: 5173) == again)
    (status, _) = try await call("DELETE", "v1/sessions/s77/ports/5173/preview")
    #expect(status == 204 && scene.store.remote.previews.previews.isEmpty)
}

/// Continue on phone's refusals: no tmux, an unknown session, one that's working or in an unknown state, one
/// that ended before the re-check; and an already hosted session answers with itself, so a retry is harmless.
@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func continueOnPhoneRefusesWhatItCantMoveAndAnswersARetry() async throws {
    let scene = Scene()
    try scene.live(pid: 201, id: "s-busy", status: "busy")
    var (status, body) = try await scene.call("POST", "v1/sessions/s-busy/continue")
    #expect(status == 503 && code(body) == "tmux_missing")

    let fixture = try HostedFixture()
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge)
    scene.store.hosted = hosted
    await hosted.install()
    do {
        try #require(hosted.available)
        try scene.live(pid: 202, id: "s-unknown", status: "unknown")
        try scene.live(pid: 203, id: "s-gone", status: "idle")
        (status, body) = try await scene.call("POST", "v1/sessions/nope/continue")
        #expect(status == 404 && code(body) == "session_not_found")
        for id in ["s-busy", "s-unknown", "s-gone"] {
            (status, body) = try await scene.call("POST", "v1/sessions/\(id)/continue")
            #expect(status == 409 && code(body) == "cannot_deliver", "\(id): \(body)")
        }

        let name = try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .new(model: nil)))
        try scene.live(pid: 204, id: "s-hosted", status: "idle", hosted: name)
        (status, body) = try await scene.call("POST", "v1/sessions/s-hosted/continue")
        #expect(status == 200 && body["name"] as? String == name && body["sessionID"] as? String == "s-hosted", "\(body)")
        #expect(hosted.sessions.count == 1)
    } catch { Issue.record(error) }
    await fixture.cleanUp()
}

/// A process nobody else knows, detached so it isn't this test's child; its row carries its real start time.
@MainActor
private func idleSession(_ id: String, since: Double, kind: String? = "interactive", cwd: String = "/tmp/app") async throws -> LiveSession {
    let output = await HostedSessions.process("/bin/sh", ["-c", "nohup /bin/sleep 600 >/dev/null 2>&1 & echo $!"], timeout: 5).output
    let pid = try #require(Int(output.trimmingCharacters(in: .whitespacesAndNewlines)))
    var live = LiveSession(pid: pid, sessionID: id, name: nil, title: nil, cost: nil, cwd: cwd, status: "idle", waitingFor: nil, since: since)
    live.agent = "claude"; live.kind = kind
    live.started = ProcessCheck.startTime(pid)?.rounded(.down)
    return live
}

/// Quit signals only the process the phone saw (same pid and start time), never a headless run; Quit Idle takes only
/// the sessions idle longer than asked.
@MainActor @Test func quitEndsOnlyTheSessionThePhoneSawAndQuitIdleOnlyTheStaleOnes() async throws {
    let scene = Scene()
    let now = Date().timeIntervalSince1970
    let target = try await idleSession("q-one", since: now)
    let old = try await idleSession("q-old", since: now - 3600)
    let recent = try await idleSession("q-new", since: now - 60)
    let headless = try await idleSession("q-sdk", since: now - 3600, kind: "sdk")
    var reused = LiveSession(pid: target.pid, sessionID: "q-reused", name: nil, title: nil, cost: nil, cwd: "/tmp/app", status: "idle", waitingFor: nil, since: now)
    reused.started = 1_700_000_000
    scene.store.sessions.live = [target, old, recent, headless, reused]
    defer { for session in [target, old, recent, headless] { kill(pid_t(session.pid), SIGKILL) } }

    var (status, body) = try await scene.call("POST", "v1/sessions/nope/quit")
    #expect(status == 404 && code(body) == "session_not_found")
    (status, body) = try await scene.call("POST", "v1/sessions/q-sdk/quit")
    #expect(status == 409 && code(body) == "cannot_deliver")
    // Same pid, another start time: a reused pid is never signalled.
    (status, body) = try await scene.call("POST", "v1/sessions/q-reused/quit")
    #expect(status == 404)
    #expect(ProcessCheck.alive(target.pid))

    (status, _) = try await scene.call("POST", "v1/sessions/q-one/quit")
    #expect(status == 204)
    #expect(await waitUntil(3) { !ProcessCheck.alive(target.pid) })

    scene.store.sessions.live = [old, recent, headless]
    (status, body) = try await scene.call("POST", "v1/sessions/quit-idle", ["olderThanMinutes": 30])
    #expect(status == 200 && body["quit"] as? [String] == [WireBuilders.key(old)], "\(body)")
    #expect(await waitUntil(3) { !ProcessCheck.alive(old.pid) })
    #expect(ProcessCheck.alive(recent.pid) && ProcessCheck.alive(headless.pid))
}

@MainActor @Test func thePhoneTurnsKeepAwakeOnAndReadsTheMac() async throws {
    let scene = Scene()
    let was = scene.store.keepAwake.settings.enabled
    defer { scene.store.keepAwake.setEnabled(was) }
    var (status, body) = try await scene.call("POST", "v1/mac/settings", ["keepAwake": true])
    #expect(status == 200 && body["keepAwake"] as? Bool == true && scene.store.keepAwake.settings.enabled)
    #expect((body["memoryTotal"] as? Int ?? 0) > 1 << 30 && (body["memoryUsed"] as? Int ?? 0) > 0)
    #expect(["normal", "warning", "critical"].contains(body["memoryPressure"] as? String ?? ""))
    (status, body) = try await scene.call("POST", "v1/mac/settings", ["keepAwake": false])
    #expect(status == 200 && body["keepAwake"] as? Bool == false)
    (status, _) = try await scene.call("POST", "v1/mac/settings", "nope".data(using: .utf8)!)
    #expect(status == 400)
}

/// History lists pins first and leaves the archive out; changes are Side A's own and show at once; search pages.
@MainActor @Test func historyPinsRenamesArchivesAndSearchPages() async throws {
    let scene = Scene()
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sa-history-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home"), index = base.appendingPathComponent("Side A")
    let ids = ["h1", "h2", "h3"]
    for (n, id) in ids.enumerated() {
        try TranscriptFixture.write(TranscriptFixture.lines(session: id, cwd: "/tmp/app", day: "2026-10-0\(n + 1)"), session: id, home: home)
    }
    TranscriptFixture.index(home: home, root: index)
    scene.store.sessions.transcriptSource = (home: home, bridge: TranscriptFixture.bridge, python: "/usr/bin/python3", root: index)
    let sessions = scene.store.sessions
    func reset() { for id in ids { sessions.setPinned(id, false); sessions.setArchived(id, false); sessions.setTitle(id, "") } }
    reset()
    defer { reset() }
    let listed = { (path: String) async throws -> [String] in
        let (status, body) = try await scene.call("GET", path)
        #expect(status == 200, "\(body)")
        return (body["sessions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    #expect(try await listed("v1/history") == ["h3", "h2", "h1"])
    var (status, body) = try await scene.call("POST", "v1/history/h1", ["pinned": true, "title": " Billing "])
    #expect(status == 200 && body["pinned"] as? Bool == true && body["customTitle"] as? String == "Billing" && body["title"] as? String == "Billing")
    // A live row of it shows the same title.
    try scene.live(pid: 4242, id: "h1", status: "idle")
    #expect(WireBuilders.session(scene.store.sessions.live.last!, store: scene.store, finished: []).title == "Billing")
    scene.store.sessions.live.removeLast()
    #expect(try await listed("v1/history") == ["h1", "h3", "h2"])
    (status, body) = try await scene.call("POST", "v1/history/h2", ["archived": true])
    #expect(status == 200 && body["archived"] as? Bool == true)
    #expect(try await listed("v1/history") == ["h1", "h3"])
    #expect(try await listed("v1/history?archived=true") == ["h2"])
    #expect(try await listed("v1/history?archived=1") == ["h2"])
    #expect(try await listed("v1/history?archived=0") == ["h1", "h3"])
    #expect(try await listed("v1/history?project=/tmp/other").isEmpty)
    // Archiving a pinned one unpins it; pinning brings it back.
    (status, body) = try await scene.call("POST", "v1/history/h1", ["archived": true])
    #expect(status == 200 && body["pinned"] as? Bool == false && !sessions.isPinned("h1"))
    (status, body) = try await scene.call("POST", "v1/history/h1", ["pinned": true])
    #expect(status == 200 && body["archived"] as? Bool == false && body["pinned"] as? Bool == true)
    (status, body) = try await scene.call("POST", "v1/history/h1", ["pinned": true, "archived": true])
    #expect(status == 400)
    (status, body) = try await scene.call("POST", "v1/history/nope", ["pinned": true])
    #expect(status == 404 && code(body) == "session_not_found")
    (status, _) = try await scene.call("GET", "v1/history?cursor=zz")
    #expect(status == 400)

    // Search leaves the archived h2 out, one result a page here.
    (status, body) = try await scene.call("GET", "v1/search?q=build&limit=1")
    let first = try #require(body["results"] as? [[String: Any]])
    #expect(status == 200 && first.count == 1 && body["next"] as? String == "o1", "\(body)")
    #expect((first.first?["snippet"] as? String).map { !$0.contains("\u{02}") } ?? true)
    (status, body) = try await scene.call("GET", "v1/search?q=build&limit=1&cursor=o1")
    let second = try #require(body["results"] as? [[String: Any]])
    #expect(second.count == 1 && body["next"] == nil)
    #expect(Set((first + second).compactMap { $0["id"] as? String }) == ["h1", "h3"])
    (status, _) = try await scene.call("GET", "v1/search?q=")
    #expect(status == 400)
}

/// The harness's past conversations page through history, newest first, and its forks name their parents.
@MainActor @Test func theHarnessHistorySpansPagesWithForks() async throws {
    let scene = Scene()
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("sa-past-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: home) }
    try HarnessScene.past(home: home)
    let index = home.appendingPathComponent("Side A")
    TranscriptFixture.index(home: home, root: index)
    scene.store.sessions.transcriptSource = (home: home, bridge: TranscriptFixture.bridge, python: "/usr/bin/python3", root: index)
    var rows: [[String: Any]] = [], cursor: String?, pages = 0
    repeat {
        pages += 1
        let (status, body) = try await scene.call("GET", "v1/history" + (cursor.map { "?cursor=" + $0 } ?? ""))
        #expect(status == 200, "\(body)")
        rows += body["sessions"] as? [[String: Any]] ?? []
        cursor = body["next"] as? String
    } while cursor != nil && rows.count < 100
    #expect(pages == 2)
    let ids = rows.compactMap { $0["id"] as? String }
    #expect(ids.prefix(3) == ["past-03-fork-2", "past-03-fork", "past-00"])
    let parent = Dictionary(uniqueKeysWithValues: rows.compactMap { row in (row["id"] as? String).map { ($0, row["parentID"] as? String) } })
    #expect(parent["past-03-fork"] == "past-03" && parent["past-03-fork-2"] == "past-03-fork" && parent["past-03"] == .some(nil))
}

/// A demo's Clean Up moves only the harness's own transcripts; with no harness home it touches nothing.
@MainActor @Test func aDemosCleanUpStaysInItsOwnHome() async throws {
    let scene = Scene()
    var (status, _) = try await scene.call("POST", "v1/cleanup/archive", ["olderThanDays": 90])
    #expect(status == 503)
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("sa-clean-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: home) }
    try TranscriptFixture.write(TranscriptFixture.lines(session: "old", cwd: "/tmp/app"), session: "old", home: home)
    let file = home.appendingPathComponent(".claude/projects/-fixture/old.jsonl")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 86_400)], ofItemAtPath: file.path)
    let index = home.appendingPathComponent("Side A")
    TranscriptFixture.index(home: home, root: index)
    scene.store.sessions.transcriptSource = (home: home, bridge: TranscriptFixture.bridge, python: "/usr/bin/python3", root: index)
    var body: [String: Any]
    (status, body) = try await scene.call("POST", "v1/cleanup/archive", ["olderThanDays": 90])
    #expect(status == 200 && body["count"] as? Int == 1, "\(body)")
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: index.appendingPathComponent("archive/.claude/projects/-fixture/old.jsonl").path))
    (status, body) = try await scene.call("POST", "v1/cleanup/restore")
    #expect(status == 200 && body["count"] as? Int == 1 && FileManager.default.fileExists(atPath: file.path), "\(body)")
}

@MainActor @Test func stopServerEndsOnlyTheServerTheSessionStarted() async throws {
    let scene = Scene()
    var owner = try await idleSession("srv", since: Date().timeIntervalSince1970)
    let server = try await idleSession("srv-child", since: 0)
    defer { kill(pid_t(owner.pid), SIGKILL); kill(pid_t(server.pid), SIGKILL) }
    owner.ports = [.init(port: 3000, pid: server.pid, command: "node", started: server.started),
                   .init(port: 9229, pid: owner.pid, command: "claude", started: owner.started)]
    scene.store.sessions.live = [owner]
    var (status, body) = try await scene.call("POST", "v1/sessions/srv/ports/4000/stop")
    #expect(status == 404 && code(body) == "port_not_found")
    // The session's own process is never the server that gets stopped.
    (status, body) = try await scene.call("POST", "v1/sessions/srv/ports/9229/stop")
    #expect(status == 404 && ProcessCheck.alive(owner.pid))
    (status, _) = try await scene.call("POST", "v1/sessions/srv/ports/3000/stop")
    #expect(status == 204)
    #expect(await waitUntil(3) { !ProcessCheck.alive(server.pid) })
    #expect(ProcessCheck.alive(owner.pid))
}

@Test func aHandoffPromptLeavesOutWhatIsEmpty() {
    let handoff = Handoff(goal: "Fix the build", branch: "main", failed: " ", next: "Run the tests", lastMessages: "", cwd: "/tmp/app", project: "app")
    let prompt = SessionCommands.prompt(handoff)
    #expect(prompt.contains("## Goal\n\nFix the build") && prompt.contains("## Branch\n\n`main`") && prompt.contains("## Next steps\n\nRun the tests"))
    #expect(!prompt.contains("What failed") && !prompt.contains("Last messages"))
}

/// The draft comes from the conversation itself; Restart starts the new hosted session with it, then ends the old one.
@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func restartFreshDraftsAHandoffAndRunsIt() async throws {
    let scene = Scene()
    let fixture = try HostedFixture()
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge)
    scene.store.hosted = hosted
    await hosted.install()
    let home = fixture.base.appendingPathComponent("transcripts"), index = home.appendingPathComponent("Side A")
    try TranscriptFixture.write(TranscriptFixture.lines(session: "r1", cwd: fixture.project.path, day: TranscriptFixture.today), session: "r1", home: home)
    TranscriptFixture.index(home: home, root: index)
    scene.store.sessions.transcriptSource = (home: home, bridge: TranscriptFixture.bridge, python: "/usr/bin/python3", root: index)
    var old = try await idleSession("r1", since: Date().timeIntervalSince1970, cwd: fixture.project.path)
    old.flag = .init(kind: "loop", text: "Repeated the same step 3 times")
    scene.store.sessions.live = [old]
    defer { kill(pid_t(old.pid), SIGKILL) }
    do {
        try #require(hosted.available)
        var (status, body) = try await scene.call("POST", "v1/sessions/r1/handoff")
        #expect(status == 200 && body["goal"] as? String == "Fix the build" && body["failed"] as? String == "Repeated the same step 3 times", "\(body)")
        #expect(body["cwd"] as? String == fixture.project.path && body["project"] as? String == "app" && body["model"] as? String == "claude-opus-5-5")
        let last = try #require(body["lastMessages"] as? String)
        #expect(last.hasPrefix("**You:** Fix the build") && last.contains("**Claude:** Running tests."), "\(last)")
        #expect(ProcessCheck.alive(old.pid) && hosted.sessions.isEmpty)

        var handoff = body
        handoff["next"] = "Run the tests"
        (status, body) = try await scene.call("POST", "v1/sessions/r1/restart", ["handoff": handoff.merging(["cwd": "/elsewhere"]) { $1 }])
        #expect(status == 409 && code(body) == "cannot_deliver")
        (status, body) = try await scene.call("POST", "v1/sessions/r1/restart", ["handoff": handoff], headers: [("Idempotency-Key", "R1")])
        #expect(status == 201 && body["cwd"] as? String == fixture.project.path, "\(body)")
        #expect(await waitUntil(3) { !ProcessCheck.alive(old.pid) })
        let args = fixture.submitted.appendingPathExtension("args")
        #expect(await waitUntil { ((try? String(contentsOf: args, encoding: .utf8)) ?? "").contains("## Next steps") })
        #expect(hosted.sessions.count == 1)
    } catch { Issue.record(error) }
    await fixture.cleanUp()
}

/// Clean Up against a throwaway home: what Archive would move at 30, 60 and 90 days, worktrees with why one is kept,
/// a pin that stays, Archive and Restore, and a removal that never forces.
@MainActor @Test func cleanUpReportsArchivesRestoresAndRemovesOnlyCleanWorktrees() async throws {
    let scene = Scene()
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sa-cleanup-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home"), root = base.appendingPathComponent("Side A"), repo = base.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    let git = { (args: [String]) async in
        _ = await HostedSessions.process("/usr/bin/git", ["-C", repo.path, "-c", "user.email=t@t", "-c", "user.name=t"] + args,
                                         environment: ["HOME": home.path], timeout: 10)
    }
    await git(["init", "-q", "-b", "main"])
    try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    await git(["add", "-A"]); await git(["commit", "-qm", "init"])
    let clean = base.appendingPathComponent("repo-clean").path, dirty = base.appendingPathComponent("repo-dirty").path
    await git(["worktree", "add", "-q", "-b", "clean", clean]); await git(["worktree", "add", "-q", "-b", "dirty", dirty])
    try "b\n".write(toFile: dirty + "/b.txt", atomically: true, encoding: .utf8)

    try TranscriptFixture.write(TranscriptFixture.lines(session: "c-new", cwd: repo.path, day: TranscriptFixture.today), session: "c-new", home: home)
    try TranscriptFixture.write(TranscriptFixture.lines(session: "c-old", cwd: repo.path), session: "c-old", home: home)
    let oldFile = home.appendingPathComponent(".claude/projects/-fixture/c-old.jsonl")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 86400)], ofItemAtPath: oldFile.path)
    TranscriptFixture.index(home: home, root: root)
    scene.store.remote.cleanupBridge = { args, timeout in
        let result = await HostedSessions.process("/usr/bin/python3", [TranscriptFixture.bridge.path, "--root", root.path] + args,
                                                  environment: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin"], timeout: timeout)
        guard result.status == 0 else { throw BridgeFailure(message: result.errors) }
        return Data(result.output.utf8)
    }

    var (status, body) = try await scene.call("GET", "v1/cleanup")
    #expect(status == 200 && body["conversations"] as? Int == 2 && (body["conversationBytes"] as? Int ?? 0) > 0, "\(body)")
    let archivable = (body["archivable"] as? [[String: Any]] ?? []).map { ($0["olderThanDays"] as? Int ?? 0, $0["count"] as? Int ?? -1) }
    #expect(archivable.map(\.0) == [30, 60, 90] && archivable.map(\.1) == [1, 1, 1])
    let trees = Dictionary(uniqueKeysWithValues: (body["worktrees"] as? [[String: Any]] ?? []).map { ($0["branch"] as? String ?? "", $0) })
    #expect(trees["clean"]?["keep"] == nil && trees["dirty"]?["keep"] as? String == "changes", "\(trees)")
    let cleanID = try #require(trees["clean"]?["id"] as? String), dirtyID = try #require(trees["dirty"]?["id"] as? String)
    #expect(!cleanID.contains("/"))

    (status, body) = try await scene.call("DELETE", "v1/worktrees/\(dirtyID)")
    #expect(status == 409 && code(body) == "worktree_kept" && FileManager.default.fileExists(atPath: dirty))
    (status, _) = try await scene.call("DELETE", "v1/worktrees/\(cleanID)")
    #expect(status == 204 && !FileManager.default.fileExists(atPath: clean))
    (status, _) = try await scene.call("DELETE", "v1/worktrees/\(cleanID)")
    #expect(status == 404)

    scene.store.sessions.setPinned("c-old", true)
    (status, body) = try await scene.call("POST", "v1/cleanup/archive", ["olderThanDays": 90])
    #expect(status == 200 && body["count"] as? Int == 0 && FileManager.default.fileExists(atPath: oldFile.path))
    scene.store.sessions.setPinned("c-old", false)
    (status, body) = try await scene.call("POST", "v1/cleanup/archive", ["olderThanDays": 90])
    #expect(status == 200 && body["count"] as? Int == 1 && !FileManager.default.fileExists(atPath: oldFile.path))
    (status, body) = try await scene.call("POST", "v1/cleanup/restore")
    #expect(status == 200 && body["count"] as? Int == 1 && FileManager.default.fileExists(atPath: oldFile.path))
    (status, _) = try await scene.call("POST", "v1/cleanup/archive", ["olderThanDays": 0])
    #expect(status == 400)
}

@Test func autopilotDecisionsAreReadBackFromItsLog() {
    let log = """
    2026-10-18T09:00:00 Work: usage read failed: timeout
    2026-10-18T09:01:00 Work → Personal: waiting for its sessions to pause (quiet 12s of 60s).
    2026-10-18T09:02:00 Work → Personal: moved (Fable share with Side).
    2026-10-18T09:03:00 New commands: Work → Personal.
    2026-10-18T09:04:00 New commands: Work → Personal failed: no login.
    2026-10-18T09:05:00 Spare: primed its 5-hour window.
    2026-10-18T09:06:00 Work → Personal: move failed: The swap didn't finish.
    garbage line
    """
    let decisions = Autopilot.decisions(log)
    #expect(decisions.map(\.kind) == [.failed, .primed, .failed, .moved, .moved, .waiting])
    #expect(decisions[0].title == "Couldn't move Work → Personal" && decisions[0].reason == "move failed: The swap didn't finish.")
    #expect(decisions[3].title == "New commands use Personal" && decisions[3].from == "Work")
    #expect(decisions[4].reason == "Fable share with Side" && decisions[4].at == 1_792_314_120)
    #expect(Set(decisions.map(\.id)).count == decisions.count)
}

@MainActor @Test func moveNowRunsTheHeldMoveAndIncidentsComeFromTheStatusPage() async throws {
    let scene = Scene()
    let store = scene.store
    let log = store.root.appendingPathComponent("runtime/autopilot.log")
    try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: log)
    var (status, body) = try await scene.call("GET", "v1/autopilot")
    #expect(status == 200 && body["pending"] == nil && (body["decisions"] as? [Any])?.isEmpty == true)
    (status, body) = try await scene.call("POST", "v1/autopilot/move")
    #expect(status == 409 && code(body) == "nothing_to_move")

    let accounts = store.config.accounts.filter { $0.provider == .claude }
    try #require(accounts.count >= 2)
    store.heldMoves["mac"] = .init(slot: "mac", from: accounts[0].id, to: accounts[1].id, share: false, reason: "Waiting for its sessions to pause.", since: Date())
    (status, body) = try await scene.call("GET", "v1/autopilot")
    let pending = try #require(body["pending"] as? [String: Any])
    #expect(pending["kind"] as? String == "waiting" && pending["from"] as? String == accounts[0].name && pending["to"] as? String == accounts[1].name)
    (status, body) = try await scene.call("POST", "v1/autopilot/move")
    #expect(status == 200 && body["pending"] == nil && store.heldMoves.isEmpty, "\(body)")
    #expect(((body["decisions"] as? [[String: Any]])?.first?["kind"] as? String) == "moved")

    #expect(WireBuilders.incidents(store).isEmpty)
    store.outage = Outage(id: "b", name: "Elevated errors on Opus", major: true, status: "identified", startedAt: 1_792_315_800, url: "https://stspg.io/b")
    #expect(WireBuilders.incidents(store) == [Incident(id: "b", provider: .claude, title: "Elevated errors on Opus", status: .identified,
                                                       url: "https://stspg.io/b", startedAt: 1_792_315_800)])
    store.outage = nil
}

/// A JSON GET carries its body's hash as an ETag; sending it back gets a 304 with no body until the answer changes.
@MainActor @Test func bigGetsAnswerNotModifiedForTheSameBody() async throws {
    let scene = Scene()
    func get(_ path: String, _ tag: String? = nil) async -> HTTPResponse {
        let route = path.split(separator: "/").map(String.init)
        let request = HTTPRequest(method: "GET", target: "/" + path, path: route, query: [:],
                                  headers: HTTPHeaders(tag.map { [("If-None-Match", $0)] } ?? []), body: Data())
        return await RemoteRoutes.route(request, RemoteServer.Caller(device: "d1", connection: 1), scene.store.remote)
    }
    // State, sessions, accounts and history need a running server or a bridge; the tag is the router's, the same for every route.
    for path in ["v1/projects", "v1/options"] {
        let first = await get(path)
        let tag = try #require(first.headers["ETag"], "\(path) \(first.status)")
        #expect(first.status == 200 && tag.hasPrefix("\"") && tag.hasSuffix("\"") && first.headers["Cache-Control"] == "private, no-cache")
        #expect(first.headers["Content-Type"] == "application/json")
        let again = await get(path, tag)
        #expect(again.status == 304 && again.body.isEmpty && again.headers["ETag"] == tag, "\(path)")
        #expect(await get(path, "\"other\", W/\(tag)").status == 304)
        #expect(await get(path, "\"other\"").status == 200)
    }
    // A change is a new body and a new tag.
    func request(_ method: String, _ tag: String?) -> HTTPRequest {
        HTTPRequest(method: method, target: "/v1/state", path: ["v1", "state"], query: [:], headers: HTTPHeaders(tag.map { [("If-None-Match", $0)] } ?? []), body: Data())
    }
    let one = RemoteRoutes.tagged(.json(200, Data(#"{"seq":1}"#.utf8)), request("GET", nil))
    let tag = try #require(one.headers["ETag"])
    #expect(RemoteRoutes.tagged(.json(200, Data(#"{"seq":1}"#.utf8)), request("GET", tag)).status == 304)
    let two = RemoteRoutes.tagged(.json(200, Data(#"{"seq":2}"#.utf8)), request("GET", tag))
    #expect(two.status == 200 && two.headers["ETag"] != tag && two.body == Data(#"{"seq":2}"#.utf8))
    // Errors, other methods and images (which tag themselves) are left as they are.
    #expect(RemoteRoutes.tagged(.json(404, Data("{}".utf8)), request("GET", nil)).headers["ETag"] == nil)
    #expect(RemoteRoutes.tagged(.json(200, Data("{}".utf8)), request("POST", nil)).headers["ETag"] == nil)
    #expect(await get("v1/requests/\(UUID().uuidString)").headers["ETag"] == nil)
}

/// Account actions: switching the Mac-wide login and Autopilot both wait on the confirm key, after checks that need no
/// key; the work behind them is the same PLAY and toggle the Mac's own controls run.
@MainActor @Test func accountActionsCheckBeforeTheConfirmAndShareTheMacsControls() async throws {
    let scene = Scene()
    let store = scene.store
    #expect(RemoteController.capabilities.isSuperset(of: [.accountsUse, .autopilotToggle]))
    let studio = store.config.accounts[1]
    var (status, body) = try await scene.call("POST", "v1/accounts/nope/use", [String: String](), headers: [("Idempotency-Key", "A1")])
    #expect(status == 404 && code(body) == "not_found", "\(body)")
    store.config.accounts[1].ready = false
    (status, body) = try await scene.call("POST", "v1/accounts/\(studio.id)/use", [String: String](), headers: [("Idempotency-Key", "A2")])
    #expect(status == 409 && code(body) == "account_not_ready", "\(body)")
    // Ready, it goes to the confirm step; the scene has no server to check a signature with (RemoteServerTests covers
    // the signature), and nothing switched.
    store.config.accounts[1].ready = true
    (status, body) = try await scene.call("POST", "v1/accounts/\(studio.id)/use", [String: String](), headers: [("Idempotency-Key", "A3")])
    #expect(status == 503 && code(body) == "not_ready", "\(body)")
    #expect(store.activeIDs[.claude] == store.config.accounts[0].id)

    (status, body) = try await scene.call("POST", "v1/autopilot", ["enabled": "yes"], headers: [("Idempotency-Key", "A4")])
    #expect(status == 400 && code(body) == "bad_request", "\(body)")
    (status, body) = try await scene.call("POST", "v1/autopilot", ["enabled": false], headers: [("Idempotency-Key", "A5")])
    #expect(status == 503 && code(body) == "not_ready", "\(body)")
    #expect(store.config.smartMode)
    // Answering with the recommended choice waits on the same key, and needs no shell switching.
    #expect(RemoteController.capabilities.contains(.autopilotAnswers))
    (status, body) = try await scene.call("POST", "v1/autopilot/answers", ["enabled": "yes"], headers: [("Idempotency-Key", "A4a")])
    #expect(status == 400 && code(body) == "bad_request", "\(body)")
    (status, body) = try await scene.call("POST", "v1/autopilot/answers", ["enabled": true], headers: [("Idempotency-Key", "A4b")])
    #expect(status == 503 && code(body) == "not_ready", "\(body)")
    #expect(store.config.answerRecommended == nil)

    // Shell switching off, the phone can't turn it on: a Claude switch and Autopilot on are refused before the
    // confirm, while Autopilot off and a Codex switch still go to it.
    store.shellSwitching = false
    (status, body) = try await scene.call("POST", "v1/accounts/\(studio.id)/use", [String: String](), headers: [("Idempotency-Key", "A6")])
    #expect(status == 409 && code(body) == "cannot_deliver" && hint(body) == "shellSwitching", "\(body)")
    store.config.smartMode = false
    (status, body) = try await scene.call("POST", "v1/autopilot", ["enabled": true], headers: [("Idempotency-Key", "A7")])
    #expect(status == 409 && hint(body) == "shellSwitching", "\(body)")
    (status, body) = try await scene.call("POST", "v1/autopilot", ["enabled": false], headers: [("Idempotency-Key", "A8")])
    #expect(status == 503 && code(body) == "not_ready", "\(body)")
    let codex = try #require(store.config.accounts.first { $0.provider == .codex && $0.id != store.activeIDs[.codex] })
    (status, body) = try await scene.call("POST", "v1/accounts/\(codex.id)/use", [String: String](), headers: [("Idempotency-Key", "A9")])
    #expect(status == 503 && code(body) == "not_ready", "\(body)")
    #expect(!store.shellSwitching && !store.config.smartMode)
    store.shellSwitching = true
    store.config.smartMode = true

    // What runs once confirmed: PLAY's switch and the toggle's setter.
    try await store.use(studio.id)
    #expect(store.activeIDs[.claude] == studio.id)
    try await store.use(studio.id)
    store.setAutopilot(false)
    #expect(!store.config.smartMode)
    store.toggleSmart()
    #expect(store.config.smartMode)
}
