import CryptoKit
import Foundation
import Network
import os
import SideACore
import SideAProtocol

/// The Mac's end of the relay tunnel (docs/remote/tunnel.md, The Mac): one outbound WebSocket to the install's object,
/// each stream on it spliced to `RemoteServer`'s loopback TLS listener. The phone's TLS ends there exactly as on the LAN,
/// so the pin, the token and every check are the same; this only moves bytes it can't read.
final class TunnelClient: @unchecked Sendable {
    enum Status: Sendable, Equatable {
        case off, connecting, connected
        case waiting(String)
    }

    /// Streams the Mac takes from one phone socket, and from all of them: well inside the server's 64 connections.
    static let perSlot = 8
    static let total = 24
    static let pingEvery: TimeInterval = 25
    static let pongWithin: TimeInterval = 10
    static let backoffCap: TimeInterval = 60
    /// The relay's CLOCK_SKEW: how far a signed `ts` may be from its clock.
    static let clockWindow: TimeInterval = 120

    let queue = DispatchQueue(label: "com.arnenoori.sidea.remote.tunnel")
    private let log = Logger(subsystem: "com.arnenoori.sidea", category: "tunnel")
    private let base: URL
    private let key: Curve25519.Signing.PrivateKey
    private let session: URLSession
    private let register: @Sendable () async throws -> Void
    /// The loopback port to splice a new stream to, asked per stream: it changes if the listener restarts.
    private let target: @Sendable (@escaping @Sendable (UInt16?) -> Void) -> Void
    var statusChanged: (@Sendable (Status) -> Void)?

    private var mux: TunnelMux!
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var running = false
    private var attempt = 0
    private var skew = 0
    /// The `ts` the latest upgrade was signed with.
    private var signed = 0
    /// Set once a clock refusal has been retried at once; cleared when a socket connects.
    private var reclocked = false
    private var registered = false
    /// Nil until the Mac can read its list: the relay keeps the one it has rather than being told nobody is paired.
    private var devices: [TunnelControl.Device]?
    /// The open pairing sheet's ticket.
    private var ticket: Data?
    /// Frames for streams whose loopback connection is still being made.
    private var opening: [UInt32: [TunnelFrame]] = [:]
    private var retry: DispatchWorkItem?
    private var pinger: DispatchSourceTimer?
    private var lastPong = Date()
    private(set) var status: Status = .off

    init(base: URL, key: Curve25519.Signing.PrivateKey, session: URLSession = .shared, register: @escaping @Sendable () async throws -> Void,
         target: @escaping @Sendable (@escaping @Sendable (UInt16?) -> Void) -> Void) {
        self.base = base; self.key = key; self.session = session; self.register = register; self.target = target
        mux = TunnelMux(queue: queue) { [weak self] frame in self?.send(.data(frame.encoded)) }
        mux.ended = { [weak self] id in self?.opening[id] = nil }
    }

    var url: URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/v1/tunnel/mac"
        return components.url!
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            connect()
        }
    }

    func stop() {
        queue.sync {
            running = false
            retry?.cancel()
            drop()
            set(.off)
        }
    }

    /// Who may connect: every paired device's id and secret hash. Sent now and on every reconnect.
    func setDevices(_ devices: [TunnelControl.Device]) {
        queue.async { [self] in
            self.devices = devices
            send(.string(TunnelControl(type: "devices", devices: devices).text))
        }
    }

    /// How long the relay honours a ticket after the Mac last named it. It's named again with every ping, so the ticket
    /// lives exactly as long as the sheet, give or take this much if the Mac vanishes with the sheet open.
    static let ticketWindow: TimeInterval = 120

    /// The pairing sheet's ticket while it's open; nil once it closes.
    func setPairing(ticket: Data?) {
        queue.async { [self] in
            self.ticket = ticket
            send(.string(pairing.text))
        }
    }

    private var pairing: TunnelControl {
        guard let ticket else { return TunnelControl(type: "pairing") }
        return TunnelControl(type: "pairing", ticketHash: Data(SHA256.hash(data: ticket)).base64URL,
                             expiresAt: Date().timeIntervalSince1970 + Self.ticketWindow)
    }

    /// A network change or a wake: a socket that's waiting tries now; a live one proves itself with a ping.
    func networkChanged() {
        queue.async { [self] in
            guard running else { return }
            log.info("network changed, \(self.socket == nil ? "connecting now" : "pinging", privacy: .public)")
            if socket == nil {
                retry?.cancel()
                attempt = 0
                connect()
            } else {
                ping()
            }
        }
    }

    var streams: Int { queue.sync { mux.count } }

    // MARK: Socket

    static func describe(_ status: Status) -> String {
        switch status {
        case .off: "off"
        case .connecting: "connecting to the relay"
        case .connected: "connected to the relay"
        case .waiting(let why): "waiting (\(why))"
        }
    }

    private func set(_ next: Status) {
        guard next != status else { return }
        status = next
        log.info("tunnel \(String(describing: next), privacy: .public), \(self.mux.count) streams")
        RemoteLog.shared("tunnel: \(Self.describe(next)), \(mux.count) streams")
        statusChanged?(next)
    }

    private func connect() {
        guard running, socket == nil else { return }
        set(.connecting)
        generation += 1
        let generation = generation
        let register = register
        Task {
            if !queue.sync(execute: { registered }) {
                do { try await register() } catch {
                    return queue.async { [self] in
                        guard generation == self.generation else { return }
                        fail("Can't reach the relay: \(error.localizedDescription)", unregistered: false)
                    }
                }
                queue.async { [self] in registered = true }
            }
            queue.async { [self] in
                guard running, generation == self.generation else { return }
                open(generation)
            }
        }
    }

    private func open(_ generation: Int) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        let ts = Int(Date().timeIntervalSince1970) + skew
        signed = ts
        guard let authorization = try? RelaySignature.authorization(key, method: "GET", path: "/v1/tunnel/mac", body: Data(), ts: ts) else {
            return fail("The relay key can't sign", unregistered: false)
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = TunnelFrame.header + TunnelFrame.maxPayload + 1024
        socket = task
        task.resume()
        // Queued behind the upgrade, so the relay has the device list before any phone it lets in reaches the Mac.
        if let devices { send(.string(TunnelControl(type: "devices", devices: devices).text)) }
        if ticket != nil { send(.string(pairing.text)) }
        receive(task, generation)
        startPinging(task)
        // The relay says nothing on its own; its pong is what says the socket is up.
        ping()
    }

    private func receive(_ task: URLSessionWebSocketTask, _ generation: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation, self.socket === task else { return }
                switch result {
                case .failure(let error): self.failed(task, error)
                case .success(let message):
                    if self.status != .connected { self.attempt = 0; self.reclocked = false; self.set(.connected) }
                    self.lastPong = Date()
                    switch message {
                    case .string(let text): self.control(text)
                    case .data(let data): self.frame(data)
                    @unknown default: break
                    }
                    self.receive(task, generation)
                }
            }
        }
    }

    private func failed(_ task: URLSessionWebSocketTask, _ error: Error) {
        let http = task.response as? HTTPURLResponse
        log.error("relay socket ended: HTTP \(http?.statusCode ?? 0), close \(task.closeCode.rawValue), \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        RemoteLog.shared("tunnel: relay socket ended: HTTP \(http?.statusCode ?? 0), close \(task.closeCode.rawValue), \((error as NSError).domain) \((error as NSError).code)")
        // Only a refusal's Date is the relay's clock now. A socket that ran and then ended still holds its 101, dated when
        // it opened: taken as the clock, it signed the next upgrade that far in the past.
        let relayNow = http?.statusCode == 101 ? nil : http?.value(forHTTPHeaderField: "Date").flatMap(RelayClient.httpDate)
        if let relayNow { skew = Int(relayNow.timeIntervalSinceNow.rounded()) }
        switch (http?.statusCode, task.closeCode.rawValue) {
        case (401?, _) where relayNow.map({ Self.outsideWindow(signed: signed, relay: $0) }) == true:
            // The socket can't read the refusal's code, but its Date says the time was refused, not the Mac.
            guard reclocked else {
                reclocked = true
                RemoteLog.shared("tunnel: the relay refused the time, \(skew) s off; trying again on its clock")
                drop()
                return connect()
            }
            fail("This Mac's clock is too far from the relay's", unregistered: false)
        // An install the relay forgot comes back under the same key, as with pushes.
        case (401?, _): fail("The relay didn't recognise this Mac", unregistered: true)
        case (503?, _): fail("The relay's tunnel is paused", unregistered: false, wait: 300)
        case (_, 4409): fail("Replaced by a newer connection", unregistered: false)
        case (_, 4401): fail("The relay key changed", unregistered: false)
        default: fail(error.localizedDescription, unregistered: false)
        }
    }

    /// Whether the relay, answering at `relay`, would have refused `signed` as skewed. Its `Date` is cut to the second
    /// and written a moment after the check, hence the two seconds' slack; a refusal it lets through as a clock
    /// refusal costs one immediate retry, which then reads as what it is.
    static func outsideWindow(signed: Int, relay: Date) -> Bool {
        abs(relay.timeIntervalSince1970 - Double(signed)) > clockWindow - 2
    }

    /// Drops the socket and every stream on it, then tries again after a backoff.
    private func fail(_ reason: String, unregistered: Bool, wait: TimeInterval? = nil) {
        drop()
        if unregistered { registered = false }
        guard running else { return }
        set(.waiting(reason))
        let delay = wait ?? min(Self.backoffCap, pow(2, Double(attempt))) * Double.random(in: 0.8...1.2)
        attempt += 1
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func drop() {
        generation += 1
        pinger?.cancel(); pinger = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        opening = [:]
        mux.drop()
    }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        guard let task = socket else { return }
        // Called in order on the queue, so frames go out in order.
        task.send(message) { [weak self] error in
            guard let error, let self else { return }
            self.queue.async { if self.socket === task { self.failed(task, error) } }
        }
    }

    private func startPinging(_ task: URLSessionWebSocketTask) {
        lastPong = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingEvery, repeating: Self.pingEvery)
        timer.setEventHandler { [weak self] in self?.ping() }
        timer.resume()
        pinger = timer
    }

    /// A text `ping`, answered by the relay without waking the object; any message counts as the answer.
    private func ping() {
        guard let task = socket else { return }
        let sent = Date()
        send(.string("ping"))
        if ticket != nil { send(.string(pairing.text)) }
        queue.asyncAfter(deadline: .now() + Self.pongWithin) { [weak self] in
            guard let self, self.socket === task, self.lastPong < sent else { return }
            self.fail("The relay stopped answering", unregistered: false)
        }
    }

    // MARK: Frames

    private func control(_ text: String) {
        guard text != "pong", let control = TunnelControl(text: text) else { return }
        // Relay input never traps: a slot out of range is ignored.
        if control.type == "gone", let value = control.slot, let slot = UInt32(exactly: value), slot <= 0xffff {
            let gone = opening.keys.filter { $0 >> 16 == slot }
            for id in gone { opening[id] = nil }
            mux.drop { $0 >> 16 == slot }
        }
    }

    private func frame(_ data: Data) {
        guard let frame = TunnelFrame(data) else { return }
        guard frame.kind == .open else {
            guard let waiting = opening[frame.stream] else { return mux.received(frame) }
            // What a phone may send before the stream is spliced: its credit window, the same as after.
            guard waiting.reduce(frame.payload.count, { $0 + $1.payload.count }) <= TunnelMux.Tuning().window, waiting.count < 64 else {
                opening[frame.stream] = nil
                return send(.data(TunnelFrame.reset(frame.stream, "over credit").encoded))
            }
            opening[frame.stream]!.append(frame)
            return
        }
        let slot = frame.stream >> 16
        let fromSlot = mux.ids.filter { $0 >> 16 == slot }.count + opening.keys.filter { $0 >> 16 == slot }.count
        guard mux.count + opening.count < Self.total, fromSlot < Self.perSlot else {
            log.error("refused a stream from slot \(slot): \(fromSlot) from it, \(self.mux.count + self.opening.count) in all")
            RemoteLog.shared("tunnel: refused a stream from slot \(slot): \(fromSlot) from it, \(mux.count + opening.count) in all")
            return send(.data(TunnelFrame.reset(frame.stream, "too_many_streams").encoded))
        }
        opening[frame.stream] = []
        let generation = generation
        target { [weak self] port in
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation, let waiting = self.opening.removeValue(forKey: frame.stream) else { return }
                guard let port, let nwPort = NWEndpoint.Port(rawValue: port) else {
                    return self.send(.data(TunnelFrame.reset(frame.stream, "mac_not_listening").encoded))
                }
                let parameters = NWParameters.tcp
                (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
                let connection = NWConnection(host: .ipv4(.loopback), port: nwPort, using: parameters)
                // The server sees loopback; this names the phone's slot instead, so tunnel phones never share a
                // budget with local processes (RemoteServer.stranger). Ready comes before any request: TLS needs a
                // round trip through the relay first.
                self.mux.attach(frame.stream, connection) { connection in
                    if case .hostPort(_, let local)? = connection.currentPath?.localEndpoint {
                        SplicedPeers.shared.set(local.rawValue, "tunnel slot \(slot)", source: "tunnel:\(slot)")
                    }
                }
                for queued in waiting { self.mux.received(queued) }
            }
        }
    }
}
