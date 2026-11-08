import Foundation
import Network
@testable import SideA
import SideACore
import Testing

@MainActor private final class FakeDecisions: PoolDecisions {
    var accounts = ["full", "ok"]
    var answered: [(String, Int)] = []
    var limits: [String: [UsageWindow]] = [:]
    func poolAccount(_ provider: AgentProvider, session: String?, excluding: Set<String>) -> String? { accounts.first { !excluding.contains($0) } }
    func poolToken(_ account: String, refused: Bool) async throws -> PoolCredential { PoolCredential(token: "tok-\(account)", accountID: "workspace-\(account)") }
    func poolRefused(_ provider: AgentProvider?, status: Int, message: String) {}
    func poolHealthReport() -> [String: Int] { ["claude": accounts.count] }
    func poolTokenFailed(_ account: String, _ error: any Error) {}
    func poolAnswered(_ account: String, status: Int, headers: HTTPHeaders) {
        answered.append((account, status))
        limits[account] = Pool.limits(headers)
    }
}

private final class FakeAnthropic: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-anthropic")
    private let lock = NSLock()
    private var _seen: [HTTPRequest] = []
    var seen: [HTTPRequest] { lock.withLock { _seen } }
    /// Holds each connection this long after answering, then closes it unasked, as a server timing out an idle one does.
    private let linger: DispatchTimeInterval

    init(linger: DispatchTimeInterval = .seconds(0)) throws {
        self.linger = linger
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let listener = listener
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                if case .ready = state { resumed = true; continuation.resume(returning: listener.port!.rawValue) }
                if case .failed(let error) = state { resumed = true; continuation.resume(throwing: error) }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        nonisolated(unsafe) var parser = HTTPParser(bodyLimit: { _ in 1 << 24 })
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, _ in
                guard let self else { return }
                for case .success(let request) in parser.feed(data ?? Data()) {
                    self.lock.withLock { self._seen.append(request) }
                    let queue = self.queue, linger = self.linger
                    connection.send(content: Data(Self.reply(to: request).utf8), isComplete: true, completion: .contentProcessed { _ in
                        queue.asyncAfter(deadline: .now() + linger) { connection.cancel() }
                    })
                    return
                }
                if !complete { read() }
            }
        }
        read()
    }

    private static func reply(to request: HTTPRequest) -> String {
        if request.headers["Authorization"] == "Bearer tok-full" {
            let body = #"{"type":"error","error":{"type":"rate_limit_error","message":"limit"}}"#
            return "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nanthropic-ratelimit-unified-reset: 4000000000\r\n"
                + "anthropic-ratelimit-unified-5h-utilization: 1.0\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        }
        let events = "event: message_start\ndata: {\"a\":1}\n\nevent: message_stop\ndata: {}\n\n"
        return "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nrequest-id: req_1\r\n"
            + "anthropic-ratelimit-unified-5h-utilization: 0.25\r\nanthropic-ratelimit-unified-5h-reset: 1800000000\r\n"
            + "Content-Length: \(events.utf8.count)\r\n\r\n\(events)"
    }
}

@MainActor @Test func poolProxyMovesAFullAccountsRequestToTheNextAndStreamsTheReply() async throws {
    let upstream = try FakeAnthropic()
    let base = try await upstream.start()
    defer { upstream.stop() }
    let decisions = FakeDecisions()
    let proxy = PoolProxy(key: String(repeating: "k", count: 64), decisions: decisions, services: [
        PoolService(provider: .claude, base: base, prefix: "/v1/", client: "Claude Code", admits: Pool.fromClaudeCode, session: Pool.session),
        PoolService(provider: .codex, base: base.appendingPathComponent("backend-api"), prefix: "/codex/", client: "Codex", admits: Pool.fromCodex, session: { headers, _ in Pool.codexSession(headers) }),
    ])
    let port = try await proxy.start(port: 0)
    defer { proxy.stop() }

    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages?beta=true")!)
    request.httpMethod = "POST"
    request.httpBody = Data(#"{"model":"claude-opus-5-5","metadata":{"user_id":"user_x_account__session_abc"}}"#.utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("claude-code-20250219", forHTTPHeaderField: "anthropic-beta")
    request.setValue("claude-cli/2.1.314 (external, cli)", forHTTPHeaderField: "User-Agent")

    let (refused, refusal) = try await URLSession.shared.data(for: request)
    #expect((refusal as? HTTPURLResponse)?.statusCode == 401)
    #expect(String(decoding: refused, as: UTF8.self).contains("authentication_error"))
    #expect(upstream.seen.isEmpty)

    request.setValue("Bearer " + String(repeating: "k", count: 64), forHTTPHeaderField: "Authorization")
    let (body, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(http.value(forHTTPHeaderField: "request-id") == "req_1")
    #expect(String(decoding: body, as: UTF8.self) == "event: message_start\ndata: {\"a\":1}\n\nevent: message_stop\ndata: {}\n\n")

    #expect(decisions.answered.map(\.0) == ["full", "ok"])
    #expect(decisions.answered.map(\.1) == [429, 200])
    #expect(decisions.limits["ok"]?.first?.percent == 25)
    let sent = upstream.seen
    #expect(sent.count == 2)
    #expect(sent.map { $0.headers["Authorization"] } == ["Bearer tok-full", "Bearer tok-ok"])
    #expect(sent.allSatisfy { $0.target == "/v1/messages?beta=true" && $0.headers["x-api-key"] == nil })
    #expect(sent.last?.headers["anthropic-beta"] == "claude-code-20250219,oauth-2025-04-20")
    #expect(sent.last?.body == request.httpBody)

    var stranger = request
    stranger.setValue("Anthropic/Python 0.70.0", forHTTPHeaderField: "User-Agent")
    let (_, refusedSDK) = try await URLSession.shared.data(for: stranger)
    #expect((refusedSDK as? HTTPURLResponse)?.statusCode == 403)
    var offHost = request
    offHost.url = URL(string: "http://127.0.0.1:\(port)//evil.example/v1/messages")!
    let (_, refusedPath) = try await URLSession.shared.data(for: offHost)
    #expect((refusedPath as? HTTPURLResponse)?.statusCode == 404)
    #expect(upstream.seen.count == 2)

    decisions.accounts = ["full"]
    let (_, exhausted) = try await URLSession.shared.data(for: request)
    #expect((exhausted as? HTTPURLResponse)?.statusCode == 429)
}

/// Moving on from a full account reuses the connection its 429 came on. A server that has since closed it costs that one
/// send, which it never read: Claude Code must not hear a 502 for it.
@MainActor @Test func anUpstreamClosingAKeptConnectionDoesntFailTheRequest() async throws {
    let upstream = try FakeAnthropic(linger: .milliseconds(150))
    let base = try await upstream.start()
    defer { upstream.stop() }
    let decisions = FakeDecisions()
    let proxy = PoolProxy(key: String(repeating: "k", count: 64), decisions: decisions, services: [
        PoolService(provider: .claude, base: base, prefix: "/v1/", client: "Claude Code", admits: Pool.fromClaudeCode, session: Pool.session),
    ])
    let port = try await proxy.start(port: 0)
    defer { proxy.stop() }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.setValue("Bearer " + String(repeating: "k", count: 64), forHTTPHeaderField: "Authorization")
    request.setValue("claude-cli/2.1.314 (external, cli)", forHTTPHeaderField: "User-Agent")
    let (body, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(String(decoding: body, as: UTF8.self))")
    #expect(decisions.answered.map(\.0) == ["full", "ok"])
}

/// A lost connection may have got there, so only the routes that make a turn take the risk of a second one.
@Test func onlyTurnsAreResentOnALostConnection() {
    #expect(PoolProxy.resends("/v1/messages?beta=true") && PoolProxy.resends("/v1/messages") && PoolProxy.resends("/codex/responses"))
    #expect(!PoolProxy.resends("/v1/messages/count_tokens") && !PoolProxy.resends("/v1/messages/batches") && !PoolProxy.resends("/codex/models"))
}

@MainActor @Test func aSharedPoolServesOnlyAdmittedPeersWithTheShareKey() async throws {
    let upstream = try FakeAnthropic()
    let base = try await upstream.start()
    defer { upstream.stop() }
    let decisions = FakeDecisions()
    decisions.accounts = ["ok"]
    let proxy = PoolProxy(key: String(repeating: "k", count: 64), decisions: decisions, services: [
        PoolService(provider: .claude, base: base, prefix: "/v1/", client: "Claude Code", admits: Pool.fromClaudeCode, session: Pool.session),
        PoolService(provider: .codex, base: base.appendingPathComponent("backend-api"), prefix: "/codex/", client: "Codex", admits: Pool.fromCodex, session: { headers, _ in Pool.codexSession(headers) }),
    ])
    _ = try await proxy.start(port: 0)
    defer { proxy.stop() }
    let admitted = Admitted()
    let port = try await proxy.share(on: "127.0.0.1", port: 0, gate: PoolGate(key: String(repeating: "s", count: 64), admit: { await admitted.check($0) }))
    func ask(_ key: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("claude-cli/2.1.314 (external, cli)", forHTTPHeaderField: "User-Agent")
        return (try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode ?? 0
    }
    #expect(try await ask(String(repeating: "s", count: 64)) == 403)
    await admitted.allow()
    #expect(try await ask(String(repeating: "k", count: 64)) == 401)
    #expect(try await ask(String(repeating: "s", count: 64)) == 200)
    #expect(await admitted.peers.allSatisfy { $0 == "127.0.0.1" })
    proxy.unshare()
    await #expect(throws: (any Error).self) { _ = try await ask(String(repeating: "s", count: 64)) }
}

/// What a bare TCP client hears, sending only `text`, within a few seconds.
private func rawReply(port: UInt16, sending data: Data) async -> String {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let heard = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
        let once = NSLock()
        nonisolated(unsafe) var done = false
        let finish = { @Sendable (text: String) in
            once.withLock { if !done { done = true; continuation.resume(returning: text) } }
        }
        connection.start(queue: .global())
        if !data.isEmpty { connection.send(content: data, completion: .contentProcessed { _ in }) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, _ in finish(String(decoding: data ?? Data(), as: UTF8.self)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { finish("") }
    }
    connection.cancel()
    return heard
}

@MainActor private func sharedProxy(admit: Bool, patience: TimeInterval = PoolProxy.requestTime) async throws -> (PoolProxy, UInt16, FakeDecisions) {
    let decisions = FakeDecisions()
    let proxy = PoolProxy(key: String(repeating: "k", count: 64), decisions: decisions, services: [])
    let port = try await proxy.share(on: "127.0.0.1", port: 0, gate: PoolGate(key: String(repeating: "s", count: 64), admit: { _ in admit }, patience: patience))
    return (proxy, port, decisions)
}

/// Finding 9: someone else on the tailnet is turned away before sending anything.
@MainActor @Test func aPeerWhoIsntAdmittedIsRefusedBeforeSendingAByte() async throws {
    let (proxy, port, decisions) = try await sharedProxy(admit: false)
    defer { withExtendedLifetime(decisions) { proxy.stop() } }
    #expect(await rawReply(port: port, sending: Data()).hasPrefix("HTTP/1.1 403"))
}

/// Finding 9: only the key buys the 40 MiB.
@MainActor @Test func aCallerWithoutTheKeyCantAskForALargeBuffer() async throws {
    let (proxy, port, decisions) = try await sharedProxy(admit: true)
    defer { withExtendedLifetime(decisions) { proxy.stop() } }
    let large = "POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-Length: \(PoolProxy.bodyLimit)\r\n\r\n"
    #expect(await rawReply(port: port, sending: Data(large.utf8)).hasPrefix("HTTP/1.1 413"))
    let keyed = "POST /v1/messages HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(String(repeating: "s", count: 64))\r\nContent-Length: \(PoolProxy.bodyLimit + 1)\r\n\r\n"
    #expect(await rawReply(port: port, sending: Data(keyed.utf8)).hasPrefix("HTTP/1.1 413"))
    #expect(PoolProxy.strangerBody <= 64 << 10)
}

/// Finding 9: a client that opens a request and stalls doesn't hold its buffer forever.
@MainActor @Test func aRequestThatStallsIsDropped() async throws {
    let (proxy, port, decisions) = try await sharedProxy(admit: true, patience: 0.3)
    defer { withExtendedLifetime(decisions) { proxy.stop() } }
    let stalled = "POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nonly this"
    #expect(await rawReply(port: port, sending: Data(stalled.utf8)).hasPrefix("HTTP/1.1 408"))
}

private actor Admitted {
    var open = false
    var peers: [String] = []
    func allow() { open = true }
    func check(_ peer: String) -> Bool { peers.append(peer); return open }
}

@Test func whoisNamesThePeersTailscaleLogin() {
    #expect(Pool.whoisLogin(Data(#"{"Node":{"Name":"mbp"},"UserProfile":{"LoginName":"arne@example.com"}}"#.utf8)) == "arne@example.com")
    #expect(Pool.whoisLogin(Data("{}".utf8)) == nil)
    #expect(Pool.joinCommand(address: "100.64.1.2", port: 47317, key: "k") == "sidea pool join http://100.64.1.2:47317 k")
}

@MainActor @Test func poolProxyServesCodexOnItsOwnRoutesAndReportsHealth() async throws {
    let upstream = try FakeAnthropic()
    let base = try await upstream.start()
    defer { upstream.stop() }
    let decisions = FakeDecisions()
    decisions.accounts = ["ok"]
    let proxy = PoolProxy(key: String(repeating: "k", count: 64), decisions: decisions, services: [
        PoolService(provider: .codex, base: base.appendingPathComponent("backend-api"), prefix: "/codex/", client: "Codex", admits: Pool.fromCodex, session: { headers, _ in Pool.codexSession(headers) }),
    ])
    let port = try await proxy.start(port: 0)
    defer { proxy.stop() }
    let bearer = "Bearer " + String(repeating: "k", count: 64)

    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/codex/responses")!)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.setValue(bearer, forHTTPHeaderField: "Authorization")
    request.setValue("codex_exec", forHTTPHeaderField: "originator")
    request.setValue("someone-elses", forHTTPHeaderField: "chatgpt-account-id")
    let (_, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let sent = try #require(upstream.seen.first)
    #expect(sent.target == "/backend-api/codex/responses")
    #expect(sent.headers["Authorization"] == "Bearer tok-ok")
    #expect(sent.headers["chatgpt-account-id"] == "workspace-ok")
    #expect(sent.headers["anthropic-beta"] == nil)

    request.setValue(nil, forHTTPHeaderField: "originator")
    let (_, stranger) = try await URLSession.shared.data(for: request)
    #expect((stranger as? HTTPURLResponse)?.statusCode == 403)
    #expect(upstream.seen.count == 1)

    var health = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/side-a/health")!)
    let (_, anonymous) = try await URLSession.shared.data(for: health)
    #expect((anonymous as? HTTPURLResponse)?.statusCode == 401)
    health.setValue(bearer, forHTTPHeaderField: "Authorization")
    let (body, answered) = try await URLSession.shared.data(for: health)
    #expect((answered as? HTTPURLResponse)?.statusCode == 200)
    #expect(try JSONDecoder().decode([String: Int].self, from: body)["claude"] == 1)
}

@MainActor private final class HeldDecisions: PoolDecisions {
    var open = false
    func poolAccount(_ provider: AgentProvider, session: String?, excluding: Set<String>) -> String? { excluding.isEmpty ? "ok" : nil }
    func poolToken(_ account: String, refused: Bool) async throws -> PoolCredential {
        while !open { try await Task.sleep(for: .milliseconds(10)) }
        return PoolCredential(token: "tok-ok", accountID: nil)
    }
    func poolRefused(_ provider: AgentProvider?, status: Int, message: String) {}
    func poolHealthReport() -> [String: Int] { [:] }
    func poolTokenFailed(_ account: String, _ error: any Error) {}
    func poolAnswered(_ account: String, status: Int, headers: HTTPHeaders) {}
}

/// An automatic update waits while the pool is answering anyone.
@MainActor @Test func poolCountsTheRequestsItIsAnswering() async throws {
    let upstream = try FakeAnthropic()
    let base = try await upstream.start()
    defer { upstream.stop() }
    let decisions = HeldDecisions()
    let proxy = PoolProxy(key: String(repeating: "k", count: 64), decisions: decisions, services: [
        PoolService(provider: .claude, base: base, prefix: "/v1/", client: "Claude Code", admits: Pool.fromClaudeCode, session: Pool.session),
    ])
    let port = try await proxy.start(port: 0)
    defer { proxy.stop() }
    #expect(proxy.inFlight == 0)
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.setValue("claude-cli/2.1.314 (external, cli)", forHTTPHeaderField: "User-Agent")
    request.setValue("Bearer " + String(repeating: "k", count: 64), forHTTPHeaderField: "Authorization")
    let sent = Task { try await URLSession.shared.data(for: request) }
    for _ in 0..<500 where proxy.inFlight == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(proxy.inFlight == 1)
    decisions.open = true
    let (_, response) = try await sent.value
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    for _ in 0..<500 where proxy.inFlight != 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(proxy.inFlight == 0)
}
