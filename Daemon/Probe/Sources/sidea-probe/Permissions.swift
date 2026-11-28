import Foundation
import SideAProtocol
import SideARemoteKit

/// A stand-in agent (Daemon/Tests/Fixtures/fake-claude-permission.py, never the real CLI) run through `--agent`, a command prefix such
/// as `docker exec NAME python3 /path/fake-claude-permission.py`. It runs the hook `sidead hooks on` installed, exactly as Claude Code
/// would, and prints one `RESULT {json}` line once the hook has answered.
final class StandIn: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let finished: AsyncStream<Void>

    init(prefix: String, command: String, session: String) throws {
        let words = prefix.split(separator: " ").map(String.init)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = words + ["--command", command, "--session", session, "--cwd", "/root/work"]
        process.standardOutput = output
        let (stream, done) = AsyncStream<Void>.makeStream()
        finished = stream
        process.terminationHandler = { _ in done.yield(); done.finish() }
        try process.run()
    }

    /// The agent's verdict, once its hook returned.
    func result(within seconds: Double) async throws -> [String: Any] {
        let waited = Task { for await _ in finished { return true }; return false }
        let timeout = Task { try await Task.sleep(for: .seconds(seconds)); process.terminate() }
        defer { timeout.cancel() }
        guard await waited.value else { throw Failure(description: "the stand-in agent didn't end") }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("RESULT ") }),
              let object = try JSONSerialization.jsonObject(with: Data(line.dropFirst(7).utf8)) as? [String: Any] else {
            throw Failure(description: "the stand-in agent printed no result: \(text)")
        }
        return object
    }
}

/// The phone's side of a permission request: see it arrive on the events socket and in the lists, answer Allow (signed with the
/// unlock key, as an unlocked phone does) and Deny, and see the agent act on each.
func permissions(client: RemoteClient, keys: Keys, macID: String, deviceID: String, agent: String) async throws {
    let events = try await client.socket("/v1/ws/events")
    let encoder = JSONEncoder()
    try await events.send(.text(String(decoding: try encoder.encode(ClientMessage.hello(epoch: nil, lastSeq: nil, capabilities: [.events])), as: UTF8.self)))
    var greeted = 0
    while greeted < 2 {
        if case .text(let text) = try await events.receive(), let kind = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"] as? String,
           kind == "welcome" || kind == "snapshot" { greeted += 1 }
    }

    func next(_ matches: (ServerEvent) -> Bool) async throws -> ServerEvent {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard case .text(let text) = try await events.receive(), let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: Data(text.utf8)) else { continue }
            say("event \(envelope.event.type)")
            if matches(envelope.event) { return envelope.event }
        }
        throw Failure(description: "the event never came")
    }

    let allowing = try StandIn(prefix: agent, command: "npm test", session: "probe-session-1")
    guard case .requestAdd(let asked) = try await next({ if case .requestAdd(let request) = $0 { return request.action == .command("npm test") } else { return false } }) else { throw Failure(description: "the event was not the one asked for") }
    try require(asked.agent == .claude && asked.sessionID == "probe-session-1" && asked.answers.contains(.allow) && asked.answers.contains(.deny),
                "a permission request arrived on the events socket: \(asked.headline), asking for \(asked.allowGate.rawValue)")
    try require(try await client.requests().requests.contains { $0.id == asked.id }, "GET /v1/requests lists it")
    try require(try await client.get("/v1/state", as: StateSnapshot.self).requests.contains { $0.id == asked.id }, "the state snapshot holds it")
    try require(try await client.request(asked.id).action == .command("npm test"), "GET /v1/requests/{id} gives it whole")

    let allow = AnswerBody(answer: .allow(confirmDestructive: false))
    do {
        let _: RequestResolution = try await client.post("/v1/requests/\(asked.id)/answer", json: allow)
        throw Failure(description: "an unsigned Allow was taken")
    } catch let failure as RemoteFailure {
        try require(failure.status == 401, "an Allow with no signature is refused (\(failure.error.code.rawValue))")
    }
    let proof = try keys.sign(macID: macID, deviceID: deviceID, purpose: .allow,
                              subject: try ConfirmMessage.subject(requestID: asked.id, answer: allow.answer) ?? "", faceID: false)
    let allowed: RequestResolution = try await client.post("/v1/requests/\(asked.id)/answer", json: allow, confirm: proof)
    try require(allowed.by == .device && allowed.answer == .allow, "the unlocked phone's Allow was taken")
    guard case .requestResolve(let settled) = try await next({ if case .requestResolve(let resolution) = $0 { return resolution.requestID == asked.id } else { return false } }) else { throw Failure(description: "the event was not the one asked for") }
    try require(settled.by == .device && settled.answer == .allow, "the events socket says the request was allowed on this phone")
    let yes = try await allowing.result(within: 30)
    try require(yes["outcome"] as? String == "allow", "the hook gave the stand-in agent the phone's Allow: \(yes)")

    let denying = try StandIn(prefix: agent, command: "npm publish", session: "probe-session-2")
    guard case .requestAdd(let second) = try await next({ if case .requestAdd(let request) = $0 { return request.action == .command("npm publish") } else { return false } }) else { throw Failure(description: "the event was not the one asked for") }
    let denied: RequestResolution = try await client.post("/v1/requests/\(second.id)/answer", json: AnswerBody(answer: .deny(message: "Not from the probe.")))
    try require(denied.answer == .deny, "the phone's Deny needs no signature and was taken")
    _ = try await next { if case .requestResolve(let resolution) = $0 { return resolution.requestID == second.id } else { return false } }
    let no = try await denying.result(within: 30)
    try require(no["outcome"] as? String == "deny" && no["message"] as? String == "Not from the probe.", "the hook gave the stand-in agent the phone's Deny and its words: \(no)")
    try require(try await client.requests().requests.isEmpty, "nothing is left waiting")
    events.close(code: 1000, reason: nil)
}
