import CryptoKit
import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

/// A demo store with a real server behind its routes, whose signature check is the one a phone meets.
@MainActor
private final class Rotation {
    let store = AccountStore(demo: true)
    let confirm = P256.Signing.PrivateKey(), unlock = P256.Signing.PrivateKey()
    let keychain: TestKeychain
    let server: RemoteServer
    let token = DeviceToken.make()

    init() throws {
        keychain = try TestKeychain()
        let identity = try #require(try keychain.store.identity())
        let controller = store.remote
        server = RemoteServer(identity: identity, epoch: "e1", handler: RemoteRoutes.handler(controller))
        server.macID = "mac"
        server.setDevices([(id: "d1", hash: DeviceToken.hash(token))],
                          keys: ["d1": .init(confirm: confirm.publicKey.x963Representation.base64URL, unlock: unlock.publicKey.x963Representation.base64URL)])
        controller.server = server
        controller.hub = EventHub(queue: server.queue, epoch: "e1", snapshot: { { seq, epoch in StateSnapshot(seq: seq, epoch: epoch) } }, hello: {
            Hello(app: "", build: 0, mac: MacInfo(id: "", name: ""), capabilities: [], epoch: "e1", serverTime: 0, endpoints: Endpoints(tailnet: ""), keyID: "")
        })
    }

    func signature(_ subject: String, purpose: ConfirmPurpose = .rotation, signer: ConfirmSignature.Signer = .confirm, device: String = "d1", at: Int? = nil) throws -> String {
        let at = at ?? Int(Date().timeIntervalSince1970)
        let text = try ConfirmMessage.text(macID: "mac", deviceID: device, purpose: purpose, subject: subject, at: at)
        let key = signer == .confirm ? confirm : unlock
        return ConfirmSignature(at: at, signer: signer, signature: try key.signature(for: Data(text.utf8)).derRepresentation).headerValue
    }

    func call(_ method: String, _ path: String, _ body: Any? = nil, confirm header: String? = nil) async throws -> (status: Int, body: [String: Any]) {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var headers = [("Idempotency-Key", UUID().uuidString)]
        if let header { headers.append((ConfirmSignature.header, header)) }
        let request = HTTPRequest(method: method, target: "/" + path, path: path.split(separator: "/").map(String.init), query: [:], headers: HTTPHeaders(headers), body: data)
        let response = await RemoteRoutes.route(request, RemoteServer.Caller(device: "d1", connection: 1), store.remote)
        return (response.status, response.body.isEmpty ? [:] : try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any]))
    }
}

private func code(_ object: [String: Any]) -> String? { (object["error"] as? [String: Any])?["code"] as? String }
private func details(_ object: [String: Any]) -> [String: String]? { (object["error"] as? [String: Any])?["details"] as? [String: String] }

/// Everything a signed route must refuse: no signature, the unlock key, a signature for another change, another
/// purpose, another device, an old one, and the same one twice. Nothing changes until the last, good one.
@MainActor private func checkGate(_ scene: Rotation, path: String, body: [String: Any], subject: String, wrong: String,
                                  unchanged: () -> Bool, changed: () -> Bool) async throws {
    func refused(_ header: String?, _ expected: String, line: String) async throws {
        let (status, answer) = try await scene.call("POST", path, body, confirm: header)
        #expect(status == 401 && code(answer) == expected, "\(path) \(line): \(status) \(answer)")
        #expect(unchanged(), "\(path) changed on \(line)")
    }
    try await refused(nil, "confirm_required", line: "token alone")
    try await refused(try scene.signature(subject, signer: .unlock), "confirm_required", line: "unlock key")
    try await refused(try scene.signature(wrong), "confirm_invalid", line: "another change")
    try await refused(try scene.signature(subject, purpose: .autopilot), "confirm_invalid", line: "another purpose")
    try await refused(try scene.signature(subject, purpose: .account), "confirm_invalid", line: "the Use signature's purpose")
    try await refused(try scene.signature(subject, device: "d2"), "confirm_invalid", line: "another device")
    try await refused(try scene.signature(subject, at: Int(Date().timeIntervalSince1970) - 600), "confirm_invalid", line: "an old signature")
    let good = try scene.signature(subject)
    let (status, answer) = try await scene.call("POST", path, body, confirm: good)
    #expect(status == 200, "\(path): \(answer)")
    #expect(changed(), "\(path) didn't change")
    let (again, replayed) = try await scene.call("POST", path, body, confirm: good)
    #expect(again == 401 && code(replayed) == "confirm_invalid" && details(replayed)?["reason"] == "replayed", "\(path) replay: \(replayed)")
}

@MainActor @Test func priorityTakesTheConfirmKeyAndNothingLess() async throws {
    let scene = try Rotation()
    let id = scene.store.config.accounts[1].id
    try await checkGate(scene, path: "v1/accounts/\(id)/priority", body: ["priority": "last"],
                        subject: try ConfirmMessage.subject(account: id, priority: .last), wrong: try ConfirmMessage.subject(account: id, priority: .first),
                        unchanged: { scene.store.config.accounts[1].priority == nil }, changed: { scene.store.config.accounts[1].priority == .last })
}

@MainActor @Test func autoTakesTheConfirmKeyAndNothingLess() async throws {
    let scene = try Rotation()
    let id = scene.store.config.accounts[1].id
    try await checkGate(scene, path: "v1/accounts/\(id)/auto", body: ["enabled": false],
                        subject: try ConfirmMessage.subject(account: id, auto: false), wrong: try ConfirmMessage.subject(account: id, auto: true),
                        unchanged: { scene.store.config.accounts[1].allowAuto }, changed: { !scene.store.config.accounts[1].allowAuto })
}

@MainActor @Test func swapAtTakesTheConfirmKeyAndNothingLess() async throws {
    let scene = try Rotation()
    defer { scene.store.setSwapAt(95) }
    try await checkGate(scene, path: "v1/rotation/swap-at", body: ["percent": 97],
                        subject: ConfirmMessage.subject(swapAt: 97), wrong: ConfirmMessage.subject(swapAt: 99),
                        unchanged: { scene.store.config.swapAt == nil }, changed: { scene.store.config.swapAt == 97 })
}

@MainActor @Test func followFableTakesTheConfirmKeyAndNothingLess() async throws {
    let scene = try Rotation()
    try await checkGate(scene, path: "v1/rotation/follow-fable", body: ["enabled": false],
                        subject: ConfirmMessage.subject(followFable: false), wrong: ConfirmMessage.subject(followFable: true),
                        unchanged: { scene.store.config.followFable == nil }, changed: { scene.store.config.followFable == false })
}

/// A signature for one account never moves another, and a change of account is a new thing to sign.
@MainActor @Test func aSignatureBindsTheAccount() async throws {
    let scene = try Rotation()
    let first = scene.store.config.accounts[0].id, second = scene.store.config.accounts[1].id
    let (status, answer) = try await scene.call("POST", "v1/accounts/\(second)/priority", ["priority": "last"],
                                                confirm: try scene.signature(try ConfirmMessage.subject(account: first, priority: .last)))
    #expect(status == 401 && code(answer) == "confirm_invalid")
    #expect(scene.store.config.accounts[1].priority == nil)
}

/// Checks that need no key come first, so a bad body never spends a good signature.
@MainActor @Test func badBodiesAreRefusedBeforeTheSignature() async throws {
    let scene = try Rotation()
    let id = scene.store.config.accounts[1].id
    let good = try scene.signature(ConfirmMessage.subject(swapAt: 42))
    for (path, body) in [("v1/rotation/swap-at", ["percent": 42] as [String: Any]), ("v1/rotation/swap-at", ["percent": "95"]), ("v1/rotation/swap-at", ["percent": 95.5]),
                         ("v1/accounts/\(id)/priority", ["priority": "sometimes"]), ("v1/accounts/\(id)/auto", ["enabled": "yes"]),
                         ("v1/rotation/follow-fable", ["enabled": 1])] {
        let (status, answer) = try await scene.call("POST", path, body, confirm: good)
        #expect(status == 400, "\(path) \(body): \(answer)")
    }
    let (status, answer) = try await scene.call("POST", "v1/accounts/nope/auto", ["enabled": true])
    #expect(status == 404 && code(answer) == "not_found")
    #expect(scene.store.config.swapAt == nil)
}

/// Pool mode stays on the Mac, whatever a phone signs.
@MainActor @Test func poolModeIsRefusedHoweverItIsAsked() async throws {
    let scene = try Rotation()
    let before = scene.store.config.pool
    for header in [nil, try scene.signature("pool:true")] {
        let (status, answer) = try await scene.call("POST", "v1/rotation/pool", ["enabled": true], confirm: header)
        #expect(status == 409 && code(answer) == "cannot_deliver" && details(answer)?["hint"] == "poolOnMac", "\(answer)")
    }
    #expect(scene.store.config.pool == before)
    // Nor is it in a body that takes something else.
    _ = try await scene.call("POST", "v1/rotation/follow-fable", ["enabled": false, "pool": true], confirm: try scene.signature(ConfirmMessage.subject(followFable: false)))
    #expect(scene.store.config.pool == before)
}

/// Over the wire: no token gets nothing from any new route, and a removed device's token and signature stop working.
@MainActor @Test func theServerAsksForATokenAndARemovedDeviceLosesEveryRoute() async throws {
    let scene = try Rotation()
    let server = scene.server, token = scene.token
    let id = scene.store.config.accounts[1].id
    let port = freePort()
    server.serve(addresses: ["127.0.0.1"], port: port)
    defer { server.stop() }
    for _ in 0..<750 where server.listenerStates.values.first != .ready { try await Task.sleep(for: .milliseconds(20)) }
    let pin = try #require(try scene.keychain.store.identity()).spkiHash
    let host = "Host: 127.0.0.1:\(port)\r\n"
    let routes = ["GET /v1/usage/outlook", "POST /v1/accounts/\(id)/priority", "POST /v1/accounts/\(id)/auto", "POST /v1/rotation/swap-at",
                  "POST /v1/rotation/follow-fable", "POST /v1/rotation/pool"]
    func ask(_ route: String, bearer: String?, confirm: String? = nil, body: String = "{\"priority\":\"last\"}") async -> String {
        let client = PinnedClient(port: port, pin: pin)
        defer { client.close() }
        let auth = bearer.map { "Authorization: Bearer \($0)\r\n" } ?? ""
        let signed = confirm.map { "\(ConfirmSignature.header): \($0)\r\n" } ?? ""
        client.send("\(route) HTTP/1.1\r\n\(host)\(auth)\(signed)Idempotency-Key: \(UUID().uuidString)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        return await client.text(until: "\r\n\r\n")
    }
    // Refused, or past five tries from one address refused sooner by the stranger limit; never served.
    func refused(_ answer: String) -> Bool { answer.hasPrefix("HTTP/1.1 401") || answer.hasPrefix("HTTP/1.1 429") }
    for route in routes {
        let answer = await ask(route, bearer: nil, confirm: try scene.signature(try ConfirmMessage.subject(account: id, priority: .last)))
        #expect(refused(answer), "\(route): \(answer)")
    }
    #expect(await ask("GET /v1/usage/outlook", bearer: token).hasPrefix("HTTP/1.1 200"))
    let signature = try scene.signature(try ConfirmMessage.subject(account: id, priority: .last))
    server.setDevices([], keys: [:])
    server.revoke("d1")
    for route in routes {
        let answer = await ask(route, bearer: token, confirm: signature)
        #expect(refused(answer), "\(route) after removal: \(answer)")
    }
    #expect(scene.store.config.accounts[1].priority == nil)
}

@MainActor @Test func accountsCarryWhatThePlannerAndSignInSay() throws {
    let store = AccountStore(demo: true)
    let now = Date().timeIntervalSince1970
    let ids = store.config.accounts.map(\.id)
    func window(_ id: String, _ percent: Double) -> UsageWindow { UsageWindow(id: id, label: id, percent: percent, resetsAt: now + 3600) }
    store.usage[ids[0]] = AccountUsage(windows: [window("five_hour", 100), window("seven_day", 10)], capacity: 5)
    store.usage[ids[1]] = AccountUsage(windows: [window("five_hour", 10), window("seven_day", 10), window("model:fable", 100)], capacity: 5)
    store.usage[ids[2]] = AccountUsage(windows: [window("five_hour", 10), window("seven_day", 10)], capacity: 5)
    store.config.accounts[2].priority = .last
    store.config.accounts[2].allowAuto = false
    store.loginEnds[ids[2]] = now + 86_400
    store.config.accounts[3].ready = false
    store.health[ids[4]] = .signIn(replacedBy: "Work")
    let wire = WireBuilders.accounts(store)
    #expect(wire[0].limited == true && wire[0].fableOut == false && wire[0].backAt == now + 3600)
    #expect(wire[1].limited == false && wire[1].fableOut == true)
    #expect(wire[2].limited == false && wire[2].priority == .last && wire[2].allowAuto == false)
    #expect(wire[2].issue == AccountIssue(kind: .signInEnds, endsAt: now + 86_400))
    #expect(wire[3].issue == AccountIssue(kind: .signedOut))
    #expect(wire[4].issue == AccountIssue(kind: .replaced, replacedBy: "Work"))
    #expect(wire[0].issue == nil)
    // A sign-in that ends in over three days isn't mentioned yet.
    store.loginEnds[ids[2]] = now + 4 * 86_400
    #expect(WireBuilders.accounts(store)[2].issue == nil)
}

@MainActor @Test func sessionsStoppedOnALimitSayWhenTheyCanGoOn() throws {
    let store = AccountStore(demo: true)
    let now = Date().timeIntervalSince1970
    let work = store.config.accounts[0], studio = store.config.accounts[1]
    let live = try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: ["pid": 1, "id": "s1", "status": "idle", "started": 1, "agent": "claude"]))
    store.sessions.live = [live]

    // A reset known only in words: the reading says the longest it could take, and so does the phone.
    store.usage[work.id] = (store.usage[work.id] ?? AccountUsage(windows: [])).hitting("five_hour", at: now)
    store.usage[work.id]?.windows.removeAll { $0.id == "seven_day" }
    store.usage[work.id]?.windows[0].resetsAt = now + 5 * 3600
    store.limitHits = [work.id: ("five_hour", now, ["s1", "gone"])]
    store.usage[studio.id] = AccountUsage(windows: [UsageWindow(id: "five_hour", label: "5-hour", percent: 100, resetsAt: now + 3600)])
    let limits = store.sessionLimits(now: now)
    #expect(limits["s1"] == SessionLimit(window: "five_hour", accountID: work.id, until: now + 5 * 3600, worstCase: true))
    let wire = WireBuilders.session(live, store: store, finished: [])
    #expect(wire.limit?.accountID == work.id)
    // The first account back is the one sessions can move to, not only their own.
    let waiting = store.waitingSummary(limits: limits, now: now)
    #expect(waiting?.account == studio.name && waiting?.at == now + 3600 && waiting?.worstCase == false)

    // A known reset isn't a worst case.
    store.usage[work.id]?.windows[0].resetsAt = now + 1800
    #expect(store.sessionLimits(now: now)["s1"]?.worstCase == false)
    #expect(store.waitingSummary(limits: store.sessionLimits(now: now), now: now)?.account == work.name)

    // Room again: nobody is waiting, whatever the last reply said.
    store.usage[work.id] = AccountUsage(windows: [UsageWindow(id: "five_hour", label: "5-hour", percent: 10, resetsAt: now + 3600)])
    #expect(store.sessionLimits(now: now).isEmpty)
    #expect(store.waitingSummary(limits: [:], now: now) == nil)
    // A session that isn't running any more waits for nothing.
    #expect(store.waitingSummary(limits: ["gone": SessionLimit(window: "five_hour", accountID: work.id, until: now + 1)], now: now) == nil)
}

@MainActor @Test func theStateSaysWhatComesNextPerLoginAndEveryHeldMove() async throws {
    let store = AccountStore(demo: true)
    let accounts = store.config.accounts.filter { $0.provider == .claude }
    let now = Date().timeIntervalSince1970
    let work = accounts[0], studio = accounts[1], weekend = accounts[2]
    for account in accounts { store.usage[account.id] = AccountUsage(windows: [UsageWindow(id: "five_hour", label: "5-hour", percent: 10, resetsAt: now + 3600)]) }
    store.activeIDs[.claude] = work.id
    store.busyLogins = ["mac": work.id, "other": studio.id]
    let next = store.nextMoves(now: now)
    #expect(next.map(\.from) == [work.name, studio.name])
    #expect(next.allSatisfy { $0.to == weekend.name && $0.atPercent == Int(store.config.moveAt.rounded()) && !$0.held && $0.minutes == nil })

    let since = Date()
    store.heldMoves = ["mac": .init(slot: "mac", from: work.id, to: weekend.id, share: false, reason: "Waiting for its sessions to pause.", since: since),
                       "other": .init(slot: "other", from: studio.id, to: weekend.id, share: false, reason: "Waiting.", since: since.addingTimeInterval(-60))]
    let state = Autopilot.state(store, log: "")
    #expect(state.held?.map(\.from) == [studio.name, work.name] && state.pending == state.held?.first)
    #expect(state.next?.first { $0.id == work.id }?.held == true)
    #expect(state.swapAt == Int(store.config.moveAt.rounded()) && state.followFable == true && state.fableMode == false)
    store.config.swapAt = 80
    #expect(Autopilot.state(store, log: "").swapAt == 80 && store.nextMoves(now: now).allSatisfy { $0.atPercent == 80 })
    store.config.swapAt = nil
    // Nothing on the wire names a Keychain slot.
    #expect(state.held?.allSatisfy { !$0.id.contains("other") && !$0.id.contains("mac") } == true)

    store.setAuto(work.id, false)
    #expect(store.nextMoves(now: now).map(\.from) == [studio.name])
    store.config.smartMode = false
    #expect(store.nextMoves(now: now).isEmpty)
}

@MainActor @Test func recordsGiveAMoveItsReasonAndOldLinesStayReasonless() throws {
    let store = AccountStore(demo: true)
    let at = try Date("2026-10-18T09:02:00", strategy: AutopilotLog.stamp).timeIntervalSince1970
    let log = """
    2026-10-18T08:00:00 Old → Line: moved.
    2026-10-18T08:30:00 Spent is full and no free account has room.
    2026-10-18T08:40:00 Work → Personal: this login moved recently, so a move only for priority waits.
    2026-10-18T09:00:00 Work → Personal: waiting for its sessions to pause (quiet 12s of 300s).
    2026-10-18T09:01:00 Work → Personal: waiting for its sessions to pause (quiet 72s of 300s).
    2026-10-18T09:02:00 Work → Personal: moved.
    """
    store.recordRotation(RotationRecord(at: at, kind: .moved, from: "Work", to: "Personal", reason: "5-hour 96%", sessions: [.init(id: "s1", project: "side-a")]))
    store.recordRotation(RotationRecord(at: at + 60, kind: .stuck, from: "Personal", reason: "Weekly 100%"))
    let rows = Autopilot.decisions(log, records: store.rotationRecords.records, store: store)
    #expect(rows[0].kind == .stuck && rows[0].reason == "Weekly 100%")
    #expect(rows[1].title == "Work → Personal" && rows[1].reason == "5-hour 96%" && rows[1].sessions == [.init(sessionID: "s1", title: "side-a")])
    // The line the record stands for is gone; the quiet seconds count as one wait.
    #expect(rows.filter { $0.kind == .moved }.count == 2)
    #expect(rows.filter { $0.kind == .waiting }.count == 1)
    #expect(rows.first { $0.from == "Old" }?.reason == "")
    #expect(rows.first { $0.kind == .stuck && $0.from == "Spent" }?.reason == "")
    #expect(rows.first { $0.kind == .priorityWait }?.title == "Holding Work → Personal")
}

@Test func recordsOutliveARelaunchAndKeepTheirNewest() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rotation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("rotation.json")
    var records = RotationRecords(url: url)
    for index in 0..<(RotationRecords.limit + 5) { records.add(RotationRecord(at: Double(index), kind: .moved, from: "A", reason: "")) }
    let again = RotationRecords(url: url)
    #expect(again.records.count == RotationRecords.limit && again.records.first?.at == 5)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

/// `autopilot.update` goes out when the state changed, once, and the snapshot has it for a phone starting over.
@MainActor @Test func aChangeReachesThePhoneAsAnEventAndInTheSnapshot() async throws {
    let store = AccountStore(demo: true)
    let queue = DispatchQueue(label: "test.hub")
    let hub = EventHub(queue: queue, epoch: "e1", snapshot: { { seq, epoch in StateSnapshot(seq: seq, epoch: epoch) } }, hello: {
        Hello(app: "", build: 0, mac: MacInfo(id: "", name: ""), capabilities: [], epoch: "e1", serverTime: 0, endpoints: Endpoints(tailnet: ""), keyID: "")
    })
    let events = RemoteEvents(store: store, hub: hub, queue: queue)
    events.start()
    defer { events.stop() }
    #expect(events.snapshot()(0, "e1").autopilot?.followFable == true)
    func updates() -> [AutopilotState] { hub.recorded(after: 0).compactMap { if case .autopilotUpdate(let state) = $0 { state } else { nil } } }

    events.autopilotChanged()
    try await Task.sleep(for: .milliseconds(1400))
    #expect(updates().isEmpty, "nothing changed")

    store.config.followFable = false
    events.autopilotChanged()
    for _ in 0..<100 where updates().isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(updates().last?.followFable == false && updates().count == 1)
    #expect(events.snapshot()(0, "e1").autopilot?.followFable == false)
}

/// A rotation push goes only to a phone whose latest hello said it can show one, and which asked for it; what the phone
/// said is kept, since pushes go out while its socket is closed. The relay sees a category and a sealed blob.
@MainActor @Test func rotationPushesGoOnlyToPhonesThatAdvertiseThem() async throws {
    let store = AccountStore(demo: true)
    let remote = store.remote
    func device(_ id: String) -> RemoteDevice {
        RemoteDevice(id: id, name: id, model: "iPhone", system: "iOS", app: "1.0", build: 1, hash: Data(count: 32), secretHash: "s", created: 0)
    }
    try remote.devices.add(device("old"), replacing: nil)
    try remote.devices.add(device("new"), replacing: nil)
    remote.noteCapabilities("new", [.events, .rotation])
    remote.noteCapabilities("old", [.events])
    func saved(_ id: String) -> RemoteDevice { remote.devices.devices.first { $0.id == id }! }
    #expect(RemotePush.showsRotation(saved("new")) && !RemotePush.showsRotation(saved("old")))
    remote.noteCapabilities("new", [.events])
    #expect(!RemotePush.showsRotation(saved("new")))
    remote.noteCapabilities("gone", [.rotation])
    #expect(remote.devices.devices.count == 2)

    let key = PushKey(key: SymmetricKey(size: .bits256), keyID: Data([1, 2, 3, 4]))
    let payload = RemotePushPayload.rotation(title: "Now on Personal", body: "5-hour 96%", account: nil, resetsAt: nil, mac: "m", now: 1)
    let sealed = try PushEnvelope.seal(RemotePushPayload.encoded(payload), with: key, category: .rotation, collapseID: "rotation", deviceID: "new")
    #expect(!sealed.contains("Personal") && !String(decoding: Data(base64URL: sealed) ?? Data(), as: UTF8.self).contains("Personal"))
    #expect(try JSONDecoder().decode(PushPayload.self, from: PushEnvelope.open(sealed, with: key, category: .rotation, collapseID: "rotation", deviceID: "new")) == payload)
    #expect(throws: (any Error).self) { try PushEnvelope.open(sealed, with: key, category: .limit, collapseID: "rotation", deviceID: "new") }
}

/// Live Limits doesn't document `prompt_cache`, so anything but its usual shape says nothing and Move Now keeps its words.
@MainActor @Test func aMovesCacheCostIsReadOrLeftOutSilently() throws {
    let store = AccountStore(demo: true)
    let live = store.root.appendingPathComponent("runtime/live")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    let name = "slot-\(UUID().uuidString)"
    let url = live.appendingPathComponent("\(name).json")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(store.recacheTokens(slot: name) == nil)
    for (text, tokens) in [(#"{"prompt_cache":{"warm":true,"expires_at":1,"recache_tokens_if_cold":120000}}"#, 120_000 as Int?),
                           (#"{"prompt_cache":{"warm":false,"recache_tokens_if_cold":120000}}"#, nil),
                           (#"{"prompt_cache":"warm"}"#, nil), (#"{"prompt_cache":{"warm":true,"recache_tokens_if_cold":"lots"}}"#, nil),
                           (#"{"rate_limits":{}}"#, nil), ("not json", nil)] {
        try Data(text.utf8).write(to: url)
        #expect(store.recacheTokens(slot: name) == tokens, "\(text)")
    }
    #expect(store.recacheTokens(slot: "../../config") == nil)
}

/// The room sums what Autopilot may use, and shows no date while the data is thin.
@MainActor @Test func theOutlookHidesItsDateWhenTheDataIsThin() throws {
    let store = AccountStore(demo: true)
    let now = Date().timeIntervalSince1970
    var outlook = RotationOutlook.build(store, now: now)
    let claude = try #require(outlook.rooms.first { $0.provider == .claude })
    #expect(claude.accounts == 3 && claude.limited == 1)
    // Never read, in the demo: nothing to take a pace from.
    #expect(claude.runsOut == nil)
    #expect(outlook.rooms.allSatisfy { $0.runsOut == nil })

    // Read just now, with real weeks of activity, and burning fast.
    let claudes = store.config.accounts.filter { $0.provider == .claude }
    let format = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
    let spans = (0..<30).map { offset in
        ActivitySpan(date: Date(timeIntervalSince1970: now - Double(offset) * 86_400).formatted(format), hours: Array(repeating: 10, count: 24))
    }
    store.report = UsageReport(days: [], projects: [], models: [], activity: spans)
    for account in claudes {
        store.usage[account.id] = AccountUsage(windows: [UsageWindow(id: "seven_day", label: "Weekly", percent: 90, resetsAt: now + 3.5 * 86_400)])
        store.readAt[account.id] = Date()
    }
    outlook = RotationOutlook.build(store, now: now)
    let room = try #require(outlook.rooms.first { $0.provider == .claude })
    #expect(room.weeklyLeft == 10)
    let date = try #require(room.runsOut)
    #expect(date > now && date < now + 86_400)
    #expect(date.truncatingRemainder(dividingBy: 900) == 0)
    // Codex has no activity to take a rhythm from.
    #expect(outlook.rooms.first { $0.provider == .codex }?.runsOut == nil)

    // One account's reading failing or stale takes the date away, not the room.
    store.health[claudes[0].id] = .offline
    #expect(RotationOutlook.build(store, now: now).rooms.first { $0.provider == .claude }?.runsOut == nil)
    store.health[claudes[0].id] = nil
    store.readAt[claudes[1].id] = Date(timeIntervalSince1970: now - 7200)
    #expect(RotationOutlook.build(store, now: now).rooms.first { $0.provider == .claude }?.runsOut == nil)
}
