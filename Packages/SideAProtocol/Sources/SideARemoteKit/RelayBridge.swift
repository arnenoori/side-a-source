import Foundation
import Network
import SideAProtocol

/// Where a Mac's relay tunnel is, from pairing (docs/remote/tunnel.md). A paired phone authenticates with its relay
/// credential; a phone mid-pairing with the sheet's ticket from the QR code.
public struct RelayRoute: Codable, Hashable, Sendable {
    public let url: URL
    public let installID: String
    public let deviceID: String?
    /// The pairing ticket, base64url; only while pairing.
    public let ticket: String?
    public init(url: URL, installID: String, deviceID: String? = nil, ticket: String? = nil) {
        self.url = url; self.installID = installID; self.deviceID = deviceID; self.ticket = ticket
    }

    /// Where a relay credential may go: https, or plain http to this machine for a local relay in tests.
    public static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" || (url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost"))
    }

    var socketURL: URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/v1/tunnel/phone"
        return components.url!
    }
}

/// The phone's end of the relay tunnel: a listener on 127.0.0.1 whose connections are carried as streams on one
/// WebSocket to the relay. `NWTransport` dials it with the pinned TLS to the Mac, so the relay sees only that TLS, and
/// a connection that doesn't open with a TLS handshake is dropped. Whoever else reaches the port gets a pipe to a Mac
/// that wants the pin and a token; the caps keep it from taking the streams the app needs. One per Mac per process;
/// everything runs on `queue`.
public final class RelayBridge: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle, connecting
        /// The relay socket is up; `mac` says whether the Mac's is.
        case open(mac: Bool)
        /// 4401: this device isn't on the Mac's list any more. Tried again only when asked.
        case refused
        case failed(String)
    }

    static let pingEvery: TimeInterval = 25
    /// A relay that doesn't answer a ping within this is gone, as after Wi-Fi hands over to cellular.
    static let pongWithin: TimeInterval = 10
    static let openWithin: TimeInterval = 6
    /// A connection has this long to start its TLS handshake.
    static let headWithin: TimeInterval = 5
    /// Live streams: the Mac takes 8 from one phone socket, so more wait here rather than be reset there.
    static let maxStreams = 8
    /// Connections waiting for a stream, and for their first bytes; beyond these, new ones are dropped.
    static let maxQueued = 16
    static let maxPending = 8

    public let route: RelayRoute
    let queue = DispatchQueue(label: "com.arnenoori.sidea.relay-bridge")
    private let authorization: @Sendable () async -> String?
    private let session: URLSession
    private var mux: TunnelMux!
    private var listener: NWListener?
    private var listenerPort: UInt16?
    private var portWaiters: [CheckedContinuation<UInt16, Error>] = []
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var nextStream: UInt32 = 1
    private var pinger: DispatchSourceTimer?
    private var openWaiters: [(Bool) -> Void] = []
    private var queued: [(connection: NWConnection, initial: Data)] = []
    private var pending = 0
    private var lastHeard = Date.distantPast
    private(set) var state: State = .idle
    public var stateChanged: (@Sendable (State) -> Void)?

    /// `authorization` is the whole header value: `Bearer d1.…` or `SideA-Pair <install>.<ticket>`.
    public init(route: RelayRoute, session: URLSession = .shared, authorization: @escaping @Sendable () async -> String?) {
        self.route = route; self.session = session; self.authorization = authorization
        mux = TunnelMux(queue: queue) { [weak self] frame in self?.send(.data(frame.encoded)) }
        mux.ended = { [weak self] _ in self?.next() }
    }

    deinit {
        listener?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// The proxy's port, listening from the first call on for as long as the bridge lives.
    public func port() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<UInt16, Error>) in
            queue.async { [self] in
                if let listenerPort { return done.resume(returning: listenerPort) }
                portWaiters.append(done)
                if listener == nil { listen() }
            }
        }
    }

    /// Opens the relay socket if it isn't, and says whether the Mac is on the other end.
    public func warm() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in whenOpen { done.resume(returning: $0) } }
        }
    }

    public var current: State { queue.sync { state } }
    public var streams: Int { queue.sync { mux.count } }

    /// The network changed: a relay socket that doesn't answer a ping within `within` is dropped, so the next stream
    /// opens a new one instead of waiting on a dead one.
    public func check(within: TimeInterval = 3) {
        queue.async { [self] in ping(within: within) }
    }

    /// Closes the relay socket; the proxy keeps listening and a new stream opens it again.
    public func close() {
        queue.async { [self] in
            socket?.cancel(with: .normalClosure, reason: nil)
            dropSocket(.idle)
        }
    }

    // MARK: Proxy

    private func listen() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return failPort(URLError(.cannotConnectToHost)) }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                self.listenerPort = listener.port?.rawValue
                for waiter in self.portWaiters { waiter.resume(returning: self.listenerPort ?? 0) }
                self.portWaiters = []
            case .failed:
                self.listener = nil; self.listenerPort = nil
                self.failPort(URLError(.cannotConnectToHost))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    private func failPort(_ error: Error) {
        for waiter in portWaiters { waiter.resume(throwing: error) }
        portWaiters = []
    }

    private func accept(_ connection: NWConnection) {
        guard pending < Self.maxPending, queued.count < Self.maxQueued else { return connection.cancel() }
        pending += 1
        connection.start(queue: queue)
        let settled = Flag()
        func settle() -> Bool {
            guard !settled.value else { return false }
            settled.value = true
            pending -= 1
            return true
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: TunnelFrame.maxPayload) { [weak self] data, _, _, _ in
            guard let self, settle() else { return }
            // Only a TLS handshake record: the connection is the stream itself.
            guard let data, data.first == 0x16 else { return connection.cancel() }
            self.open(connection, initial: data)
        }
        queue.asyncAfter(deadline: .now() + Self.headWithin) {
            guard settle() else { return }
            connection.cancel()
        }
    }

    private func open(_ connection: NWConnection, initial: Data) {
        whenOpen { [weak self] online in
            guard let self else { return }
            // The Mac isn't on the relay: the client's handshake fails at once instead of waiting it out.
            guard online, self.socket != nil else { return connection.cancel() }
            guard self.mux.count < Self.maxStreams else {
                guard self.queued.count < Self.maxQueued else { return connection.cancel() }
                return self.queued.append((connection, initial))
            }
            self.stream(connection, initial: initial)
        }
    }

    /// A stream ended: the longest-waiting connection takes its place.
    private func next() {
        while mux.count < Self.maxStreams, !queued.isEmpty {
            let (connection, initial) = queued.removeFirst()
            guard connection.state == .ready, socket != nil else { connection.cancel(); continue }
            stream(connection, initial: initial)
        }
    }

    private func stream(_ connection: NWConnection, initial: Data) {
        let id = streamID()
        send(.data(TunnelFrame(.open, id).encoded))
        mux.attach(id, connection, initial: initial)
    }

    private func streamID() -> UInt32 {
        let live = Set(mux.ids)
        repeat {
            nextStream = nextStream >= 0xffff ? 1 : nextStream + 1
        } while live.contains(nextStream)
        return nextStream
    }

    // MARK: Relay socket

    /// Runs `then` once the relay has said whether the Mac is there, opening the socket if needed.
    private func whenOpen(_ then: @escaping (Bool) -> Void) {
        if case .open(let mac) = state { return then(mac) }
        openWaiters.append(then)
        guard socket == nil else { return }
        openSocket()
    }

    private func openSocket() {
        generation += 1
        let generation = generation
        set(.connecting)
        let authorization = authorization
        let url = route.socketURL
        Task {
            let header = await authorization()
            queue.async { [self] in
                guard generation == self.generation else { return }
                guard let header else { return dropSocket(.failed("No relay credential")) }
                var request = URLRequest(url: url, timeoutInterval: Self.openWithin)
                request.setValue(header, forHTTPHeaderField: "Authorization")
                let task = session.webSocketTask(with: request)
                task.maximumMessageSize = TunnelFrame.header + TunnelFrame.maxPayload + 1024
                socket = task
                task.resume()
                receive(task, generation)
                queue.asyncAfter(deadline: .now() + Self.openWithin) { [weak self] in
                    guard let self, self.socket === task, self.state == .connecting else { return }
                    task.cancel(with: .goingAway, reason: nil)
                    self.dropSocket(.failed("The relay didn't answer"))
                }
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, _ generation: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation, self.socket === task else { return }
                switch result {
                case .failure:
                    let status = (task.response as? HTTPURLResponse)?.statusCode
                    let refused = status == 401 || task.closeCode.rawValue == 4401
                    self.dropSocket(refused ? .refused : .failed(status.map { "The relay answered \($0)" } ?? "The relay connection ended"))
                case .success(.string(let text)):
                    self.lastHeard = Date()
                    if let control = TunnelControl(text: text), control.type == "mac", let online = control.online { self.macChanged(online, task) }
                    self.receive(task, generation)
                case .success(.data(let data)):
                    self.lastHeard = Date()
                    if let frame = TunnelFrame(data) { self.mux.received(frame) }
                    self.receive(task, generation)
                case .success: self.receive(task, generation)
                }
            }
        }
    }

    private func macChanged(_ online: Bool, _ task: URLSessionWebSocketTask) {
        // Streams were with a Mac socket that is gone; URLSession sees its connections fail and asks again.
        if !online { mux.drop() }
        if pinger == nil { startPinging(task) }
        set(.open(mac: online))
        let waiters = openWaiters
        openWaiters = []
        for waiter in waiters { waiter(online) }
    }

    private func dropSocket(_ next: State) {
        generation += 1
        pinger?.cancel(); pinger = nil
        socket = nil
        mux.drop()
        for (connection, _) in queued { connection.cancel() }
        queued = []
        set(next)
        let waiters = openWaiters
        openWaiters = []
        for waiter in waiters { waiter(false) }
    }

    private func startPinging(_ task: URLSessionWebSocketTask) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingEvery, repeating: Self.pingEvery)
        timer.setEventHandler { [weak self] in
            guard let self, self.socket === task else { return }
            self.ping(within: Self.pongWithin)
        }
        timer.resume()
        pinger = timer
    }

    /// The relay answers `ping` itself, without waking the object; anything heard after it counts.
    private func ping(within: TimeInterval) {
        guard let task = socket, case .open = state else { return }
        let sent = Date()
        send(.string("ping"))
        queue.asyncAfter(deadline: .now() + within) { [weak self] in
            guard let self, self.socket === task, self.lastHeard < sent else { return }
            KitLog.log(.transport, "relay didn't answer a ping within \(Int(within)) s")
            task.cancel(with: .goingAway, reason: nil)
            self.dropSocket(.failed("The relay stopped answering"))
        }
    }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        guard let task = socket else { return }
        task.send(message) { [weak self] error in
            guard error != nil, let self else { return }
            self.queue.async {
                guard self.socket === task else { return }
                task.cancel(with: .goingAway, reason: nil)
                self.dropSocket(.failed("The relay connection ended"))
            }
        }
    }

    private func set(_ next: State) {
        guard next != state else { return }
        state = next
        stateChanged?(next)
    }
}
