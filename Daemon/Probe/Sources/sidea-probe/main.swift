import CryptoKit
import Foundation
import SideAProtocol
import SideARemoteKit

// sidea-probe --link URL [--connect HOST:PORT | --relay-only [--relay-url URL]] [--agent PREFIX] --cwd DIR
//
// Pairs with a sidead (the link is what `sidead pair` prints; --connect replaces its address, for a daemon behind a port
// forward), then walks the phone's path: hello, projects, start a hosted session, wait for it to register, read its
// transcript, reply, and watch the new messages arrive on the events socket. With --agent, it then has a stand-in agent
// ask for permission twice and answers Allow and Deny (Permissions.swift). Exits 0 only when every step held.

struct Failure: Error, CustomStringConvertible { let description: String }

// swiftlint:disable:next print_in_app -- the probe's output is what scripts/linux-e2e.sh reads.
func say(_ text: String) { print("PROBE \(text)"); fflush(stdout) }

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(description: message) }
    say("ok   \(message)")
}

actor Token: CredentialStore {
    var value: String?
    var secret: Data?
    func token(for macID: String) async throws -> String? { value }
    func setToken(_ token: String?, for macID: String) async throws { value = token }
    /// The pairing's device secret: after the pairing ticket is spent, it is how a phone is let through the relay.
    func relaySecret(for macID: String) async throws -> Data? { secret }
    func keep(secret: Data) { self.secret = secret }
}

/// A software stand-in for the phone's two Secure Enclave keys.
struct Keys {
    let unlock = P256.Signing.PrivateKey()
    let biometric = P256.Signing.PrivateKey()
    var unlockKey: String { unlock.publicKey.x963Representation.base64URL }
    var confirmKey: String { biometric.publicKey.x963Representation.base64URL }

    func sign(macID: String, deviceID: String, purpose: ConfirmPurpose, subject: String, faceID: Bool) throws -> String {
        let at = Int(Date().timeIntervalSince1970)
        let text = try ConfirmMessage.text(macID: macID, deviceID: deviceID, purpose: purpose, subject: subject, at: at)
        let signature = try (faceID ? biometric : unlock).signature(for: Data(text.utf8))
        return ConfirmSignature(at: at, signer: faceID ? .confirm : .unlock, signature: signature.derRepresentation).headerValue
    }
}

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let at = arguments.firstIndex(of: name), at + 1 < arguments.count else { return nil }
    return arguments[at + 1]
}

/// What `--save` keeps so a later `--resume` can show the pairing survived a daemon restart.
struct SavedPairing: Codable { let endpoint: Endpoint; let token: String }

/// `--resume FILE [--connect HOST:PORT]`: the saved token is still accepted, so the pairing survived.
func resume(_ path: String) async throws {
    let saved = try JSONDecoder().decode(SavedPairing.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var endpoint = saved.endpoint
    if let address = option("--connect"), let url = URL(string: "https://\(address)") {
        endpoint = Endpoint(macID: endpoint.macID, baseURL: url, serverKeyHash: endpoint.serverKeyHash, name: endpoint.name, os: endpoint.os)
    }
    let info = ClientInfo(version: "1.0", build: 100_000, system: "macOS probe", capabilities: [.events, .transcriptStream, .hosted])
    let credentials = Token()
    try await credentials.setToken(saved.token, for: endpoint.macID)
    let client = RemoteClient(endpoint: endpoint, credentials: credentials, info: info)
    let hello = try await client.hello()
    try require(hello.paired == true, "after the restart the daemon still knows this phone (paired=\(String(describing: hello.paired)))")
    let sessions = try await client.sessions()
    try require(true, "sessions list answers (\(sessions.sessions.count) sessions)")
    say("DONE")
}

func run() async throws {
    if let path = option("--resume") { return try await resume(path) }
    guard let link = option("--link").flatMap(URL.init(string:)), let found = PairingClient.Invitation(url: link), let cwd = option("--cwd") else {
        throw Failure(description: "usage: sidea-probe --link URL [--connect HOST:PORT | --relay-only [--relay-url URL]] --cwd DIR")
    }
    // --relay-only drops every direct address, so the phone can only reach the daemon through the relay's tunnel;
    // --relay-url replaces the relay's address in the link (a daemon in a container names it from the container's side).
    let viaRelay = CommandLine.arguments.contains("--relay-only")
    // The kit refuses a relay it can't call https or local, so the link's `i` and `p` are read here and the address comes from --relay-url.
    let fields = Dictionary(uniqueKeysWithValues: (link.fragment ?? "").split(separator: "&").compactMap { pair -> (String, String)? in
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    })
    let route = found.relay ?? option("--relay-url").flatMap(URL.init(string:)).flatMap { url in
        fields["i"].map { RelayRoute(url: url, installID: $0, ticket: fields["p"]) }
    }
    if viaRelay, route == nil { throw Failure(description: "the link has no relay (start sidead with --relay URL)") }
    let invitation = PairingClient.Invitation(address: viaRelay ? "" : option("--connect") ?? found.address, fp: found.fp, macName: found.macName,
                                              macID: found.macID, tailnet: nil, code: found.code, relay: route)
    let keys = Keys()
    let info = ClientInfo(version: "1.0", build: 100_000, system: "macOS probe", capabilities: [.events, .transcriptStream, .hosted])
    let device = DeviceInfo(name: "Probe", model: "Mac", system: "macOS", app: "1.0", build: 100_000, capabilities: info.capabilities)
    let pairing = PairingClient(invitation: invitation, device: device, confirmKey: keys.confirmKey, unlockKey: keys.unlockKey)

    say("pairing with \(invitation.address) (key \(invitation.fp.prefix(8)))")
    let attempt = try await pairing.start(info: info)
    say("comparison code \(attempt.comparisonCode): confirm it on the computer")
    let paired = try await pairing.wait(attempt)
    try require(paired.response.token.hasPrefix("sa1_"), "paired as \(paired.response.deviceID.prefix(8)), host is \(paired.response.mac.os?.rawValue ?? "?") headless=\(paired.response.mac.headless == true)")
    try require(paired.response.mac.os == .linux || paired.response.mac.os == .wsl, "the host says it is Linux")

    let credentials = Token()
    try await credentials.setToken(paired.response.token, for: paired.endpoint.macID)
    await credentials.keep(secret: paired.deviceSecret)
    let client = RemoteClient(endpoint: paired.endpoint, credentials: credentials, info: info)
    let macID = paired.endpoint.macID, deviceID = paired.response.deviceID
    if let path = option("--save") {
        try JSONEncoder().encode(SavedPairing(endpoint: paired.endpoint, token: paired.response.token)).write(to: URL(fileURLWithPath: path))
    }

    let hello = try await client.hello()
    try require(hello.capabilities.contains(.hosted) && hello.capabilities.contains(.transcriptStream), "hello lists hosted and transcript.stream (\(hello.capabilities.map(\.rawValue).sorted().joined(separator: ", ")))")

    let accounts = try await client.accounts().accounts
    try require(true, "accounts list answers (\(accounts.count): \(accounts.map { "\($0.name)" }.joined(separator: ", ")))")

    let projects = try await client.projects().projects
    try require(projects.contains { $0.path == cwd }, "the folder \(cwd) is a project")

    let start = StartHosted(cwd: cwd, agent: .claude, prompt: "first message from the probe")
    let proof = try keys.sign(macID: macID, deviceID: deviceID, purpose: .settings, subject: ConfirmMessage.subject(start: start), faceID: false)
    let hosted: HostedSession = try await client.post("/v1/hosted", json: start, confirm: proof)
    try require(hosted.name.hasPrefix("sa-") && hosted.alive, "started hosted session \(hosted.name)")
    // --start-only: the program behind the session is a real agent that can't answer here (it wants a sign-in), so stop once it runs.
    if CommandLine.arguments.contains("--start-only") {
        try await Task.sleep(for: .seconds(3))
        try require(try await client.hosted().hosted.contains { $0.name == hosted.name && $0.alive }, "the hosted session is still alive after 3 s")
        say("DONE")
        return
    }

    var session: RemoteSession?
    for _ in 0..<150 where session == nil {
        let list = try await client.sessions()
        session = list.sessions.first { $0.hosted == hosted.name && $0.conversationID != nil && $0.status == .idle }
        if session == nil { try await Task.sleep(for: .milliseconds(200)) }
    }
    guard let live = session else { throw Failure(description: "the session never showed as idle") }
    try require(true, "session \(live.id.prefix(8)) is \(live.status.rawValue), in \(live.cwd ?? "?"), abilities \(live.abilities.map(\.rawValue).sorted().joined(separator: ","))")

    var page = try await client.transcript(live.id)
    try require(page.messages.map { $0.role.rawValue } == ["user", "assistant"], "transcript has the prompt and the answer: \(page.messages.compactMap(\.text))")
    try require(page.messages.last?.text == "Echo: first message from the probe", "the answer echoes the prompt")

    let events = try await client.socket("/v1/ws/events")
    let encoder = JSONEncoder()
    try await events.send(.text(String(decoding: try encoder.encode(ClientMessage.hello(epoch: nil, lastSeq: nil, capabilities: [.events, .transcriptStream])), as: UTF8.self)))
    var greeted = 0
    while greeted < 2 {
        if case .text(let text) = try await events.receive(), let kind = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"] as? String {
            say("event \(kind)")
            if kind == "welcome" || kind == "snapshot" { greeted += 1 }
        }
    }
    try await events.send(.text(String(decoding: try encoder.encode(ClientMessage.subscribe(sessions: [live.id: page.after])), as: UTF8.self)))

    let reply = RemoteReply(text: "second message from the probe")
    let replyProof = try keys.sign(macID: macID, deviceID: deviceID, purpose: .action, subject: ConfirmMessage.subject(action: .reply, target: live.id, body: reply), faceID: true)
    let result: ReplyResult = try await client.post("/v1/sessions/\(live.id)/reply", json: reply, confirm: replyProof)
    try require(result.delivery == .typed, "reply delivered as \(result.delivery.rawValue)")

    var arrived = false
    let deadline = Date().addingTimeInterval(30)
    while !arrived, Date() < deadline {
        guard case .text(let text) = try await events.receive(), let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: Data(text.utf8)) else { continue }
        say("event \(envelope.event.type)")
        if case .transcriptAppend(let delta) = envelope.event, delta.messages.contains(where: { $0.text == "Echo: second message from the probe" }) { arrived = true }
    }
    try require(arrived, "the transcript's new messages arrived on the events socket")
    events.close(code: 1000, reason: nil)

    page = try await client.transcript(live.id)
    try require(page.messages.count == 4 && page.messages.last?.text == "Echo: second message from the probe", "the transcript now has four messages")
    let list = try await client.hosted()
    try require(list.hosted.contains { $0.name == hosted.name && $0.sessionID == live.id }, "the hosted list names the session")

    let end = try keys.sign(macID: macID, deviceID: deviceID, purpose: .action, subject: ConfirmMessage.subject(action: .endHosted, target: hosted.name), faceID: false)
    try await client.endHosted(hosted.name, confirm: end)
    try require(try await client.hosted().hosted.isEmpty, "the hosted session ended")
    if let agent = option("--agent") { try await permissions(client: client, keys: keys, macID: macID, deviceID: deviceID, agent: agent) }
    say("DONE")
}

do { try await run() } catch {
    FileHandle.standardError.write(Data("PROBE FAILED \(error)\n".utf8))
    exit(1)
}
