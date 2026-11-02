import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures

/// A scripted Mac: REST answers from a handler, sockets the test feeds frame by frame.
final class FakeMac: Transport, @unchecked Sendable {
    struct Reply { var status = 200; var body = Data(); var headers: [String: String] = [:] }
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _sockets: [FakeSocket] = []
    private var handler: @Sendable (URLRequest) -> Reply = { _ in Reply(status: 404) }
    /// `GET /v1/hello`, answered apart from `handler` so tests only script what they're about.
    private var helloReply = Reply(body: try! Fixtures.data("Hello.paired"))

    var requests: [URLRequest] { lock.withLock { _requests } }
    var sockets: [FakeSocket] { lock.withLock { _sockets } }
    func respond(_ handler: @escaping @Sendable (URLRequest) -> Reply) { lock.withLock { self.handler = handler } }
    func hello(_ reply: Reply) { lock.withLock { helloReply = reply } }
    /// Hosts whose TLS key isn't the pinned one: every request to them fails the handshake.
    private var _rekeyed: Set<String> = []
    func rekeyed(_ hosts: Set<String>) { lock.withLock { _rekeyed = hosts } }
    /// Hosts that never answer.
    private var _unreachable: Set<String> = []
    func unreachable(_ hosts: Set<String>) { lock.withLock { _unreachable = hosts } }
    /// Every request fails as a phone with no direct path, turned away by the relay.
    private var _relayRefuses = false
    func relayRefuses(_ refuses: Bool) { lock.withLock { _relayRefuses = refuses } }
    private var _learned: [Endpoints] = []
    /// What the engine passed on from each trusted hello.
    var learned: [Endpoints] { lock.withLock { _learned } }
    func learned(_ endpoints: Endpoints) async { lock.withLock { _learned.append(endpoints) } }
    /// Everything but hello.
    var calls: [URLRequest] { requests.filter { $0.url?.path != "/v1/hello" } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if lock.withLock({ _relayRefuses }) { throw RelayRefused() }
        if lock.withLock({ _rekeyed.contains(request.url?.host ?? "") }) { throw ServerKeyChanged(seen: "other") }
        if lock.withLock({ _unreachable.contains(request.url?.host ?? "") }) {
            lock.withLock { _requests.append(request) }
            throw URLError(.cannotConnectToHost)
        }
        let reply = lock.withLock { () -> Reply? in
            _requests.append(request)
            return request.url?.path == "/v1/hello" ? helloReply : nil
        } ?? lock.withLock { handler }(request)
        if reply.status == 0 { throw URLError(.notConnectedToInternet) }
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!)
    }

    func socket(_ request: URLRequest) -> any SocketConnection {
        let socket = FakeSocket(request: request)
        lock.withLock { _sockets.append(socket) }
        return socket
    }

    /// The next socket the client opens, once it has sent its hello.
    func socket(_ index: Int) async throws -> FakeSocket {
        try await until("socket \(index)") { self.sockets.count > index && !self.sockets[index].raw.isEmpty }
        return sockets[index]
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
    /// Every frame the client sent, as sent.
    var raw: [SocketMessage] { lock.withLock { _raw } }
    var closedByClient: Int? { lock.withLock { _closed } }

    func send(_ message: SocketMessage) async throws {
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
    /// How many pings the client sent.
    var pings: Int { lock.withLock { _pings } }
    /// Every ping from now on goes unanswered, with this error.
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
    /// The client's close takes effect only when the test says, with `serverClose`.
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

/// Polls until `condition` holds, for at most two seconds.
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

func engine(_ mac: FakeMac, token: String? = "sa1_token", outbox: Outbox? = nil, timing: SyncTiming = fastTiming) throws -> SyncEngine {
    SyncEngine(endpoint: endpoint, credentials: Keys(token: token), outbox: try outbox ?? temporaryOutbox().0, transport: mac,
               info: ClientInfo(version: "1.0", build: 41, system: "iOS 27.0", capabilities: [.events, .transcriptStream]), timing: timing)
}

func json(_ value: some Encodable) -> Data { try! JSONEncoder().encode(value) }

func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Fixtures.data(name))
}
