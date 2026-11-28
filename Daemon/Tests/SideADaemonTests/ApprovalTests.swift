import Crypto
import Foundation
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

// A permission request from Claude Code, as the hook sends it, reaching a paired phone and being answered. The hook's side is a
// plain socket client; the phone's is the HTTP and events socket it uses on the Mac, with real confirm signatures.

struct ApprovalRig {
    let directory: URL
    let work: URL
    let approvals: Approvals
    let socket: String

    init(alive: @escaping @Sendable (Int) -> Bool = { _ in true }, maxOpen: Int = 100, directory: URL? = nil, socket: String? = nil) throws {
        self.directory = try directory ?? temporaryDirectory("ap")
        work = self.directory.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        self.socket = socket ?? self.directory.appendingPathComponent("island.sock").path
        let socket = self.socket
        var settings = Approvals.Settings(socket: socket, accountName: { $0 == "work" ? "Work" : nil })
        settings.alive = alive
        settings.maxOpen = maxOpen
        approvals = Approvals(settings: settings)
    }

    func clean() { try? FileManager.default.removeItem(at: directory) }

    /// What `island_hook.py` sends for a PermissionRequest.
    func message(tool: String = "Bash", input: [String: Any] = ["command": "npm test", "description": "Run the tests"], pid: Int = 4242,
                 session: String = "sess-1", headless: Bool = false, event: String = "PermissionRequest", agent: String = "claude",
                 slot: String = "mac", suggestions: Bool = true) -> [String: Any] {
        var request: [String: Any] = ["session_id": session, "cwd": work.path, "permission_mode": "default", "hook_event_name": event,
                                      "tool_name": tool, "tool_input": input]
        if suggestions {
            request["permission_suggestions"] = [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                                  "rules": [["toolName": tool, "ruleContent": "npm test:*"]]]]
        }
        return ["v": 1, "agent": agent, "pid": pid, "slot": slot, "headless": headless, "request": request]
    }
}

struct Phone {
    let phone: FakePhone
    let token: String
    let deviceID: String
    let http: TestConnection
    let daemon: SideADaemon

    func call(_ method: String, _ path: String, body: Data = Data(), confirm: String? = nil, key: String = UUID().uuidString) async throws -> Answer {
        var headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json", "Idempotency-Key": key]
        if let confirm { headers[ConfirmSignature.header] = confirm }
        return try await http.request(method, path, headers: headers, body: body)
    }

    func requests() async throws -> [RemoteRequest] { try await call("GET", "/v1/requests").json(RequestList.self).requests }

    /// POSTs an answer, signed for the request when `signer` says so.
    func answer(_ rid: String, _ answer: RemoteAnswer, mode: PermissionMode? = nil, signer: Signer = .none) async throws -> Answer {
        let body = AnswerBody(answer: answer, mode: mode)
        let subject = try mode.map { try ConfirmMessage.subject(requestID: rid, allowMode: $0) } ?? ConfirmMessage.subject(requestID: rid, answer: answer)
        var confirm: String?
        switch signer {
        case .none: break
        case .unlock: confirm = try phone.confirm(purpose: .allow, subject: try #require(subject))
        case .faceID: confirm = try phone.confirm(purpose: .allow, subject: try #require(subject), biometric: true)
        }
        return try await call("POST", "/v1/requests/\(rid)/answer", body: JSONEncoder().encode(body), confirm: confirm)
    }

    enum Signer { case none, unlock, faceID }

    /// The events socket, past its welcome and snapshot.
    func events() async throws -> TestConnection {
        let socket = try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash)
        #expect(try await socket.upgrade("/v1/ws/events", token: token).status == 101)
        let hello = try JSONEncoder().encode(ClientMessage.hello(epoch: nil, lastSeq: nil, capabilities: [.events]))
        try await socket.send(text: String(decoding: hello, as: UTF8.self))
        _ = try await socket.event(); _ = try await socket.event()
        return socket
    }
}

extension TestConnection {
    /// The next event of this type, skipping others.
    func event(of type: String) async throws -> [String: Any] {
        // swiftlint:disable:next unbounded_poll_in_tests -- not a poll: `event()` blocks and throws when the socket closes.
        while true {
            let next = try await event()
            if next["type"] as? String == type { return (next["data"] as? [String: Any]) ?? [:] }
        }
    }
}

private func withPhone<T>(alive: @escaping @Sendable (Int) -> Bool = { _ in true }, maxOpen: Int = 100,
                          _ body: (ApprovalRig, Phone) async throws -> T) async throws -> T {
    let rig = try ApprovalRig(alive: alive, maxOpen: maxOpen)
    defer { rig.clean() }
    return try await withDaemon(services: ApprovalServices(approvals: rig.approvals)) { daemon, _ in
        let phone = FakePhone()
        let paired = try await phone.pair(with: daemon, pin: daemon.identity.spkiHash)
        let http = try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash)
        return try await body(rig, Phone(phone: phone, token: paired.token, deviceID: paired.deviceID, http: http, daemon: daemon))
    }
}

/// The one request the phone is told about, with the hook still waiting on it.
private func ask(_ rig: ApprovalRig, _ phone: Phone, _ message: [String: Any]) async throws -> (hook: HookClient, request: RemoteRequest) {
    let hook = try HookClient(path: rig.socket)
    let before = try await phone.requests().count
    hook.send(message)
    #expect(await eventually { (try? await phone.requests().count) == before + 1 })
    return (hook, try #require(try await phone.requests().last))
}

@Test func aPermissionRequestIsOfferedToThePhoneAndItsAllowAnswersTheHook() async throws {
    try await withPhone { rig, phone in
        let socket = try await phone.events()
        let hook = try HookClient(path: rig.socket)
        hook.send(rig.message(slot: "work"))
        let added = try await socket.event(of: "request.add")
        let request = try JSONDecoder().decode(RemoteRequest.self, from: JSONSerialization.data(withJSONObject: added))
        #expect(request.tool == "Bash" && request.action == .command("npm test") && request.agent == .claude)
        #expect(request.sessionID == "sess-1" && request.project == "work" && request.accountName == "Work" && !request.headless)
        #expect(request.allowGate == .unlock && request.risk != .destructive)
        #expect(request.answers == [.allow, .always, .deny, .terminal])
        #expect(request.suggestions.map(\.title) == ["Always allow Bash(npm test:*) in this project", "Always allow Bash(npm test:*) for this session"])
        #expect(request.handBackAt == nil)

        #expect(try await phone.requests().map(\.id) == [request.id])
        #expect(try await phone.call("GET", "/v1/requests/\(request.id)").json(RemoteRequest.self).id == request.id)
        #expect(try await phone.call("GET", "/v1/state").json(StateSnapshot.self).requests.map(\.id) == [request.id])

        // An Allow takes an unlocked phone; nothing is sent to the hook before it has one.
        let bare = try await phone.answer(request.id, .allow(confirmDestructive: false))
        #expect(bare.status == 401 && bare.errorCode == "confirm_required")
        let signed = try await phone.answer(request.id, .allow(confirmDestructive: false), signer: .unlock)
        #expect(signed.status == 200)
        let resolution = try signed.json(RequestResolution.self)
        #expect(resolution.by == .device && resolution.answer == .allow && resolution.deviceID == phone.deviceID && resolution.deviceName == "Test iPhone")
        #expect(await answer(of: hook)?["behavior"] as? String == "allow")
        let resolved = try await socket.event(of: "request.resolve")
        #expect(resolved["requestID"] as? String == request.id && resolved["by"] as? String == "device")
        #expect(try await phone.requests().isEmpty)

        let late = try await phone.answer(request.id, .deny(message: nil))
        #expect(late.status == 409 && late.errorCode == "already_resolved")
        #expect(try await phone.call("GET", "/v1/requests/\(request.id)").status == 404)
        hook.close(); await socket.close()
    }
}

@Test func aDenyNeedsNoProofAndCarriesItsWordsToTheAgent() async throws {
    try await withPhone { rig, phone in
        let (hook, request) = try await ask(rig, phone, rig.message())
        let said = try await phone.answer(request.id, .deny(message: "Not that one, use the staging script."))
        #expect(said.status == 200)
        #expect(try said.json(RequestResolution.self).answer == .deny)
        let line = try #require(await answer(of: hook))
        #expect(line["behavior"] as? String == "deny" && line["message"] as? String == "Not that one, use the staging script.")

        let (second, plain) = try await ask(rig, phone, rig.message())
        #expect(try await phone.answer(plain.id, .deny(message: nil)).status == 200)
        #expect(await answer(of: second)?["message"] as? String == "The user denied this in Side A.")
        // Handing it back is the third answer a request takes: Claude Code's own prompt shows.
        let (third, handed) = try await ask(rig, phone, rig.message())
        #expect(try await phone.answer(handed.id, .terminal).status == 200)
        #expect(await answer(of: third)?["behavior"] as? String == "ask")
        for client in [hook, second, third] { client.close() }
    }
}

@Test func aPlainReadInsideTheProjectIsAllowedFromALockedPhoneButAnythingElseNeedsUnlock() async throws {
    try await withPhone { rig, phone in
        let (hook, read) = try await ask(rig, phone, rig.message(tool: "Read", input: ["file_path": rig.work.appendingPathComponent("README.md").path], suggestions: false))
        #expect(read.allowGate == .lockScreen)
        #expect(try await phone.answer(read.id, .allow(confirmDestructive: false)).status == 200)
        #expect(await answer(of: hook)?["behavior"] as? String == "allow")

        let (secret, env) = try await ask(rig, phone, rig.message(tool: "Read", input: ["file_path": rig.work.appendingPathComponent(".env").path], suggestions: false))
        // A secret is never read from a locked phone: reading `.env` is rated destructive, so it asks for Face ID.
        #expect(env.allowGate == .biometric)
        #expect(try await phone.answer(env.id, .allow(confirmDestructive: false)).errorCode == "confirm_required")
        #expect(try await phone.answer(env.id, .deny(message: nil)).status == 200)
        hook.close(); secret.close()
    }
}

@Test func aRequestThatBecameHarderToApproveSinceThePhoneSawItIsToldSoInsteadOfAskedForTheOldProof() async throws {
    try await withPhone { rig, phone in
        let notes = rig.work.appendingPathComponent("notes.md")
        try Data("plain".utf8).write(to: notes)
        let (hook, request) = try await ask(rig, phone, rig.message(tool: "Read", input: ["file_path": notes.path], suggestions: false))
        #expect(request.allowGate == .lockScreen)
        // Between the phone seeing it and the Allow, the file became a link to a secret.
        try FileManager.default.removeItem(at: notes)
        try Data("KEY=1".utf8).write(to: rig.work.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(at: notes, withDestinationURL: rig.work.appendingPathComponent(".env"))
        let late = try await phone.answer(request.id, .allow(confirmDestructive: false))
        #expect(late.status == 409 && late.errorCode == "gate_changed")
        let details = try #require((try JSONSerialization.jsonObject(with: late.body) as? [String: Any])?["error"] as? [String: Any])?["details"] as? [String: String]
        #expect(details?["gate"] == "biometric")
        _ = try await phone.requests()
        #expect(try await phone.answer(request.id, .allow(confirmDestructive: false)).status == 401)
        #expect(try await phone.answer(request.id, .deny(message: nil)).status == 200)
        hook.close()
    }
}

@Test func aDestructiveRequestNeedsFaceIDAndTheUnlockKeyIsNotEnough() async throws {
    try await withPhone { rig, phone in
        let (hook, request) = try await ask(rig, phone, rig.message(input: ["command": "rm -rf /var/lib/important"], suggestions: true))
        #expect(request.risk == .destructive && request.allowGate == .biometric)
        // Never offered a rule that outlives the answer.
        #expect(request.suggestions.isEmpty)
        let unlocked = try await phone.answer(request.id, .allow(confirmDestructive: true), signer: .unlock)
        #expect(unlocked.status == 401 && unlocked.errorCode == "confirm_required")
        #expect(try await phone.answer(request.id, .allow(confirmDestructive: true)).status == 401)
        let face = try await phone.answer(request.id, .allow(confirmDestructive: false), signer: .faceID)
        #expect(face.status == 200)
        #expect(await answer(of: hook)?["behavior"] as? String == "allow")
        hook.close()
    }
}

@Test func aSignatureForAnotherAnswerOrAnotherRequestIsRefused() async throws {
    try await withPhone { rig, phone in
        let (hook, request) = try await ask(rig, phone, rig.message())
        let (other, second) = try await ask(rig, phone, rig.message(session: "sess-2"))
        // A signed Allow for the first can't be replayed on the second.
        let subject = try #require(try ConfirmMessage.subject(requestID: request.id, answer: .allow(confirmDestructive: false)))
        let header = try phone.phone.confirm(purpose: .allow, subject: subject)
        let body = try JSONEncoder().encode(AnswerBody(answer: .allow(confirmDestructive: false)))
        let replayed = try await phone.call("POST", "/v1/requests/\(second.id)/answer", body: body, confirm: header)
        #expect(replayed.status == 401 && replayed.errorCode == "confirm_invalid")
        #expect(try await phone.requests().count == 2)
        for rid in [request.id, second.id] { #expect(try await phone.answer(rid, .deny(message: nil)).status == 200) }
        hook.close(); other.close()
    }
}

@Test func anAlwaysRuleAndAnAcceptEditsModeTravelBackToClaudeCode() async throws {
    try await withPhone { rig, phone in
        let (hook, request) = try await ask(rig, phone, rig.message())
        let rule = try #require(request.suggestions.first)
        #expect(try await phone.answer(request.id, .always(suggestionID: rule.id)).errorCode == "confirm_required")
        #expect(try await phone.answer(request.id, .always(suggestionID: rule.id), signer: .unlock).status == 200)
        let line = try #require(await answer(of: hook))
        let permissions = try #require(line["permissions"] as? [[String: Any]])
        #expect(line["behavior"] as? String == "allow" && permissions.first?["type"] as? String == "addRules" && permissions.first?["destination"] as? String == "localSettings")

        let edit: [String: Any] = ["file_path": rig.work.appendingPathComponent("a.swift").path, "old_string": "a", "new_string": "b"]
        let (editing, change) = try await ask(rig, phone, rig.message(tool: "Edit", input: edit, suggestions: false))
        #expect(change.modes == [.acceptEdits] && change.answers.contains(.allowMode))
        #expect(try await phone.answer(change.id, .allow(confirmDestructive: false), mode: .acceptEdits).status == 401)
        #expect(try await phone.answer(change.id, .allow(confirmDestructive: false), mode: .acceptEdits, signer: .unlock).status == 200)
        let mode = try #require(await answer(of: editing))
        #expect(mode["behavior"] as? String == "allow" && mode["mode"] as? String == "acceptEdits")
        // A rule the request never offered is not one to take on a phone's word.
        let (third, plain) = try await ask(rig, phone, rig.message())
        #expect(try await phone.answer(plain.id, .always(suggestionID: "0000000000000000"), signer: .unlock).status == 422)
        #expect(try await phone.answer(plain.id, .answers([]), signer: .unlock).errorCode == "invalid_answer")
        hook.close(); editing.close(); third.close()
    }
}

@Test func aHookThatQuitsTakesItsRequestAwayAndTheRoutesAnswerWhatTheyShould() async throws {
    try await withPhone { rig, phone in
        let socket = try await phone.events()
        let (hook, request) = try await ask(rig, phone, rig.message())
        hook.close()
        let resolved = try await socket.event(of: "request.resolve")
        #expect(resolved["requestID"] as? String == request.id && resolved["by"] as? String == "sessionEnded" && resolved["answer"] == nil)
        #expect(try await phone.requests().isEmpty)
        #expect(try await phone.answer(request.id, .deny(message: nil)).status == 409)
        #expect(try await phone.answer(UUID().uuidString.lowercased(), .deny(message: nil)).status == 404)
        #expect(try await phone.answer("not-an-id", .deny(message: nil)).status == 404)
        #expect(try await phone.call("POST", "/v1/requests/\(request.id)/answer", body: Data("{".utf8)).status == 400)
        await socket.close()
    }
}

@Test func aHeadlessRequestIsHandedBackAfterTwoMinutesAndOneAnsweredInTheTerminalIsClosed() async throws {
    let gone = Flag()
    try await withPhone(alive: { _ in !gone.on }) { rig, phone in
        let socket = try await phone.events()
        let (headless, held) = try await ask(rig, phone, rig.message(session: "sdk", headless: true))
        let due = try #require(held.handBackAt)
        #expect(abs(due - held.arrivedAt - 120) < 1)
        await rig.approvals.sync([], now: Date(timeIntervalSince1970: due - 1))
        #expect(try await phone.requests().count == 1)
        await rig.approvals.sync([], now: Date(timeIntervalSince1970: due + 1))
        #expect(await answer(of: headless)?["behavior"] as? String == "ask")
        #expect(try await socket.event(of: "request.resolve")["by"] as? String == "handedBack")

        // Claude Code leaves the hook running when its own prompt is answered; the registry says the session moved on.
        let (hook, asked) = try await ask(rig, phone, rig.message(pid: 777, session: "s2"))
        let at = asked.arrivedAt
        func row(_ status: String, since: Double) throws -> LiveRow { try liveRow(["pid": 777, "id": "s2", "agent": "claude", "status": status, "since": since]) }
        await rig.approvals.sync([try row("waiting", since: at - 5)], now: Date(timeIntervalSince1970: at + 30))
        #expect(try await phone.requests().count == 1)
        // Out of "waiting" for less than half a second is not yet an answer.
        await rig.approvals.sync([try row("busy", since: at + 1)], now: Date(timeIntervalSince1970: at + 1.2))
        #expect(try await phone.requests().count == 1)
        await rig.approvals.sync([try row("busy", since: at + 1)], now: Date(timeIntervalSince1970: at + 2))
        #expect(await answer(of: hook)?["behavior"] as? String == "ask")
        #expect(try await socket.event(of: "request.resolve")["by"] as? String == "terminal")

        let (dead, _) = try await ask(rig, phone, rig.message(pid: 888, session: "s3"))
        gone.on = true
        await rig.approvals.sync([])
        #expect(await answer(of: dead)?["behavior"] as? String == "ask")
        #expect(try await phone.requests().isEmpty)
        for client in [headless, hook, dead] { client.close() }
        await socket.close()
    }
}

/// A row as the bridge's JSON gives it, which is what `LiveRow` reads.
func liveRow(_ object: [String: Any]) throws -> LiveRow {
    let data = try JSONSerialization.data(withJSONObject: object)
    let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(LiveRow(parsed))
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

@Test func whatThePhoneCantAnswerYetIsHandedStraightBackToTheTerminal() async throws {
    try await withPhone { rig, phone in
        let question: [String: Any] = ["questions": [["question": "Which one?", "header": "Pick", "multiSelect": false, "options": [["label": "A", "description": "a"], ["label": "B", "description": "b"]]]]]
        let cases: [[String: Any]] = [
            rig.message(tool: "AskUserQuestion", input: question, suggestions: false),
            rig.message(tool: "ExitPlanMode", input: ["plan": "1. Do the thing"], suggestions: false),
            rig.message(event: "Stop"),
            rig.message(agent: "codex"),
        ]
        for message in cases {
            let hook = try HookClient(path: rig.socket)
            hook.send(message)
            #expect(await answer(of: hook)?["behavior"] as? String == "ask")
            hook.close()
        }
        let broken = try HookClient(path: rig.socket)
        broken.sendRaw(Data("not json\n".utf8))
        #expect(await answer(of: broken)?["behavior"] as? String == "ask")
        #expect(try await phone.requests().isEmpty)
        broken.close()
    }
}

@Test func moreRequestsThanTheLimitAreHandedBackAndTheRestStayOpenInOrder() async throws {
    try await withPhone(maxOpen: 2) { rig, phone in
        let (first, one) = try await ask(rig, phone, rig.message(pid: 1, session: "a"))
        let (second, two) = try await ask(rig, phone, rig.message(pid: 2, session: "b"))
        let overflow = try HookClient(path: rig.socket)
        overflow.send(rig.message(pid: 3, session: "c"))
        #expect(await answer(of: overflow)?["behavior"] as? String == "ask")
        #expect(try await phone.requests().map(\.id) == [one.id, two.id])
        let rows = try [liveRow(["pid": 2, "id": "other", "agent": "claude", "status": "waiting"]),
                        liveRow(["pid": 9, "id": "a", "agent": "claude", "status": "waiting"]),
                        liveRow(["pid": 10, "id": "z", "agent": "claude", "status": "idle"])]
        let open = await rig.approvals.open(for: rows)
        #expect(open[rows[0].key] == [two.id] && open[rows[1].key] == [one.id] && open[rows[2].key] == nil)
        first.close(); second.close(); overflow.close()
    }
}

@Test func stoppingTheDaemonHandsEveryWaitingHookBackToItsTerminal() async throws {
    let rig = try ApprovalRig()
    defer { rig.clean() }
    let held = HookBox()
    try await withDaemon(services: ApprovalServices(approvals: rig.approvals)) { _, _ in
        let hook = try HookClient(path: rig.socket)
        hook.send(rig.message())
        #expect(await eventually { await rig.approvals.list().count == 1 })
        held.hook = hook
    }
    // The daemon went down inside withDaemon: the hook was told to ask in the terminal, and the socket is gone.
    #expect(await answer(of: try #require(held.hook))?["behavior"] as? String == "ask")
    #expect(throws: (any Error).self) { _ = try HookClient(path: rig.socket) }
}

final class HookBox: @unchecked Sendable { var hook: HookClient? }

// MARK: push

private func sealedPush(_ call: StubRelay.Call, _ daemon: SideADaemon, _ deviceID: String, category: PushCategory, collapse: String) async throws -> PushPayload {
    let body = try #require(try JSONSerialization.jsonObject(with: call.body) as? [String: Any])
    let sealed = try #require((body["sealed"] as? [String: String])?[deviceID])
    let device = try #require(await daemon.devices.device(id: deviceID))
    let key = PushKey(key: SymmetricKey(data: try #require(device.pushKey)), keyID: try #require(device.pushKeyID))
    return try JSONDecoder().decode(PushPayload.self, from: PushEnvelope.open(sealed, with: key, category: category, collapseID: collapse, deviceID: deviceID))
}

@Test func aWaitingRequestIsPushedSealedAndTakenAwayFromThePhonesThatDidNotAnswerIt() async throws {
    let stub = try StubRelay()
    defer { stub.shutdown() }
    let rig = try ApprovalRig()
    defer { rig.clean() }
    let directory = try temporaryDirectory("apush")
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = DaemonConfig(paths: DaemonPaths(state: directory))
    config.port = 0; config.discover = false; config.os = .linux
    config.relay = RelayConfig(url: stub.url)
    let daemon = try SideADaemon(config: config, services: ApprovalServices(approvals: rig.approvals))
    try await daemon.start()
    do {
        let fake = FakePhone(), other = FakePhone()
        let paired = try await fake.pair(with: daemon, pin: daemon.identity.spkiHash)
        let second = try await other.pair(with: daemon, pin: daemon.identity.spkiHash)
        for id in [paired.deviceID, second.deviceID] { _ = try await daemon.devices.update(id) { $0.push = PushRegistration(apnsToken: "ab12cd34") } }
        let phone = Phone(phone: fake, token: paired.token, deviceID: paired.deviceID, http: try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash),
                          daemon: daemon)
        let hook = try HookClient(path: rig.socket)
        hook.send(rig.message())
        #expect(await eventually { stub.calls.contains { $0.path == "/v1/send" } })
        let sent = try #require(stub.calls.first { $0.path == "/v1/send" })
        let request = try #require(try await phone.requests().first)
        let collapse = RelayHTTP.collapse(request.id)
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(body["kind"] as? String == "alert" && body["category"] as? String == "REQUEST" && body["level"] as? String == "time-sensitive")
        #expect(body["collapseId"] as? String == collapse && Set(body["devices"] as? [String] ?? []) == [paired.deviceID, second.deviceID])
        let payload = try await sealedPush(sent, daemon, paired.deviceID, category: .request, collapse: collapse)
        #expect(payload.t == PushKind.request.rawValue && payload.rid == request.id && payload.gate == .unlock && payload.body == "npm test")
        // The relay sees none of what the request is.
        #expect(!String(decoding: sent.body, as: UTF8.self).contains("npm test"))
        #expect(await eventually { Set(daemon.relay?.requests.showing(collapse) ?? []) == [paired.deviceID, second.deviceID] })

        // The phone that answered took its own notification away; the other one's goes by the relay.
        #expect(try await phone.answer(request.id, .deny(message: nil)).status == 200)
        #expect(await eventually { stub.calls.contains { $0.path == "/v1/send" && String(decoding: $0.body, as: UTF8.self).contains("\"dismiss\"") } })
        let last = try #require(stub.calls.last { $0.path == "/v1/send" })
        let removal = try #require(try JSONSerialization.jsonObject(with: last.body) as? [String: Any])
        #expect(removal["kind"] as? String == "dismiss" && removal["collapseId"] as? String == collapse && removal["devices"] as? [String] == [second.deviceID])
        hook.close()
        try await daemon.stop()
    } catch {
        // swiftlint:disable:next swallowed_try -- the test's own error is the one to report.
        try? await daemon.stop()
        throw error
    }
}

@Test func aRequestNobodyAnsweredReplacesItsNotificationWithWhatHappened() async throws {
    let stub = try StubRelay()
    defer { stub.shutdown() }
    let rig = try ApprovalRig()
    defer { rig.clean() }
    let directory = try temporaryDirectory("apush")
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = DaemonConfig(paths: DaemonPaths(state: directory))
    config.port = 0; config.discover = false; config.os = .linux
    config.relay = RelayConfig(url: stub.url)
    let daemon = try SideADaemon(config: config, services: ApprovalServices(approvals: rig.approvals))
    try await daemon.start()
    do {
        let paired = try await FakePhone().pair(with: daemon, pin: daemon.identity.spkiHash)
        _ = try await daemon.devices.update(paired.deviceID) { $0.push = PushRegistration(apnsToken: "ab12cd34") }
        let hook = try HookClient(path: rig.socket)
        hook.send(rig.message())
        #expect(await eventually { stub.calls.filter { $0.path == "/v1/send" }.count == 1 })
        #expect(await eventually { !(await rig.approvals.list().isEmpty) })
        let rid = try #require(await rig.approvals.list().first?.id)
        // The alert has to have been recorded as shown before it can be replaced.
        #expect(await eventually { daemon.relay?.requests.showing(RelayHTTP.collapse(rid)) == [paired.deviceID] })
        hook.close()
        #expect(await eventually { stub.calls.filter { $0.path == "/v1/send" }.count == 2 })
        let second = try #require(stub.calls.last { $0.path == "/v1/send" })
        let collapse = RelayHTTP.collapse(rid)
        let payload = try await sealedPush(second, daemon, paired.deviceID, category: .health, collapse: collapse)
        #expect(payload.t == PushKind.health.rawValue && payload.body == "The session ended")
        let sent = try #require(try JSONSerialization.jsonObject(with: second.body) as? [String: Any])
        #expect(sent["level"] as? String == "passive" && sent["sound"] as? Bool == false)
        try await daemon.stop()
    } catch {
        // swiftlint:disable:next swallowed_try -- the test's own error is the one to report.
        try? await daemon.stop()
        throw error
    }
}
