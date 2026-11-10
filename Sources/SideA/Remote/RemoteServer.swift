import Foundation
import Network
import Security
import SideACore

/// Side A's own TLS listener for Remote: one port for REST and both WebSockets, on the tailnet address (and the LAN
/// with Wi-Fi pairing). Like `IslandServer`, everything here runs on one serial queue.
final class RemoteServer: @unchecked Sendable {
    /// Who sent a request. `device` is nil before auth and on the routes that don't need it.
    struct Caller: Sendable {
        let device: String?
        let connection: UInt64
        /// The address it came from (the phone's, not loopback's, for a spliced connection), for per-address limits.
        var source: String = ""
        /// It presented a token the Mac's device list doesn't have.
        var rejected = false
    }

    typealias Handler = @Sendable (HTTPRequest, Caller) async -> HTTPResponse

    enum ListenerState: Sendable, Equatable { case starting, ready, failed(String) }

    static let maxConnections = 64
    static let requestsPerConnection = 1_000
    static let socketsPerDevice = 4

    /// A request's head has `head` seconds from its first byte; its body may go `body` seconds without a byte, so a
    /// large upload over a slow link takes as long as it keeps coming; a connection with nothing to do goes after `idle`.
    struct Timeouts: Sendable {
        var head: TimeInterval = 10
        var body: TimeInterval = 30
        /// A whole upload, however steadily it arrives.
        var upload: TimeInterval = 600
        var idle: TimeInterval = 30
    }

    /// Tests shorten these.
    var timeouts = Timeouts()

    let queue = DispatchQueue(label: "com.arnenoori.sidea.remote")
    let epoch: String
    private let identity: RemoteKeychain.Identity
    private let handler: Handler
    /// Called on the queue with each new WebSocket after its 101.
    var opened: (@Sendable (WebSocketPeer) -> Void)?
    var stateChanged: (@Sendable ([String: ListenerState]) -> Void)?
    /// A connection closed, with any request on it still running: a pairing wait whose phone went away.
    var connectionClosed: (@Sendable (UInt64) -> Void)?
    /// A device's first authenticated request since this server started: proof the phone holds its token.
    var authenticated: (@Sendable (String) -> Void)?
    private var vouched: Set<String> = []

    /// One per address the phone can reach, each relaying to `inner`; see SocketFront for why it isn't an NWListener.
    private var listeners: [String: SocketFront] = [:]
    /// TLS terminates here, on a loopback port of its own choosing.
    private var inner: NWListener?
    private var innerPort: UInt16?
    /// The relay tunnel splices its streams into `inner` too, so it stays up while the tunnel runs, addresses or not.
    private var tunnel = false
    private var portWaiters: [@Sendable (UInt16?) -> Void] = []
    private var states: [String: ListenerState] = [:]
    private(set) var port: UInt16 = 0
    private var hosts: Set<String> = []
    private var connections: [UInt64: HTTPConnection] = [:]
    private var sockets: [UInt64: WebSocketPeer] = [:]
    private var nextID: UInt64 = 0
    /// nil: the paired devices couldn't be read, so no token is accepted.
    private var devices: [(id: String, hash: Data)]? = []
    /// For the confirm signatures (ConfirmSignature): this Mac's id and each device's public keys.
    var macID = ""
    private var confirmKeys: [String: ConfirmGate.Keys] = [:]
    let replay = ConfirmGate.ReplayCache()
    /// Callers without a token: each address its own small budget with a lockout, and all of them together a larger
    /// one, so one address (or one local process on loopback) can't use up what a phone pairing needs.
    private var strangers: [String: RemotePolicy.TokenBucket] = [:]
    private var unauthenticated = RemotePolicy.TokenBucket(rate: 1, burst: 40, now: 0)
    /// Waits on, and cancels of, an attempt the phone already has: a re-poll after a dropped connection mustn't spend
    /// the budget a new pairing needs.
    private var attempts = RemotePolicy.TokenBucket(rate: 1, burst: 10, now: 0)
    private var perDevice: [String: RemotePolicy.TokenBucket] = [:]
    private var answers: [String: RemotePolicy.TokenBucket] = [:]
    private let idempotency: IdempotencyStore
    private var waitingForFirst: [String: [@Sendable () -> Void]] = [:]
    private var trimmed = Date()
    /// The last few failures, for Copy Diagnostics. No tokens or hashes.
    private(set) var errors: [String] = []

    init(identity: RemoteKeychain.Identity, epoch: String, idempotency: IdempotencyStore = IdempotencyStore(url: nil), handler: @escaping Handler) {
        self.identity = identity; self.epoch = epoch; self.handler = handler; self.idempotency = idempotency
        unauthenticated = RemotePolicy.TokenBucket(rate: 1, burst: 40, now: Date().timeIntervalSince1970)
        strangers = [:]
        attempts = RemotePolicy.TokenBucket(rate: 1, burst: 10, now: Date().timeIntervalSince1970)
    }

    // MARK: Listeners

    /// Listens on exactly these addresses, starting and stopping listeners to match. `names` are the other names the
    /// Mac answers to in `Host` (its MagicDNS and `.local` names).
    func serve(addresses: [String], port: UInt16, names: Set<String> = []) {
        queue.async { [self] in
            if port != self.port {
                for address in Array(listeners.keys) { stopListener(address) }
                self.port = port
            }
            hosts = Set(addresses.map { $0.lowercased() }).union(names.map { $0.lowercased() })
            for address in Array(listeners.keys) where !addresses.contains(address) { stopListener(address) }
            for address in addresses where listeners[address] == nil { startListener(address) }
            report()
        }
    }

    func stop() {
        queue.sync {
            tunnel = false
            for address in Array(listeners.keys) { stopListener(address) }
            stopInner()
            answerPortWaiters()
            for socket in sockets.values { socket.close(1001, "") }
            for connection in connections.values { connection.cancel() }
            connections = [:]; sockets = [:]
            report()
        }
    }

    /// While on, the loopback TLS listener stays up for the relay tunnel even with no address to serve; off, it goes
    /// with the last address.
    func setTunnel(_ on: Bool) {
        queue.async { [self] in
            tunnel = on
            if on && inner == nil { startInner() }
            if !on && listeners.isEmpty { stopInner(); answerPortWaiters() }
        }
    }

    /// The loopback port a tunnel stream splices to, asked per stream since the listener picks a new one if it restarts.
    /// nil when it can't listen. Called back on the queue.
    func tunnelPort(_ done: @escaping @Sendable (UInt16?) -> Void) {
        queue.async { [self] in
            guard tunnel else { return done(nil) }
            if let innerPort { return done(innerPort) }
            portWaiters.append(done)
            if inner == nil { startInner() }
        }
    }

    private func answerPortWaiters() {
        let waiters = portWaiters
        portWaiters = []
        for waiter in waiters { waiter(innerPort) }
    }

    private func startListener(_ address: String) {
        if inner == nil { startInner() }
        do {
            listeners[address] = try SocketFront(address: address, port: port, queue: queue) { [weak self] in self?.innerPort }
        } catch {
            return fail(address, Self.describe(error))
        }
        RemoteLog.shared("listening on \(address):\(port) (\(RemoteLog.network(address)))")
        states[address] = innerPort == nil ? .starting : .ready
    }

    private func startInner() {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity.identity) else { return failAll("Side A's security key can't be used for TLS.") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { return failAll(error.localizedDescription) }
        inner = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.inner === listener else { return }
            switch state {
            case .ready:
                self.innerPort = listener.port?.rawValue
                RemoteLog.shared("TLS listener ready on loopback port \(listener.port?.rawValue ?? 0)")
                for address in self.listeners.keys { self.states[address] = .ready }
                self.answerPortWaiters()
            case .failed(let error), .waiting(let error):
                RemoteLog.shared("TLS listener failed: \(error)")
                self.failAll(Self.describe(error))
            default: return
            }
            self.report()
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    private func stopInner() {
        inner?.cancel()
        inner = nil; innerPort = nil
    }

    /// The tunnel's flag stays set, so its next stream starts the listener again.
    private func failAll(_ message: String) {
        stopInner()
        answerPortWaiters()
        for address in Array(listeners.keys) { fail(address, message) }
    }

    private func stopListener(_ address: String) {
        if listeners[address] != nil { RemoteLog.shared("stopped listening on \(address):\(port)") }
        listeners.removeValue(forKey: address)?.cancel()
        states[address] = nil
        if listeners.isEmpty && !tunnel { stopInner() }
    }

    private func fail(_ address: String, _ message: String) {
        listeners.removeValue(forKey: address)?.cancel()
        if listeners.isEmpty && !tunnel { stopInner() }
        states[address] = .failed(message)
        note("Listening on \(address):\(port) failed: \(message)")
        RemoteLog.shared("listening on \(address):\(port) failed: \(message)")
        report()
    }

    private func report() { stateChanged?(states) }

    /// What a listener on a taken port fails with; the controller moves up a port on it.
    static let portInUse = "Port in use"

    static func describe(_ error: Error) -> String {
        switch (error as? POSIXError)?.code {
        case .EADDRINUSE?: portInUse
        case .EADDRNOTAVAIL?: "The address isn't on this Mac any more"
        default: (error as? NWError).map(describe) ?? error.localizedDescription
        }
    }

    static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE { return portInUse }
        if case .posix(let code) = error, code == .EADDRNOTAVAIL { return "The address isn't on this Mac any more" }
        return error.localizedDescription
    }

    // MARK: Devices

    func setDevices(_ devices: [(id: String, hash: Data)]?, keys: [String: ConfirmGate.Keys] = [:]) {
        queue.async { [self] in
            // Unreadable isn't removed: a list that can't be read says nothing about who is on it.
            guard let devices else {
                self.devices = nil
                return
            }
            // A device paired again under the same id has a new token: whatever the old one opened goes too.
            let old = Dictionary((self.devices ?? []).map { ($0.id, $0.hash) }, uniquingKeysWith: { a, _ in a })
            let replaced = Set(devices.filter { device in old[device.id].map { $0 != device.hash } ?? false }.map(\.id))
            self.devices = devices
            confirmKeys = keys
            let ids = Set(devices.map(\.id))
            // A device paired again, or paired anew after a revoke, proves its new token afresh.
            vouched = vouched.filter { ids.contains($0) && !replaced.contains($0) }
            for socket in sockets.values where !ids.contains(socket.device) || replaced.contains(socket.device) {
                socket.close(4401, replaced.contains(socket.device) ? "replaced" : "revoked")
            }
            for id in Array(perDevice.keys) where !ids.contains(id) { perDevice[id] = nil; answers[id] = nil }
            previews = previews.filter { ids.contains($0.value.device) && !replaced.contains($0.value.device) }
        }
    }

    /// Revoking: the device's sockets close with 4401 and its idempotency records go.
    func revoke(_ device: String) {
        queue.async { [self] in
            devices?.removeAll { $0.id == device }
            vouched.remove(device)
            for socket in sockets.values where socket.device == device { socket.close(4401, "revoked") }
            idempotency.forget(device: device)
            previews = previews.filter { $0.value.device != device }
        }
    }

    /// Before a relaunch: whoever owns each socket says goodbye first (`bye`), then 1001 so the phone reconnects quietly.
    var farewell: (@Sendable (WebSocketPeer, String) -> Void)?
    // MARK: Previews

    /// A dev server a phone is previewing, by its credential.
    struct Preview: Sendable, Equatable {
        let port: UInt16
        /// The dev server's process; nil only in tests that serve a port nobody owns.
        var pid: Int32? = nil
        let device: String
        let expires: Date
    }

    static let previewCookie = "sidea_preview"
    private var previews: [String: Preview] = [:]
    /// Forwards one request to `127.0.0.1:port` as `target`; `cookie` is set on the reply when the request came by the
    /// credential's own path.
    var proxy: (@Sendable (_ request: HTTPRequest, _ port: UInt16, _ target: String, _ cookie: String?) async -> HTTPResponse)?

    /// Credentials whose link was opened once already: after that only their cookie opens them, so a shared or
    /// copied link opens nothing in another browser.
    private var spentPreviews: Set<String> = []

    func setPreviews(_ next: [String: Preview]) {
        queue.async { [self] in
            previews = next
            spentPreviews.formIntersection(next.keys)
        }
    }

    private static func hasPreviewCookie(_ request: HTTPRequest, _ token: String) -> Bool {
        (request.headers["Cookie"] ?? "").split(separator: ";").contains { $0.trimmingCharacters(in: .whitespaces) == "\(previewCookie)=\(token)" }
    }

    /// `/v1/preview/<credential>/…`, or any path outside `/v1` that carries a live credential's cookie: a page's
    /// absolute links (`/assets/app.js`) land at the root.
    /// Only a device paired now: a credential outlives nothing its device lost.
    private func preview(_ request: HTTPRequest) -> (token: String, preview: Preview, target: String, byPath: Bool)? {
        guard let match = previewMatch(request), devices?.contains(where: { $0.id == match.preview.device }) == true else { return nil }
        return match
    }

    private func previewMatch(_ request: HTTPRequest) -> (token: String, preview: Preview, target: String, byPath: Bool)? {
        if request.path.count >= 3, request.path[0] == "v1", request.path[1] == "preview" {
            let token = request.path[2]
            let prefix = "/v1/preview/" + token
            guard let preview = previews[token], request.target.hasPrefix(prefix) else { return nil }
            let rest = String(request.target.dropFirst(prefix.count))
            return (token, preview, rest.isEmpty ? "/" : rest.hasPrefix("?") ? "/" + rest : rest, true)
        }
        guard request.path.first != "v1", let cookies = request.headers["Cookie"] else { return nil }
        for pair in cookies.split(separator: ";") {
            let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == Self.previewCookie, let preview = previews[parts[1]] {
                return (parts[1], preview, request.target, false)
            }
        }
        return nil
    }

    private func servePreview(_ request: HTTPRequest, _ match: (token: String, preview: Preview, target: String, byPath: Bool),
                              reply: @escaping @Sendable (HTTPResponse) -> Void) {
        let now = Date().timeIntervalSince1970
        switch RemotePolicy.checkPreview(request.headers, hosts: hosts, port: port) {
        case .host?: return reply(Self.error(421, "bad_host", "This address isn't one of the Mac's own."))
        case .browser?: return reply(Self.error(403, "forbidden_origin", "Only the preview's own pages can use it."))
        case nil: break
        }
        guard match.preview.expires > Date(), !request.wantsUpgrade, let proxy else {
            return reply(Self.error(404, "not_found", "This preview has ended. Open it again from the session."))
        }
        if match.byPath, !Self.hasPreviewCookie(request, match.token) {
            guard spentPreviews.insert(match.token).inserted else {
                return reply(Self.error(404, "not_found", "This preview link was already opened. Open it again from the session."))
            }
        }
        let device = match.preview.device
        if let wait = perDevice[device, default: RemotePolicy.TokenBucket(rate: 20, burst: 60, now: now)].take(now: now) { return reply(Self.limited(wait)) }
        let cookie = match.byPath ? match.token : nil
        let preview = match.preview
        Task {
            if let pid = preview.pid, !PortOwner.listens(pid: pid, port: preview.port) {
                return reply(Self.error(404, "not_found", "The dev server behind this preview has stopped. Open it again from the session."))
            }
            let response = await proxy(request, preview.port, match.target, cookie)
            // Nothing answered: the link isn't spent, so the phone can try again once the dev server is up.
            if match.byPath, response.status == 502 { queue.async { [self] in spentPreviews.remove(match.token) } }
            reply(response)
        }
    }

    /// The harness's crash switch: runs after a keyed request's handler and before its result is recorded.
    var beforeRecording: (@Sendable (HTTPRequest) -> Void)?

    func goodbye(_ reason: String) {
        queue.sync {
            for socket in sockets.values {
                farewell?(socket, reason)
                socket.close(1001, reason)
            }
        }
    }

    var recentErrors: [String] { queue.sync { errors } }
    var listenerStates: [String: ListenerState] { queue.sync { states } }

    func note(_ error: String) {
        errors.append("\(Date().formatted(.iso8601)) \(error)")
        if errors.count > 20 { errors.removeFirst(errors.count - 20) }
    }

    // MARK: Connections

    private func accept(_ nw: NWConnection) {
        if connections.count >= Self.maxConnections {
            // The oldest idle one makes room; with none idle, this one is refused.
            if let idle = connections.values.filter({ $0.idle }).min(by: { $0.lastActive < $1.lastActive }) {
                idle.cancel(); connections[idle.id] = nil
            } else {
                RemoteLog.shared("refused a connection: \(Self.maxConnections) open, none idle")
                nw.cancel(); return
            }
        }
        nextID += 1
        var peer = "\(nw.endpoint)", source = "", local: UInt16?
        if case .hostPort(let host, let port) = nw.endpoint {
            source = "\(host)"
            if let outside = SplicedPeers.shared.take(port.rawValue) { (peer, source) = outside } else { local = port.rawValue }
        }
        let connection = HTTPConnection(id: nextID, connection: nw, server: self, peer: peer, source: source, loopback: local)
        connections[nextID] = connection
        connection.start()
    }

    func closed(_ id: UInt64) {
        connections[id] = nil
        sockets[id]?.ended()
        sockets[id] = nil
        connectionClosed?(id)
    }

    /// A token arrived while the device list can't be read. It gets 503, so the phone keeps its pairing and asks again.
    var devicesUnavailable: (@Sendable () -> Void)?

    /// Bearer tokens. With the device list unreadable, nothing matches.
    /// What a caller who isn't signed in may send: a pairing request is a few hundred bytes. 64 connections of it
    /// come to 4 MiB, not the 1.25 GiB of uploads they could hold before.
    static let unauthenticatedBody = 64 << 10
    static let uploadBody = 20 << 20

    /// Asked by the parser once a request's head is in, on the queue: a body is only kept for someone who may send it.
    func bodyLimit(_ head: HTTPRequest) -> Int? {
        if device(head) != nil { return head.method == "POST" && head.path == ["v1", "uploads"] ? Self.uploadBody : nil }
        if preview(head) != nil { return nil }
        return Self.unauthenticatedBody
    }

    private func stranger(_ source: String, now: TimeInterval) -> TimeInterval? {
        if strangers.count > 512 { strangers = [:] }
        if let wait = strangers[RemotePolicy.budget(source), default: RemotePolicy.TokenBucket(rate: 10.0 / 60, burst: 5, lockout: 60, now: now)].take(now: now) { return wait }
        return unauthenticated.take(now: now)
    }

    private func device(_ request: HTTPRequest) -> String? {
        guard let value = request.headers["Authorization"], value.hasPrefix("Bearer "), let devices else { return nil }
        let token = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        guard token.hasPrefix(DeviceToken.prefix), token.count < 100 else { return nil }
        return DeviceToken.match(token, in: devices.map(\.hash)).map { devices[$0].id }
    }

    private static func open(_ request: HTTPRequest) -> Bool {
        let path = request.path
        if request.method == "GET" && path == ["v1", "hello"] { return true }
        if request.method == "POST" && path == ["v1", "pair"] { return true }
        return attempt(request)
    }

    /// `POST /v1/pair/{attempt}/wait` and `DELETE /v1/pair/{attempt}`.
    private static func attempt(_ request: HTTPRequest) -> Bool {
        let path = request.path
        guard path.count >= 3, path[0] == "v1", path[1] == "pair" else { return false }
        return request.method == "POST" && path.count == 4 && path[3] == "wait" || request.method == "DELETE" && path.count == 3
    }

    private static func answering(_ request: HTTPRequest) -> Bool {
        request.method == "POST" && request.path.first == "v1" && ["answer", "reply", "interrupt"].contains(request.path.last ?? "")
    }

    /// Every request, in order: a preview's own path, then Host and Origin, rate limit, auth, idempotency, the route.
    func handle(_ request: HTTPRequest, on connection: HTTPConnection, reply: @escaping @Sendable (HTTPResponse) -> Void) {
        // A preview's credential stands in for the device's token, for that one port and only until it expires.
        if let match = preview(request) { return servePreview(request, match, reply: reply) }
        let now = Date().timeIntervalSince1970
        switch RemotePolicy.check(request.headers, hosts: hosts, port: port) {
        case .host?: return reply(Self.error(421, "bad_host", "This address isn't one of the Mac's own."))
        case .browser?: return reply(Self.error(403, "forbidden_origin", "Browsers can't use Side A Remote."))
        case nil: break
        }
        let presented = request.headers["Authorization"]?.hasPrefix("Bearer ") == true
        if presented, devices == nil, request.path != ["v1", "pair"], !Self.attempt(request) {
            devicesUnavailable?()
            return reply(Self.error(503, "not_ready", "Side A can't read its paired devices right now.", retryAfter: 5))
        }
        let device = device(request)
        if let device, vouched.insert(device).inserted { authenticated?(device) }
        let open = Self.open(request)
        if device == nil {
            if Self.attempt(request) {
                if let wait = attempts.take(now: now) { return reply(Self.limited(wait)) }
            } else if let wait = stranger(connection.source, now: now) { return reply(Self.limited(wait)) }
            guard open else {
                var response = Self.error(401, "unauthorized", "This iPhone isn't paired with Side A. Pair it again.")
                response.headers.add("WWW-Authenticate", "Bearer")
                return reply(response)
            }
        } else if let device {
            if let wait = perDevice[device, default: RemotePolicy.TokenBucket(rate: 20, burst: 60, now: now)].take(now: now) { return reply(Self.limited(wait)) }
            if Self.answering(request), let wait = answers[device, default: RemotePolicy.TokenBucket(rate: 0.5, burst: 30, now: now)].take(now: now) {
                return reply(Self.limited(wait))
            }
        }
        // A phone too old to sign hears why, in the state it already has for this, rather than a refusal per call.
        if device != nil, !open, let build = RemotePolicy.clientBuild(request.headers["X-SideA-Client"]), build < RemotePolicy.minClientBuild {
            return reply(Self.error(426, "upgrade_client", "Update Side A Remote to use it with this Mac."))
        }
        let caller = Caller(device: device, connection: connection.id, source: connection.source, rejected: device == nil && presented)
        if request.path.count >= 2, request.path[0] == "v1", request.path[1] == "ws" {
            guard let device else { return reply(Self.error(401, "unauthorized", "This iPhone isn't paired with Side A. Pair it again.")) }
            // A terminal is a shell: opening one takes Face ID on the phone, proven by its Secure Enclave key.
            if request.path.count == 4, request.path[2] == "term",
               let refusal = Self.confirm(request.headers[ConfirmSignature.header], macID: macID, device: device, purpose: .terminal,
                                          subject: ConfirmMessage.subject(terminal: request.path[3]), needs: .biometric,
                                          keys: confirmKeys[device] ?? ConfirmGate.Keys(confirm: nil, unlock: nil), replay: replay) {
                return reply(refusal)
            }
            return upgrade(request, device: device, on: connection, reply: reply)
        }
        if (request.method == "POST" || request.method == "DELETE"), !open, let device {
            guard let key = request.headers["Idempotency-Key"], !key.isEmpty, key.count <= IdempotencyStore.maxKey else {
                return reply(Self.error(400, "missing_idempotency_key", "Send an Idempotency-Key."))
            }
            return idempotent(request, device: device, key: key, caller: caller, reply: reply)
        }
        run(request, caller, reply)
    }

    /// Nil when the request carries a signature for at least `needs`; otherwise the 401 to answer with. Off the queue only.
    func confirm(_ request: HTTPRequest, device: String, purpose: ConfirmPurpose, subject: String, needs: ConfirmProof) -> HTTPResponse? {
        guard needs > .none else { return nil }
        let keys = queue.sync { confirmKeys[device] } ?? ConfirmGate.Keys(confirm: nil, unlock: nil)
        return Self.confirm(request.headers[ConfirmSignature.header], macID: macID, device: device, purpose: purpose, subject: subject,
                            needs: needs, keys: keys, replay: replay)
    }

    static func confirm(_ header: String?, macID: String, device: String, purpose: ConfirmPurpose, subject: String, needs: ConfirmProof,
                        keys: ConfirmGate.Keys, replay: ConfirmGate.ReplayCache) -> HTTPResponse? {
        guard needs > .none else { return nil }
        var details = APIError.confirmDetails(level: needs.level ?? .unlock, pairAgain: keys.isEmpty)
        let what = needs == .biometric ? "Confirm with Face ID on your iPhone." : "Unlock your iPhone to do this."
        switch ConfirmGate.verify(header, macID: macID, deviceID: device, purpose: purpose, subject: subject, keys: keys, replay: replay) {
        case .success(let level) where level >= needs: return nil
        case .success, .failure(.missing):
            return error(401, "confirm_required", keys.isEmpty ? "Pair this iPhone again to do this from it." : what, details: details)
        case .failure(let failure):
            details["reason"] = failure.rawValue
            return error(401, "confirm_invalid", what, details: details)
        }
    }

    private func run(_ request: HTTPRequest, _ caller: Caller, _ reply: @escaping @Sendable (HTTPResponse) -> Void) {
        let handler = handler
        Task { reply(await handler(request, caller)) }
    }

    private func idempotent(_ request: HTTPRequest, device: String, key: String, caller: Caller, reply: @escaping @Sendable (HTTPResponse) -> Void) {
        let now = Date().timeIntervalSince1970
        if now - trimmed.timeIntervalSince1970 > 3_600 { trimmed = Date(); idempotency.trim(now: now) }
        switch idempotency.begin(device: device, key: key, method: request.method, path: request.target, body: request.body, now: now) {
        case .replay(let status, let contentType, let body):
            var response = HTTPResponse(status: status, body: body)
            if let contentType { response.headers.add("Content-Type", contentType) }
            response.headers.add("Idempotent-Replay", "true")
            reply(response)
        case .mismatch:
            reply(Self.error(422, "idempotency_mismatch", "This Idempotency-Key was used with another request."))
        case .unknown:
            reply(Self.error(409, "outcome_unknown", "Side A quit before it could say whether this reached the Mac."))
        case .unavailable:
            note("idempotency record couldn't be written")
            reply(Self.error(503, "not_ready", "Side A couldn't record this request, so it didn't run."))
        case .running:
            waitingForFirst[device + "\n" + key, default: []].append { [weak self] in
                self?.idempotent(request, device: device, key: key, caller: caller, reply: reply)
            }
        case .run:
            let handler = handler
            Task {
                let response = await handler(request, caller)
                self.queue.async { [self] in
                    beforeRecording?(request)
                    idempotency.finish(device: device, key: key, status: response.status, contentType: response.headers["Content-Type"], body: response.body)
                    reply(response)
                    for waiter in waitingForFirst.removeValue(forKey: device + "\n" + key) ?? [] { waiter() }
                }
            }
        }
    }

    private func upgrade(_ request: HTTPRequest, device: String, on connection: HTTPConnection, reply: @escaping @Sendable (HTTPResponse) -> Void) {
        switch WebSocketCodec.handshake(request) {
        case .failure(let error): return reply(Self.error(error.status, "bad_request", error.message))
        case .success(let response):
            guard sockets.values.filter({ $0.device == device }).count < Self.socketsPerDevice else {
                return reply(Self.error(429, "rate_limited", "Too many connections from this iPhone.", retryAfter: 10))
            }
            let peer = WebSocketPeer(id: connection.id, device: device, path: request.path, connection: connection)
            sockets[connection.id] = peer
            RemoteLog.shared("#\(connection.id) WebSocket open \(RemoteLog.path(request)) device \(device.prefix(6))")
            // Its owner attaches first: frames may have come in the same packet as the upgrade.
            opened?(peer)
            peer.startKeepalive(on: queue)
            connection.upgrade(response, to: peer)
        }
    }

    // MARK: Responses

    func stamp(_ response: inout HTTPResponse) {
        response.headers.add("X-SideA-Protocol", "1")
        response.headers.add("X-SideA-Epoch", epoch)
        response.headers.add("Cache-Control", response.headers["Cache-Control"] ?? "no-store")
    }

    /// `{"error": {"code", "message", "retryable"}}`, as protocol's APIError.
    static func error(_ status: Int, _ code: String, _ message: String, details: [String: String]? = nil, retryAfter: Int? = nil) -> HTTPResponse {
        var error: [String: Any] = ["code": code, "message": message, "retryable": status == 429 || status == 503 || code == "in_progress"]
        if let details { error["details"] = details }
        let body = (try? JSONSerialization.data(withJSONObject: ["error": error], options: [.sortedKeys])) ?? Data()
        var response = HTTPResponse.json(status, body)
        if let retryAfter { response.headers.add("Retry-After", String(retryAfter)) }
        return response
    }

    private static func limited(_ wait: TimeInterval) -> HTTPResponse {
        error(429, "rate_limited", "Too many requests. Try again shortly.", retryAfter: max(1, Int(wait.rounded(.up))))
    }
}

/// One TCP connection: TLS from Network.framework, HTTP/1.1 from `HTTPParser`, and after an upgrade, WebSocket frames.
/// Requests are answered strictly in order; the next starts only once the last response is written.
final class HTTPConnection: @unchecked Sendable {
    let id: UInt64
    private let connection: NWConnection
    private weak var server: RemoteServer?
    private lazy var parser = HTTPParser { [weak self] head in
        guard let self else { return RemoteServer.unauthenticatedBody }
        return headIn(head)
    }
    /// Heads parsed whose body hasn't all arrived.
    private var unfinished = 0
    private var queued: [HTTPRequest] = []
    /// Reading stops while this many requests, or bytes of them, wait behind a slow one, and goes on as they drain.
    static let maxQueued = 4
    static let maxQueuedBytes = 2 << 20
    private var queuedBytes = 0
    private var paused = false
    private var busy = false
    private var served = 0
    private var closing = false
    private var headTimer: DispatchWorkItem?
    private var bodyTimer: DispatchWorkItem?
    private var idleTimer: DispatchWorkItem?
    private(set) var lastActive = Date()
    private var peer: WebSocketPeer?
    private var ended = false
    /// Who it is, for the log: the outside peer SocketFront spliced in.
    private let from: String
    /// The bare address behind it, for per-address limits. A tunnel stream's slot may be recorded only once its side
    /// is ready, after the accept, so a loopback peer is looked up again on first use.
    private var known: String
    private var loopback: UInt16?
    var source: String {
        if let port = loopback, let spliced = SplicedPeers.shared.take(port) { known = spliced.source }
        loopback = nil
        return known
    }
    private let opened = Date()
    private var secured = false

    var idle: Bool { !busy && queued.isEmpty && peer == nil && unfinished == 0 }

    init(id: UInt64, connection: NWConnection, server: RemoteServer, peer: String = "", source: String = "", loopback: UInt16? = nil) {
        self.id = id; self.connection = connection; self.server = server; from = peer; known = source; self.loopback = loopback
    }

    private func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    private var queue: DispatchQueue { server?.queue ?? .main }
    private var timeouts: RemoteServer.Timeouts { server?.timeouts ?? RemoteServer.Timeouts() }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                secured = true
                RemoteLog.shared("#\(id) TLS ok in \(milliseconds(since: opened)) ms from \(from)")
            case .waiting(let error):
                RemoteLog.shared("#\(id) TLS waiting after \(milliseconds(since: opened)) ms from \(from): \(error)")
            case .failed(let error):
                RemoteLog.shared("#\(id) \(secured ? "failed" : "TLS failed") after \(milliseconds(since: opened)) ms from \(from): \(error)")
                finish()
            case .cancelled: finish()
            default: break
            }
        }
        connection.start(queue: queue)
        armIdle()
        receive()
    }

    func cancel() { connection.cancel(); finish() }

    private func finish() {
        guard !ended else { return }
        ended = true
        RemoteLog.shared("#\(id) closed after \(milliseconds(since: opened)) ms, \(served) request\(served == 1 ? "" : "s")"
                         + (secured ? "" : ", before TLS finished"))
        headTimer?.cancel(); bodyTimer?.cancel(); idleTimer?.cancel()
        server?.closed(id)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.received(data) }
            if let error, !self.ended {
                RemoteLog.shared("#\(self.id) \(self.secured ? "read failed" : "TLS failed") after \(self.milliseconds(since: self.opened)) ms from \(self.from): \(error)")
            }
            if complete || error != nil { self.cancel(); return }
            guard !self.ended else { return }
            if self.peer == nil, self.queued.count >= Self.maxQueued || self.queuedBytes >= Self.maxQueuedBytes { self.paused = true } else { self.receive() }
        }
    }

    private func resume() {
        guard paused, !ended else { return }
        paused = false
        receive()
    }

    private func received(_ data: Data) {
        lastActive = Date()
        if let peer { peer.received(data); return }
        guard !closing else { return }
        if headTimer == nil && !busy && unfinished == 0 { headTimer = cancel(after: timeouts.head) }
        for result in parser.feed(data) {
            switch result {
            case .success(let request):
                unfinished -= 1
                queued.append(request)
                queuedBytes += request.body.count
            case .failure(let error):
                RemoteLog.shared("#\(id) unreadable request: \(error.status) \(error.message)")
                queued.removeAll()
                queuedBytes = 0
                closing = true
                write(RemoteServer.error(error.status, "bad_request", error.message), close: true)
                return
            }
        }
        // Each byte of a body puts its clock back: only a body that stops arriving ends the connection.
        bodyTimer?.cancel()
        bodyTimer = unfinished > 0 ? cancel(after: timeouts.body) : nil
        next()
    }

    /// On the queue, from the parser: the head is in. Only an upload's clock changes, to one long enough for a
    /// photo over cellular; anything else still has to arrive whole within the head's time, so a stranger
    /// can't hold a connection by sending a byte now and then.
    private func headIn(_ head: HTTPRequest) -> Int? {
        unfinished += 1
        // Nil from the server means the parser's usual limit; no server, a stranger's.
        guard let server else { return RemoteServer.unauthenticatedBody }
        let limit = server.bodyLimit(head)
        if limit == RemoteServer.uploadBody {
            headTimer?.cancel()
            headTimer = cancel(after: timeouts.upload)
        }
        return limit
    }

    private func cancel(after seconds: TimeInterval) -> DispatchWorkItem {
        let timer = DispatchWorkItem { [weak self] in self?.cancel() }
        queue.asyncAfter(deadline: .now() + seconds, execute: timer)
        return timer
    }

    private func next() {
        guard !busy, !closing, !queued.isEmpty, let server else { return }
        let request = queued.removeFirst()
        queuedBytes -= request.body.count
        if queued.count < Self.maxQueued && queuedBytes < Self.maxQueuedBytes { resume() }
        busy = true
        headTimer?.cancel(); headTimer = nil
        idleTimer?.cancel()
        served += 1
        let started = Date(), line = "#\(id) \(request.method) \(RemoteLog.path(request))"
        server.handle(request, on: self) { [weak self] response in
            guard let self else { return }
            RemoteLog.shared("\(line) \(response.status) \(milliseconds(since: started)) ms")
            self.queue.async {
                guard self.peer == nil else { return }
                let close = !request.keepAlive || self.served >= RemoteServer.requestsPerConnection
                self.write(response, close: close)
                self.busy = false
                if close { self.closing = true; return }
                self.armIdle()
                self.next()
            }
        }
    }

    private func armIdle() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.idle else { return }
            self.cancel()
        }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + timeouts.idle, execute: timer)
    }

    private func write(_ response: HTTPResponse, close: Bool) {
        var response = response
        server?.stamp(&response)
        connection.send(content: response.encoded(close: close), completion: .contentProcessed { [weak self] _ in
            if close { self?.cancel() }
        })
    }

    /// Writes the 101, then hands every later byte, including any already read, to the socket.
    func upgrade(_ response: HTTPResponse, to peer: WebSocketPeer) {
        self.peer = peer
        busy = false
        idleTimer?.cancel(); headTimer?.cancel(); bodyTimer?.cancel()
        connection.send(content: response.encoded(close: false), completion: .contentProcessed { _ in })
        let rest = parser.takeRemainder()
        if !rest.isEmpty { peer.received(rest) }
        resume()
    }

    func send(_ data: Data, done: @escaping @Sendable () -> Void) {
        connection.send(content: data, completion: .contentProcessed { _ in done() })
    }

    func sendThenClose(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.cancel() })
    }
}

/// A WebSocket after its upgrade. What it carries is up to whoever `RemoteServer.opened` hands it to.
final class WebSocketPeer: @unchecked Sendable {
    static let maxQueued = 1 << 20
    static let pingEvery: TimeInterval = 15
    static let silentFor: TimeInterval = 45

    let id: UInt64
    let device: String
    let path: [String]
    private weak var connection: HTTPConnection?
    private var parser = WebSocketCodec.Parser()
    private var queuedBytes = 0
    private var closed = false
    private var heard = Date()
    private var pinger: DispatchSourceTimer?
    /// Set by the owner on the server's queue.
    var message: ((WebSocketCodec.Message) -> Void)?
    var ending: (() -> Void)?
    /// After each frame has gone out, so a producer that paused for `queued` can carry on.
    var sent: (() -> Void)?

    /// Bytes waiting to go out.
    var queued: Int { queuedBytes }

    init(id: UInt64, device: String, path: [String], connection: HTTPConnection) {
        self.id = id; self.device = device; self.path = path; self.connection = connection
    }

    func startKeepalive(on queue: DispatchQueue) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingEvery, repeating: Self.pingEvery)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if -self.heard.timeIntervalSinceNow > Self.silentFor { self.close(1001, "silent"); return }
            self.write(WebSocketCodec.frame(.ping(Data())))
        }
        timer.resume()
        pinger = timer
    }

    func received(_ data: Data) {
        guard !closed else { return }
        heard = Date()
        for result in parser.feed(data) {
            switch result {
            case .failure(let failure): close(failure.code, failure.reason); return
            case .success(.ping(let payload)): write(WebSocketCodec.frame(.pong(payload)))
            case .success(.pong): break
            case .success(.close(let code, _)): close(code == nil ? 1000 : code == 1005 ? 1000 : code!, "")
            case .success(let other): message?(other)
            }
            if closed { return }
        }
    }

    func send(_ message: WebSocketCodec.Message) { write(WebSocketCodec.frame(message)) }

    /// Over 1 MiB waiting to go out, the phone is too slow: it reconnects and catches up from its `lastSeq`.
    private func write(_ frame: Data) {
        guard !closed, let connection else { return }
        if queuedBytes + frame.count > Self.maxQueued { close(4008, "too slow"); return }
        queuedBytes += frame.count
        connection.send(frame) { [weak self] in
            guard let self else { return }
            queuedBytes -= frame.count
            sent?()
        }
    }

    func close(_ code: UInt16, _ reason: String) {
        guard !closed else { return }
        RemoteLog.shared("#\(id) WebSocket closed \(code)" + (reason.isEmpty ? "" : " \(reason)"))
        closed = true
        pinger?.cancel()
        connection?.sendThenClose(WebSocketCodec.frame(.close(code: code, reason: reason)))
        ended()
    }

    func ended() {
        if !closed { RemoteLog.shared("#\(id) WebSocket dropped without a close") }
        closed = true
        pinger?.cancel()
        let ending = ending
        self.ending = nil
        ending?()
    }
}
