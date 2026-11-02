import Foundation
import Network

/// One connection to a Codex app-server daemon: a WebSocket over its Unix socket (URLSession can't reach a socket
/// file, and Network.framework's WebSocket can't either), `initialize` with the experimental API, then calls and the
/// daemon's own requests and notifications. A closed connection stays closed; `CodexTerminals` makes a new client.
public final class AppServerClient: @unchecked Sendable {
    public enum Event: Sendable {
        case notification(method: String, params: CodexAppServer.JSON)
        case request(id: CodexAppServer.JSON, method: String, params: CodexAppServer.JSON)
        case closed
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case noSocket, refused, closed, timedOut
        case rpc(CodexAppServer.RPCError)
        public var errorDescription: String? {
            switch self {
            case .noSocket: "Codex's app server isn't running."
            case .refused: "Codex's app server refused the connection."
            case .closed: "The connection to Codex's app server closed."
            case .timedOut: "Codex's app server didn't answer."
            case .rpc(let error): error.message
            }
        }
    }

    public let socket: String
    private let queue = DispatchQueue(label: "com.arnenoori.sidea.codex-app-server")
    private let connection: NWConnection
    private let events: @Sendable (Event) -> Void
    private let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    private var head: Data? = Data()
    private var parser = CodexAppServer.Frames.Parser()
    private var next = 1
    private var waiting: [Int: CheckedContinuation<CodexAppServer.JSON, Error>] = [:]
    private var open = false
    private var ended = false
    private var ready: CheckedContinuation<Void, Error>?

    /// `events` runs on the client's own queue, in arrival order.
    public init(socket: String, events: @escaping @Sendable (Event) -> Void) {
        self.socket = socket
        self.events = events
        connection = NWConnection(to: .unix(path: socket), using: .tcp)
    }

    /// Opens the socket, upgrades it and says hello. Throws `.noSocket` when nothing listens there.
    public func connect(version: String, timeout: Double = 10) async throws {
        guard FileManager.default.fileExists(atPath: socket) else { throw Failure.noSocket }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                ready = continuation
                connection.stateUpdateHandler = { [weak self] state in self?.changed(state) }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, ready != nil else { return }
                    settle(Failure.timedOut)
                    end()
                }
            }
        }
        _ = try await call("initialize", CodexAppServer.initialize(version: version), timeout: timeout)
        queue.async { [self] in send(.text, CodexAppServer.notification(method: "initialized")) }
    }

    public func call(_ method: String, _ params: CodexAppServer.JSON? = nil, timeout: Double = 20) async throws -> CodexAppServer.JSON {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard open, !ended else { continuation.resume(throwing: Failure.closed); return }
                let id = next
                next += 1
                waiting[id] = continuation
                send(.text, CodexAppServer.request(id: id, method: method, params: params))
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.waiting.removeValue(forKey: id)?.resume(throwing: Failure.timedOut)
                }
            }
        }
    }

    /// Answers a request from the daemon.
    public func respond(_ id: CodexAppServer.JSON, _ result: CodexAppServer.JSON) {
        queue.async { [self] in if open, !ended { send(.text, CodexAppServer.response(id: id, result: result)) } }
    }

    public func close() { queue.async { [self] in end() } }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.send(content: CodexAppServer.Frames.upgrade(key: key), completion: .idempotent)
            receive()
        // A Unix socket with no listener waits instead of failing; for a daemon that's gone, that's the answer.
        case .failed, .waiting:
            settle(Failure.noSocket)
            end()
        case .cancelled: end()
        default: break
        }
    }

    private func settle(_ error: Error?) {
        guard let ready else { return }
        self.ready = nil
        if let error { ready.resume(throwing: error) } else { ready.resume() }
    }

    private func end() {
        guard !ended else { return }
        ended = true
        open = false
        settle(Failure.closed)
        connection.cancel()
        for continuation in waiting.values { continuation.resume(throwing: Failure.closed) }
        waiting = [:]
        events(.closed)
    }

    private func send(_ opcode: WebSocketCodec.Opcode, _ payload: Data) {
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        connection.send(content: CodexAppServer.Frames.frame(opcode, payload, mask: mask), completion: .idempotent)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { take(data) }
            if complete || error != nil { end(); return }
            if !ended { receive() }
        }
    }

    private func take(_ data: Data) {
        var data = data
        if var head {
            head.append(data)
            do {
                guard let rest = try CodexAppServer.Frames.accepted(head, key: key) else { self.head = head; return }
                self.head = nil
                open = true
                settle(nil)
                data = rest
            } catch {
                settle(Failure.refused)
                end()
                return
            }
        }
        do {
            for (opcode, payload) in try parser.feed(data) {
                switch opcode {
                case .text: if let message = CodexAppServer.parse(payload) { handle(message) }
                case .ping: send(.pong, payload)
                case .close: end(); return
                default: break
                }
            }
        } catch {
            end()
        }
    }

    private func handle(_ message: CodexAppServer.Message) {
        switch message {
        case .response(let id, let result):
            guard let continuation = waiting.removeValue(forKey: id) else { return }
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): continuation.resume(throwing: Failure.rpc(error))
            }
        case .request(let id, let method, let params): events(.request(id: id, method: method, params: params))
        case .notification(let method, let params): events(.notification(method: method, params: params))
        }
    }
}
