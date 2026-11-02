import Foundation
import Network
import SideACore

@MainActor protocol PoolDecisions: AnyObject {
    func poolAccount(_ provider: AgentProvider, session: String?, excluding: Set<String>) -> String?
    /// `refused`: the service turned the last token down, so renew it unless a session already did.
    func poolToken(_ account: String, refused: Bool) async throws -> PoolCredential
    func poolTokenFailed(_ account: String, _ error: any Error)
    func poolAnswered(_ account: String, status: Int, headers: HTTPHeaders)
    /// A request the pool answered itself, with no account's reply.
    func poolRefused(_ provider: AgentProvider?, status: Int, message: String)
    /// What `GET /side-a/health` reports to a Mac using this pool.
    func poolHealthReport() -> [String: Int]
}

struct PoolCredential: Equatable, Sendable {
    let token: String
    /// Codex's ChatGPT workspace, sent as chatgpt-account-id.
    var accountID: String?
}

/// One service the pool serves: where its requests go and how its client is told apart.
struct PoolService: Sendable {
    let provider: AgentProvider
    let base: URL
    let prefix: String
    let client: String
    let admits: @Sendable (HTTPHeaders) -> Bool
    let session: @Sendable (HTTPHeaders, Data) -> String?

    static let claude = PoolService(provider: .claude, base: URL(string: "https://api.anthropic.com")!, prefix: "/v1/", client: "Claude Code",
                                    admits: Pool.fromClaudeCode, session: Pool.session)
    static let codex = PoolService(provider: .codex, base: URL(string: "https://chatgpt.com/backend-api")!, prefix: "/codex/", client: "Codex",
                                   admits: Pool.fromCodex, session: { headers, _ in Pool.codexSession(headers) })
}

/// Who may use a listener: its key, and for a shared one, which peers.
struct PoolGate: Sendable {
    let key: String
    let admit: (@Sendable (String) async -> Bool)?
    /// Its connections come through SocketFront, so the peer is the one it recorded, never the loopback relay.
    var spliced = false
    /// How long a client has to send its whole request.
    var patience: TimeInterval = PoolProxy.requestTime
}

final class PoolProxy: @unchecked Sendable {
    static let preferredPort: UInt16 = 47317
    static let bodyLimit = 40 << 20
    /// What a caller without the key may send: its refusal needs nothing more.
    static let strangerBody = 64 << 10
    /// 40 MiB at about 3 Mbit/s.
    static let requestTime: TimeInterval = 120
    static let dropped: Set<String> = ["host", "authorization", "x-api-key", "connection", "content-length", "accept-encoding",
                                       "transfer-encoding", "keep-alive", "proxy-authorization", "proxy-connection", "te", "upgrade",
                                       "chatgpt-account-id"]

    let key: String
    private let services: [PoolService]
    private let queue = DispatchQueue(label: "sidea.pool")
    private var listener: NWListener?
    private var shared: (front: SocketFront, inner: NWListener)?
    private weak var decisions: (any PoolDecisions)?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    init(key: String, decisions: any PoolDecisions, services: [PoolService] = [.claude, .codex]) {
        self.key = key
        self.services = services
        self.decisions = decisions
    }

    /// A fixed port, so sessions started before an update reach the relaunched app.
    func start(port preferred: UInt16 = PoolProxy.preferredPort) async throws -> UInt16 {
        let gate = PoolGate(key: key, admit: nil)
        let port = try await { () async throws -> (NWListener, UInt16) in
            do { return try await listen(.ipv4(.loopback), NWEndpoint.Port(rawValue: preferred)!, gate) } catch { return try await listen(.ipv4(.loopback), .any, gate) }
        }()
        listener = port.0
        return port.1
    }

    /// Also listens on `address` (this Mac's Tailscale address) for the user's other Macs, behind its own key and `admit`.
    /// Network.framework never finishes a connection on a Tailscale address (see SocketFront), so a BSD socket there
    /// hands each one to a loopback listener, which learns the real peer from SplicedPeers.
    func share(on address: String, port: UInt16 = PoolProxy.preferredPort, gate: PoolGate) async throws -> UInt16 {
        unshare()
        let (inner, innerPort) = try await listen(.ipv4(.loopback), .any, PoolGate(key: gate.key, admit: gate.admit, spliced: true, patience: gate.patience))
        do {
            let front = try SocketFront(address: address, port: port, queue: queue) { innerPort }
            shared = (front, inner)
            return front.port
        } catch {
            inner.cancel()
            throw error
        }
    }

    var isShared: Bool { shared != nil }

    func unshare() {
        shared?.front.cancel()
        shared?.inner.cancel()
        shared = nil
    }

    func stop() {
        unshare()
        listener?.cancel()
        listener = nil
    }

    private func listen(_ host: NWEndpoint.Host, _ port: NWEndpoint.Port, _ gate: PoolGate) async throws -> (NWListener, UInt16) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, gate) }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: (listener, listener.port?.rawValue ?? port.rawValue)) }
                case .failed(let error):
                    listener.cancel()
                    once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection, _ gate: PoolGate) {
        let key = gate.key
        let client = PoolClient(connection: connection, queue: queue, patience: gate.patience) { head in
            Self.authorized(head, key: key) ? Self.bodyLimit : Self.strangerBody
        }
        var peer = ""
        if case .hostPort(let host, let port) = connection.endpoint {
            peer = gate.spliced ? SplicedPeers.shared.take(port.rawValue)?.source ?? "" : "\(host)".components(separatedBy: "%").first ?? ""
        }
        client.onRequest = { [weak self, weak client] request in
            guard let self, let client else { return }
            let task = Task { await self.serve(request, to: client, key: gate.key) }
            client.onClose = { task.cancel() }
        }
        guard let admit = gate.admit else { return client.start() }
        // Asked before a byte is read: someone else on the tailnet gets no buffer here at all.
        client.start(reading: false)
        Task { [peer] in
            guard await admit(peer) else { return client.fail(403, "permission_error", "This Mac's pool is only shared with your own devices on Tailscale.") }
            client.read()
        }
    }

    private static func authorized(_ request: HTTPRequest, key: String) -> Bool {
        let bearer = request.headers["Authorization"].map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : $0 }
        return [bearer, request.headers["x-api-key"]].contains { $0.map { Self.equal($0, key) } ?? false }
    }

    private static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func serve(_ request: HTTPRequest, to client: PoolClient, key: String) async {
        let service = services.first { request.target.hasPrefix($0.prefix) }
        let refuse = { [weak self] (status: Int, type: String, message: String) async in
            await self?.decisions?.poolRefused(service?.provider, status: status, message: message)
            client.fail(status, type, message)
        }
        guard Self.authorized(request, key: key) else { return client.fail(401, "authentication_error", "Side A's pool key is missing or wrong.") }
        if request.method == "GET", request.target == "/side-a/health" {
            let health = await decisions?.poolHealthReport() ?? [:]
            return client.reply(HTTPResponse.json(200, (try? JSONSerialization.data(withJSONObject: health)) ?? Data("{}".utf8)))
        }
        guard let service else { return await refuse(404, "not_found_error", "Side A's pool only forwards Claude Code's and Codex's API routes.") }
        guard service.admits(request.headers) else {
            return await refuse(403, "permission_error", "Side A's pool only serves \(service.client).")
        }
        guard let url = Pool.upstream(request.target, base: service.base, prefix: service.prefix) else {
            return await refuse(404, "not_found_error", "Side A's pool only forwards \(service.client)'s API routes.")
        }
        let conversation = service.session(request.headers, request.body)
        var excluded: Set<String> = []
        while !Task.isCancelled, let account = await decisions?.poolAccount(service.provider, session: conversation, excluding: excluded) {
            excluded.insert(account)
            do {
                var credential = try await token(account, refused: false)
                var (bytes, response) = try await send(request, to: url, as: service.provider, credential)
                if response.statusCode == 401 {
                    bytes.task.cancel()
                    let renewed = try await self.token(account, refused: true)
                    if renewed != credential {
                        credential = renewed
                        (bytes, response) = try await send(request, to: url, as: service.provider, credential)
                    }
                }
                let headers = Self.headers(response)
                await decisions?.poolAnswered(account, status: response.statusCode, headers: headers)
                if [401, 403, 429].contains(response.statusCode) { bytes.task.cancel(); continue }
                await client.stream(status: response.statusCode, headers: headers, bytes: bytes)
                return
            } catch let error as PoolTokenError {
                await decisions?.poolTokenFailed(account, error.underlying)
            } catch where Self.cancelled(error) {
                return client.close()
            } catch {
                let host = service.provider == .claude ? "Anthropic" : "OpenAI"
                return await refuse(502, "api_error", "Side A couldn't reach \(host): \(error.localizedDescription)")
            }
        }
        if Task.isCancelled { return client.close() }
        await refuse(429, "rate_limit_error", "Every \(service.provider.title) account in Side A's pool is at its limit or needs a sign-in.")
    }

    private struct PoolTokenError: Error { let underlying: any Error }

    private func token(_ account: String, refused: Bool) async throws -> PoolCredential {
        guard let decisions else { throw CancellationError() }
        do { return try await decisions.poolToken(account, refused: refused) } catch { throw PoolTokenError(underlying: error) }
    }

    private static func cancelled(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func send(_ request: HTTPRequest, to url: URL, as provider: AgentProvider, _ credential: PoolCredential) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var outgoing = URLRequest(url: url)
        outgoing.httpMethod = request.method
        outgoing.httpBody = request.body.isEmpty ? nil : url.path == "/v1/messages" ? Pool.hourLongCache(request.body) : request.body
        var betas: [String] = []
        for (name, value) in request.headers.fields where !Self.dropped.contains(name.lowercased()) {
            if provider == .claude, name.lowercased() == "anthropic-beta" { betas += value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } else {
                outgoing.addValue(value, forHTTPHeaderField: name)
            }
        }
        if provider == .claude {
            // A subscription login is only accepted with the OAuth beta, which Claude Code sends only with its own login.
            if !betas.contains("oauth-2025-04-20") { betas.append("oauth-2025-04-20") }
            outgoing.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        if let workspace = credential.accountID { outgoing.setValue(workspace, forHTTPHeaderField: "chatgpt-account-id") }
        outgoing.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: outgoing)
        } catch let error as URLError where error.code == .networkConnectionLost && Self.resends(request.target) {
            // Usually a kept connection the server had closed. The server may have had it all the same, so a resend can bill a
            // turn twice; that's the price of not failing a conversation for it, and only these routes pay it.
            (bytes, response) = try await session.bytes(for: outgoing)
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (bytes, http)
    }

    /// The routes that produce a turn. Nothing else admitted is resent on a lost connection.
    static func resends(_ target: String) -> Bool {
        ["/v1/messages", "/codex/responses"].contains(target.split(separator: "?", omittingEmptySubsequences: false).first.map(String.init) ?? "")
    }

    private static func headers(_ response: HTTPURLResponse) -> HTTPHeaders {
        HTTPHeaders(response.allHeaderFields.compactMap { name, value in
            guard let name = name as? String, !dropped.contains(name.lowercased()), name.lowercased() != "content-encoding" else { return nil }
            return (name, "\(value)")
        })
    }
}

private final class PoolClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var parser: HTTPParser
    private let patience: TimeInterval
    private var started = false
    private var ended = false
    var onRequest: ((HTTPRequest) -> Void)?
    var onClose: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, patience: TimeInterval, bodyLimit: @escaping @Sendable (HTTPRequest) -> Int?) {
        self.connection = connection
        self.queue = queue
        self.patience = patience
        parser = HTTPParser(bodyLimit: bodyLimit)
    }

    func start(reading: Bool = true) {
        // Holds the client until the connection ends; finish() lets go.
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + patience) { [weak self] in
            guard let self, !self.started, !self.ended else { return }
            self.fail(408, "invalid_request_error", "The request took too long to arrive.")
        }
        if reading { receive() }
    }

    func read() { queue.async { self.receive() } }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self, !self.ended else { return }
            if let data, !data.isEmpty {
                for result in self.parser.feed(data) {
                    switch result {
                    case .success(let request) where !self.started:
                        self.started = true
                        self.onRequest?(request)
                    case .failure(let problem): self.fail(problem.status, "invalid_request_error", problem.message)
                    default: break
                    }
                }
            }
            // Kept reading after the request too: a hang-up (Esc in Claude Code) ends the connection and so the upstream call.
            if complete || error != nil { self.connection.cancel() } else { self.receive() }
        }
    }

    func stream(status: Int, headers: HTTPHeaders, bytes: URLSession.AsyncBytes) async {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        for (name, value) in headers.fields { head += "\(name): \(value)\r\n" }
        head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        write(Data(head.utf8))
        var chunk = Data()
        do {
            // Server-sent events end each line with a newline, so flushing there keeps the reply as live as it came.
            for try await byte in bytes {
                chunk.append(byte)
                if byte == 0x0A || chunk.count >= 16 << 10 { write(Self.framed(chunk)); chunk.removeAll(keepingCapacity: true) }
            }
            if !chunk.isEmpty { write(Self.framed(chunk)) }
            write(Data("0\r\n\r\n".utf8))
        } catch {}
        close()
    }

    func reply(_ response: HTTPResponse) {
        write(response.encoded(close: true))
        close()
    }

    func fail(_ status: Int, _ type: String, _ message: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": type, "message": message]])) ?? Data()
        var response = HTTPResponse.json(status, body)
        response.headers.add("x-should-retry", "false")
        write(response.encoded(close: true))
        close()
    }

    private static func framed(_ data: Data) -> Data {
        Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8) + data + Data("\r\n".utf8)
    }

    private func write(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.connection.cancel() })
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        connection.stateUpdateHandler = nil
        onClose?()
        onClose = nil
        onRequest = nil
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
