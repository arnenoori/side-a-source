import Foundation
import Network
@testable import SideA
import SideACore
import SideAProtocol
import Testing

@MainActor private final class OneAccount: PoolDecisions {
    func poolAccount(_ provider: AgentProvider, session: String?, excluding: Set<String>) -> String? { excluding.isEmpty ? "ok" : nil }
    func poolToken(_ account: String, refused: Bool) async throws -> PoolCredential { PoolCredential(token: "tok") }
    func poolRefused(_ provider: AgentProvider?, session: String?, status: Int, message: String) {}
    func poolHealthReport() -> [String: Int] { [:] }
    func poolTokenFailed(_ account: String, _ error: any Error) {}
    func poolAnswered(_ account: String, status: Int, headers: HTTPHeaders) {}
}

private final class RecordingUpstream: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "recording-upstream")
    private let lock = NSLock()
    private var _seen: [HTTPRequest] = []
    private let answer: @Sendable (HTTPRequest) -> (Int, String)
    var seen: [HTTPRequest] { lock.withLock { _seen } }

    init(answer: @escaping @Sendable (HTTPRequest) -> (Int, String) = { _ in (200, "{}") }) throws {
        self.answer = answer
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
                if case .ready = state, let port = listener.port { resumed = true; continuation.resume(returning: port.rawValue) }
                if case .failed(let error) = state { resumed = true; continuation.resume(throwing: error) }
            }
            listener.start(queue: queue)
        }
        return try #require(URL(string: "http://127.0.0.1:\(port)"))
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
                    let (status, body) = self.answer(request)
                    let reply = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                    connection.send(content: Data(reply.utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                if !complete { read() }
            }
        }
        read()
    }
}

@MainActor private func pool(_ base: URL, _ decisions: OneAccount) async throws -> (PoolProxy, UInt16) {
    let proxy = PoolProxy(key: String(repeating: "k", count: 64), decisions: decisions, services: [
        PoolService(provider: .claude, base: base, prefix: "/v1/", client: "Claude Code", admits: Pool.fromClaudeCode, session: Pool.session),
        PoolService(provider: .codex, base: base.appendingPathComponent("backend-api"), prefix: "/codex/", client: "Codex", admits: Pool.fromCodex,
                    session: { headers, _ in Pool.codexSession(headers) }),
    ])
    return (proxy, try await proxy.start(port: 0))
}

private func turn(_ port: UInt16, _ path: String = "/v1/messages", body: Data) throws -> URLRequest {
    var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)\(path)")))
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer " + String(repeating: "k", count: 64), forHTTPHeaderField: "Authorization")
    request.setValue("claude-cli/2.1.314 (external, cli)", forHTTPHeaderField: "User-Agent")
    request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
    return request
}

private let conversation = Data((#"{"model":"claude-opus-5-5","messages":[{"role":"user","content":""#
    + String(repeating: "The same tool output, again. ", count: 400) + #""}]}"#).utf8)

@MainActor @Test func aClaudeTurnGoesUpstreamAsGzipAndOthersGoPlain() async throws {
    let upstream = try RecordingUpstream()
    let base = try await upstream.start()
    defer { upstream.stop() }
    let decisions = OneAccount()
    let (proxy, port) = try await pool(base, decisions)
    defer { proxy.stop() }

    let (_, response) = try await URLSession.shared.data(for: turn(port, body: conversation))
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let sent = try #require(upstream.seen.last)
    #expect(sent.headers["Content-Encoding"] == "gzip")
    #expect(sent.body.count < conversation.count / 4)
    #expect(Gzip.decompress(sent.body) == conversation)

    let small = Data(#"{"model":"claude-opus-5-5"}"#.utf8)
    _ = try await URLSession.shared.data(for: turn(port, body: small))
    #expect(upstream.seen.last?.headers["Content-Encoding"] == nil)
    #expect(upstream.seen.last?.body == small)

    _ = try await URLSession.shared.data(for: turn(port, "/codex/responses", body: conversation))
    #expect(upstream.seen.last?.headers["Content-Encoding"] == nil)
    #expect(upstream.seen.last?.body == conversation)

    var encoded = try turn(port, body: conversation)
    encoded.setValue("zstd", forHTTPHeaderField: "Content-Encoding")
    _ = try await URLSession.shared.data(for: encoded)
    #expect(upstream.seen.last?.headers["Content-Encoding"] == "zstd")
    #expect(upstream.seen.last?.body == conversation)
}

@MainActor @Test func aServiceRefusingGzipGetsTheTurnPlainAndEveryOneAfter() async throws {
    let upstream = try RecordingUpstream { request in
        request.headers["Content-Encoding"] == nil ? (200, #"{"ok":true}"#)
            : (400, #"{"type":"error","error":{"type":"invalid_request_error","details":{"error_code":"request_body_encoding_invalid"}}}"#)
    }
    let base = try await upstream.start()
    defer { upstream.stop() }
    let decisions = OneAccount()
    let (proxy, port) = try await pool(base, decisions)
    defer { proxy.stop() }

    let (body, response) = try await URLSession.shared.data(for: turn(port, body: conversation))
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: body, as: UTF8.self) == #"{"ok":true}"#)
    #expect(upstream.seen.map { $0.headers["Content-Encoding"] } == ["gzip", nil])
    #expect(upstream.seen.last?.body == conversation)

    _ = try await URLSession.shared.data(for: turn(port, body: conversation))
    #expect(upstream.seen.count == 3)
    #expect(upstream.seen.last?.headers["Content-Encoding"] == nil)
}

@MainActor @Test func aGzipTurnRefusedForItsContentReachesTheClientOnce() async throws {
    let refusal = #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long"}}"#
    let upstream = try RecordingUpstream { _ in (400, refusal) }
    let base = try await upstream.start()
    defer { upstream.stop() }
    let decisions = OneAccount()
    let (proxy, port) = try await pool(base, decisions)
    defer { proxy.stop() }

    let (body, response) = try await URLSession.shared.data(for: turn(port, body: conversation))
    #expect((response as? HTTPURLResponse)?.statusCode == 400)
    #expect(String(decoding: body, as: UTF8.self) == refusal)
    #expect(upstream.seen.count == 1)

    _ = try await URLSession.shared.data(for: turn(port, body: conversation))
    #expect(upstream.seen.last?.headers["Content-Encoding"] == "gzip")
}
