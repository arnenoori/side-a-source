import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures

final class FakeMac: Transport, @unchecked Sendable {
    struct Reply { var status = 200; var body = Data(); var headers: [String: String] = [:] }
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _sockets: [FakeSocket] = []
    private var handler: @Sendable (URLRequest) -> Reply = { _ in Reply(status: 404) }
    private var helloReply = Reply(body: try! Fixtures.data("Hello.paired"))

    var requests: [URLRequest] { lock.withLock { _requests } }
    var sockets: [FakeSocket] { lock.withLock { _sockets } }
    /// Runs on each socket the client opens, before it is used: a Mac that has already refused it, say.
    var onSocket: (@Sendable (FakeSocket) -> Void)? {
        get { lock.withLock { _onSocket } }
        set { lock.withLock { _onSocket = newValue } }
    }
    private var _onSocket: (@Sendable (FakeSocket) -> Void)?
    func respond(_ handler: @escaping @Sendable (URLRequest) -> Reply) { lock.withLock { self.handler = handler } }
    func hello(_ reply: Reply) { lock.withLock { helloReply = reply } }
    private var _rekeyed: Set<String> = []
    func rekeyed(_ hosts: Set<String>) { lock.withLock { _rekeyed = hosts } }
    private var _unreachable: Set<String> = []
    func unreachable(_ hosts: Set<String>) { lock.withLock { _unreachable = hosts } }
    private var _relayRefuses = false
    func relayRefuses(_ refuses: Bool) { lock.withLock { _relayRefuses = refuses } }
    private var _learned: [Endpoints] = []
    var learned: [Endpoints] { lock.withLock { _learned } }
    func learned(_ endpoints: Endpoints) async { lock.withLock { _learned.append(endpoints) } }
    private var gates: [String: Gate] = [:]
    func hold(_ path: String) -> Gate {
        let gate = Gate()
        lock.withLock { gates[path] = gate }
        return gate
    }
    var calls: [URLRequest] { requests.filter { $0.url?.path != "/v1/hello" } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if lock.withLock({ _relayRefuses }) { throw RelayRefused() }
        if lock.withLock({ _rekeyed.contains(request.url?.host ?? "") }) { throw ServerKeyChanged(seen: "other") }
        if lock.withLock({ _unreachable.contains(request.url?.host ?? "") }) {
            lock.withLock { _requests.append(request) }
            throw URLError(.cannotConnectToHost)
        }
        if let gate = lock.withLock({ gates[request.url?.path ?? ""] }) { await gate.wait() }
        let reply = lock.withLock { () -> Reply? in
            _requests.append(request)
            return request.url?.path == "/v1/hello" ? helloReply : nil
        } ?? lock.withLock { handler }(request)
        if reply.status == 0 { throw URLError(.notConnectedToInternet) }
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!)
    }

    func socket(_ request: URLRequest) -> any SocketConnection {
        let socket = FakeSocket(request: request)
        let prepare = lock.withLock { () -> (@Sendable (FakeSocket) -> Void)? in
            _sockets.append(socket)
            return _onSocket
        }
        prepare?(socket)
        return socket
    }

    func socket(_ index: Int) async throws -> FakeSocket {
        try await until("socket \(index)") { self.sockets.count > index && !self.sockets[index].raw.isEmpty }
        return sockets[index]
    }
}

final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var _arrived = 0
    var arrived: Int { lock.withLock { _arrived } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pass = lock.withLock {
                _arrived += 1
                if !opened { waiting.append(continuation) }
                return opened
            }
            if pass { continuation.resume() }
        }
    }

    func open() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiting = [] }
            return waiting
        }
        for continuation in held { continuation.resume() }
    }
}

final class FakeSocket: SocketConnection, @unchecked Sendable {
    let request: URLRequest
    private let lock = NSLock()
    private var _sent: [ClientMessage] = []
    private var _raw: [SocketMessage] = []
    private var _closed: Int?
    private let incoming: AsyncStream<Result<SocketMessage, SocketClosed>>
    private let feed: AsyncStream<Result<SocketMessage, SocketClosed>>.Continuation

    init(request: URLRequest) {
        self.request = request
        (incoming, feed) = AsyncStream.makeStream()
    }

    var sent: [ClientMessage] { lock.withLock { _sent } }
    var raw: [SocketMessage] { lock.withLock { _raw } }
    var closedByClient: Int? { lock.withLock { _closed } }

    private var _sendError: Error?
    func failSends(_ error: Error) { lock.withLock { _sendError = error } }

    func send(_ message: SocketMessage) async throws {
        if let error = lock.withLock({ _sendError }) { throw error }
        var decoded: ClientMessage?
        if case .text(let text) = message { decoded = try? JSONDecoder().decode(ClientMessage.self, from: Data(text.utf8)) }
        // Together, so a test that saw the frame also sees it decoded.
        lock.withLock {
            _raw.append(message)
            if let decoded { _sent.append(decoded) }
        }
    }

    func receive() async throws -> SocketMessage {
        for await next in incoming { return try next.get() }
        // Cancelling the task ended that wait, which a real socket's doesn't: it ends when the close lands.
        if lock.withLock({ _holdsClose }) {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let open = lock.withLock {
                    if _closeLanded { return true }
                    _heldReceive = done
                    return false
                }
                if open { done.resume() }
            }
        }
        throw SocketClosed(code: 1006)
    }

    private var _pingError: Error?
    private var _pings = 0
    var pings: Int { lock.withLock { _pings } }
    func failPings(_ error: Error) { lock.withLock { _pingError = error } }

    func sendPing() async throws {
        let error = lock.withLock { () -> Error? in
            _pings += 1
            return _pingError
        }
        if let error { throw error }
    }
    private var _holdsClose = false
    private var _closeLanded = false
    private var _heldReceive: CheckedContinuation<Void, Never>?
    func holdClose() { lock.withLock { _holdsClose = true } }

    func close(code: Int, reason: String?) {
        let holds = lock.withLock {
            _closed = code
            return _holdsClose
        }
        if !holds { feed.yield(.failure(SocketClosed(code: code))) }
    }

    func push(_ seq: Int? = nil, _ event: ServerEvent) {
        let envelope = EventEnvelope(seq: seq, at: 1, event: event)
        feed.yield(.success(.text(String(decoding: try! JSONEncoder().encode(envelope), as: UTF8.self))))
    }

    func push(raw text: String) { feed.yield(.success(.text(text))) }

    func push(_ control: TermControl) {
        feed.yield(.success(.text(String(decoding: try! JSONEncoder().encode(control), as: UTF8.self))))
    }

    func push(frame: TermFrame) { feed.yield(.success(.data(frame.data))) }

    func push(fixture name: String, seq: Int? = nil) throws {
        push(seq, try JSONDecoder().decode(ServerEvent.self, from: Fixtures.data(name)))
    }

    func serverClose(_ code: Int, _ reason: String? = nil) {
        feed.yield(.failure(SocketClosed(code: code, reason: reason)))
        let held = lock.withLock {
            _closeLanded = true
            defer { _heldReceive = nil }
            return _heldReceive
        }
        held?.resume()
    }
}

struct Keys: CredentialStore {
    let token: String?
    func token(for macID: String) async throws -> String? { token }
    func setToken(_ token: String?, for macID: String) async throws {}
}

struct Timeout: Error, CustomStringConvertible { let description: String }

func until(_ what: String, _ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw Timeout(description: "timed out waiting for \(what)")
}

let fastTiming: SyncTiming = {
    var timing = SyncTiming()
    timing.backoffBase = 0.01
    timing.backoffCap = 0.05
    timing.ping = 100
    timing.coalesce = 0
    timing.updateCheck = 0.02
    timing.expiryRecheck = 0.02
    timing.claimRecheck = 0.02
    return timing
}()

func temporaryOutbox() throws -> (Outbox, URL) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).sqlite")
    return (try Outbox(file: file), file)
}

let endpoint = Endpoint(macID: "mac1", baseURL: URL(string: "https://100.101.12.4:47800")!,
                        alternates: [URL(string: "https://192.168.1.20:47800")!], serverKeyHash: "pin", name: "MacBook Pro")

let hello = try! JSONDecoder().decode(Hello.self, from: Fixtures.data("Hello.paired"))

func welcome(_ epoch: String, seq: Int, replay: Bool, overREST: Bool = false) -> ServerEvent {
    .welcome(Welcome(epoch: epoch, seq: seq, replay: replay, snapshotOverREST: overREST, hello: hello))
}

func engine(_ mac: FakeMac, token: String? = "sa1_token", outbox: Outbox? = nil, timing: SyncTiming = fastTiming,
            now: @escaping @Sendable () -> Timestamp = { Date().timeIntervalSince1970 }) throws -> SyncEngine {
    SyncEngine(endpoint: endpoint, credentials: Keys(token: token), outbox: try outbox ?? temporaryOutbox().0, transport: mac,
               info: ClientInfo(version: "1.0", build: 41, system: "iOS 27.0", capabilities: [.events, .transcriptStream]), timing: timing, now: now)
}

func json(_ value: some Encodable) -> Data { try! JSONEncoder().encode(value) }

func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Fixtures.data(name))
}
