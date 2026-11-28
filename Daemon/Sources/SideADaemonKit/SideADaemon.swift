import Crypto
import Foundation
import SideACore
import SideAProtocol

public struct DaemonConfig: Sendable {
    public var paths: DaemonPaths
    /// Addresses to listen on. Empty means: this machine's tailnet addresses, plus its LAN ones with `lan`, and always loopback.
    public var listen: [String] = []
    public var lan = false
    /// Names a phone may also put in its Host header, for a daemon behind a port forward or a container's published port,
    /// where the address the phone dials is not one of this machine's own.
    public var allowedHosts: [String] = []
    public var port = 47800
    public var version = SideADaemon.version
    public var name: String = HostInfo.hostName()
    /// The id phones and linked computers know this host by. Two daemons in one test need two.
    public var hostID: String = HostInfo.machineID()
    public var os: HostOS = HostInfo.detectOS()
    /// Looks at `tailscale status` and the interfaces. Tests turn it off.
    public var discover = true
    public var threads = 2
    /// The notification relay, for the tunnel (phone away from home) and push. Nil: neither.
    public var relay: RelayConfig?

    public init(paths: DaemonPaths) { self.paths = paths }
}

/// What the daemon serves beyond pairing and the events socket: sessions, hosting, accounts. Each stage adds one.
public protocol DaemonServices: Sendable {
    var capabilities: Set<Capability> { get }
    /// The parts of `StateSnapshot` this service owns.
    func snapshot(into: StateParts) async -> StateParts
    /// Routes under `/v1`, matched before the 404.
    var routes: [DaemonRoute] { get }
    /// Called once the daemon is listening, and again with `stop` when it goes down.
    func start(_ daemon: SideADaemon) async
    func stop() async
    /// A command from the control socket that the core does not know (`sidead move`, `computers`, `unlink`): the JSON
    /// object to answer with, or nil when this service doesn't serve it either.
    func control(_ command: String, _ arguments: [String: String]) async -> Data?
}

public extension DaemonServices {
    func start(_ daemon: SideADaemon) async {}
    func stop() async {}
    func control(_ command: String, _ arguments: [String: String]) async -> Data? { nil }
}

public struct StateParts: Sendable {
    public var sessions: [RemoteSession] = []
    public var finished: [FinishedSession] = []
    public var requests: [RemoteRequest] = []
    public var hosted: [HostedSession] = []
    public var accounts: [RemoteAccount] = []
    public init() {}
}

public struct NoServices: DaemonServices {
    public var capabilities: Set<Capability> { [] }
    public func snapshot(into parts: StateParts) async -> StateParts { parts }
    public var routes: [DaemonRoute] { [] }
    public init() {}
}

/// One REST route: a method, a path pattern with `{name}` segments, and what answers it.
public struct DaemonRoute: Sendable {
    public let method: String
    public let pattern: [String]
    public let handle: @Sendable (RouteContext) async -> HTTPResponse

    public init(_ method: String, _ path: String, _ handle: @escaping @Sendable (RouteContext) async -> HTTPResponse) {
        self.method = method; pattern = path.split(separator: "/").map(String.init); self.handle = handle
    }
}

public struct RouteContext: Sendable {
    public let request: HTTPRequest
    public let device: String
    public let params: [String: String]
    public let daemon: SideADaemon

    public func body<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: request.body) }
}

/// The daemon: the paired devices, the pairing, the events hub and the REST routes, over one TLS listener.
public final class SideADaemon: Sendable {
    public static let version = "0.2.0"

    public let config: DaemonConfig
    public let store: any SecretStore
    public let identity: DaemonIdentity
    public let devices: DeviceRegistry
    public let ledger: IdempotencyLedger
    public let pairing: PairingBroker
    public let hub: EventHub
    public let epoch: String
    public let replay = ConfirmGate.ReplayCache()
    let relay: RelayLink?
    private let services: any DaemonServices
    private let state: State
    private let gate: GateBox

    /// What changes after `start`: where the server is, what it listens on and what it answers to.
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var server: DaemonServer?
        private var hosts: Set<String> = []
        private var addresses = RemoteAddresses()
        private var tailnetName: String?
        private var vouched: Set<String> = []

        func set(server: DaemonServer?, hosts: Set<String>, addresses: RemoteAddresses, tailnetName: String?) {
            lock.lock(); defer { lock.unlock() }
            self.server = server; self.hosts = hosts; self.addresses = addresses; self.tailnetName = tailnetName
        }
        var server_: DaemonServer? { lock.lock(); defer { lock.unlock() }; return server }
        var hosts_: Set<String> { lock.lock(); defer { lock.unlock() }; return hosts }
        var addresses_: RemoteAddresses { lock.lock(); defer { lock.unlock() }; return addresses }
        var tailnetName_: String? { lock.lock(); defer { lock.unlock() }; return tailnetName }
        func vouch(_ device: String) -> Bool { lock.lock(); defer { lock.unlock() }; return vouched.insert(device).inserted }
        func unvouch(_ device: String) { lock.lock(); defer { lock.unlock() }; vouched.remove(device) }
    }

    private actor GateBox {
        var gate = RequestGate(now: Date().timeIntervalSince1970)
        func admit(_ request: HTTPRequest, source: String, device: String?, hosts: Set<String>, port: UInt16) -> RequestGate.Refusal? {
            gate.admit(request, source: source, device: device, hosts: hosts, port: port, now: Date().timeIntervalSince1970)
        }
        func forget(_ device: String) { gate.forget(device: device) }
    }

    public init(config: DaemonConfig, store: (any SecretStore)? = nil, services: any DaemonServices = NoServices()) throws {
        self.config = config
        let store = store ?? FileSecretStore(directory: config.paths.state)
        self.store = store
        identity = try DaemonIdentity.loadOrCreate(in: store)
        devices = DeviceRegistry(store: store)
        ledger = IdempotencyLedger(store: store)
        let relay = try config.relay.map { try RelayLink(config: $0, store: store) }
        self.relay = relay
        pairing = PairingBroker(installID: relay?.installID)
        epoch = UUID().uuidString
        self.services = services
        let state = State()
        self.state = state
        gate = GateBox()
        let (identity, config, epoch) = (identity, config, epoch)
        let capabilities = Self.capabilities(services, relay: relay != nil)
        hub = EventHub(epoch: epoch, snapshot: { [services] seq, epoch in
            let parts = await services.snapshot(into: StateParts())
            return StateSnapshot(seq: seq, epoch: epoch, sessions: parts.sessions, finished: parts.finished, requests: parts.requests,
                                 hosted: parts.hosted, accounts: parts.accounts)
        }, hello: {
            Self.makeHello(config: config, identity: identity, epoch: epoch, capabilities: capabilities, state: state, paired: true, port: state.server_?.port ?? 0)
        })
    }

    static func capabilities(_ services: any DaemonServices, relay: Bool = false) -> Set<Capability> {
        services.capabilities.union(relay ? [.events, .push] : [.events])
    }

    public var port: Int { state.server_?.port ?? 0 }

    func servicesSnapshot() async -> StateParts { await services.snapshot(into: StateParts()) }

    func control(_ command: String, _ arguments: [String: String]) async -> Data? { await services.control(command, arguments) }

    /// What this host says it is, to phones and to the computers linked to it.
    public var me: MacInfo { MacInfo(id: config.hostID, name: config.name, os: config.os, headless: true) }

    // MARK: Lifecycle

    /// Binds and starts answering. With `config.discover`, the tailnet and LAN addresses are looked up first.
    public func start() async throws {
        let (listen, hosts, addresses, tailnetName) = Self.plan(config)
        let server = try await DaemonServer.start(identity: identity, addresses: listen, port: config.port, threads: config.threads,
                                                  stamp: { [epoch] response in
            response.headers.add("X-SideA-Protocol", "1")
            response.headers.add("X-SideA-Epoch", epoch)
            response.headers.add("Cache-Control", response.headers["Cache-Control"] ?? "no-store")
        }, handler: { [weak self] request, connection in
            guard let self else { return .response(.apiError(503, .notReady, "Side A is stopping.", retryAfter: 5)) }
            return await handle(request, connection)
        })
        state.set(server: server, hosts: hosts, addresses: addresses, tailnetName: tailnetName)
        await services.start(self)
        await relay?.start(self)
        Task { [pairing] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await pairing.tick()
            }
        }
    }

    public func stop() async throws {
        await services.stop()
        await relay?.stop()
        await hub.closeAll(code: 1001, reason: "quit")
        await devices.flush()
        try await state.server_?.stop()
        state.set(server: nil, hosts: [], addresses: RemoteAddresses(), tailnetName: nil)
    }

    /// Where to listen, the Host names to answer to, the addresses a phone is told, and the tailnet's DNS name.
    static func plan(_ config: DaemonConfig) -> (listen: [String], hosts: Set<String>, addresses: RemoteAddresses, tailnetName: String?) {
        var hosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        var addresses = RemoteAddresses()
        var tailnetName: String?
        var listen = config.listen
        if config.discover {
            let tailscale = HostInfo.tailscale()
            tailnetName = tailscale.dnsName
            let found = RemoteAddresses.current()
            addresses = RemoteAddresses(tailnet: tailscale.addresses.isEmpty ? found.tailnet : tailscale.addresses, lan: config.lan ? found.lan : [])
            if listen.isEmpty { listen = addresses.tailnet.filter { !$0.contains(":") } + addresses.lan }
            if let name = tailscale.dnsName { hosts.insert(name.lowercased()) }
            hosts.formUnion(addresses.tailnet.map { $0.lowercased() })
            hosts.formUnion(addresses.lan)
            hosts.insert(HostInfo.hostName().lowercased())
        }
        listen = listen.filter { !$0.contains(":") || $0 == "::1" }
        // Nothing was looked up, so a phone or a Mac is told the addresses named with `--listen`: telling it loopback
        // would send it to itself. Loopback only when that, or every address, is all there is to say.
        if !config.discover {
            for address in listen where !["0.0.0.0", "127.0.0.1", "::1", "localhost"].contains(address) && !address.hasPrefix("127.") {
                if RemoteAddresses.isTailnet(address) { addresses.tailnet.append(address) } else { addresses.lan.append(address) }
            }
        }
        // The tunnel reaches this listener on loopback, so with a relay it is always there.
        let covered = listen.contains("0.0.0.0") || listen.contains("127.0.0.1")
        if !covered && (config.listen.isEmpty || config.relay?.tunnel == true) { listen.append("127.0.0.1") }
        if config.relay?.tunnel == true { hosts.insert(Self.relayHost) }
        for address in listen { hosts.insert(address.lowercased()) }
        hosts.formUnion(config.allowedHosts.map { $0.lowercased() })
        return (listen, hosts, addresses, tailnetName)
    }

    // MARK: What the phone is told

    // swiftlint:disable:next discouraged_optional_boolean -- nil: the caller showed no token, so it is neither paired nor refused.
    static func makeHello(config: DaemonConfig, identity: DaemonIdentity, epoch: String, capabilities: Set<Capability>, state: State?, paired: Bool?,
                          port: Int = 0) -> Hello {
        let known = paired == true
        let mac = MacInfo(id: config.hostID, name: config.name, os: config.os, headless: true)
        return Hello(app: config.version, build: 0, mac: known ? mac : MacInfo(id: "", name: ""), capabilities: known ? capabilities : [],
                     minClientBuild: RemotePolicy.minClientBuild, epoch: epoch, serverTime: Date().timeIntervalSince1970, paired: paired, remoteOn: true,
                     endpoints: known ? endpoints(state: state, port: port) : Endpoints(tailnet: ""), keyID: known ? identity.keyID : "")
    }

    private static func endpoints(state: State?, port: Int) -> Endpoints {
        guard let state else { return Endpoints(tailnet: "") }
        let addresses = state.addresses_
        let lans = addresses.lan.map { hostPort($0, port) }
        if let tailnet = addresses.tailnet.first {
            return Endpoints(tailnet: hostPort(tailnet, port), name: state.tailnetName_.map { "\($0):\(port)" }, lan: lans.first, lans: lans.isEmpty ? nil : lans)
        }
        if let first = lans.first { return Endpoints(tailnet: first, lan: first, lans: lans) }
        return Endpoints(tailnet: hostPort("127.0.0.1", port))
    }

    /// The Host a phone sends over the relay: it can't resolve, so no browser can send it (docs/remote/tunnel.md).
    static let relayHost = "sidea-relay.invalid"

    static func hostPort(_ address: String, _ port: Int) -> String { address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)" }

    // swiftlint:disable:next discouraged_optional_boolean -- as makeHello.
    public func hello(paired: Bool?) -> Hello {
        Self.makeHello(config: config, identity: identity, epoch: epoch, capabilities: Self.capabilities(services, relay: relay != nil), state: state, paired: paired, port: port)
    }

    public func link(code: String) -> String {
        let addresses = state.addresses_
        let mac = me
        let lans = addresses.lan.map { Self.hostPort($0, port) }
        let primary = addresses.tailnet.first.map { Self.hostPort($0, port) } ?? lans.first ?? Self.hostPort("127.0.0.1", port)
        let viaRelay = relay.flatMap { link in link.ticket.map { (url: link.url, installID: link.installID, ticket: $0) } }
        return PairingLink.make(address: primary, lan: lans.filter { $0 != primary }, spki: Secret.base64url(identity.spkiHash) ?? Data(),
                                mac: mac, tailnetName: state.tailnetName_, code: code, relay: viaRelay)
    }

    public func status() async -> [String: String] {
        let paired = await devices.devices
        var relayState: [String: String] = [:]
        if let relay { relayState = ["relay": relay.url.absoluteString, "tunnel": relay.status, "install": relay.installID] }
        return relayState.merging(["version": config.version, "os": config.os.rawValue, "name": config.name, "port": String(port), "key": identity.keyID,
                "fingerprint": identity.spkiHash, "devices": String(paired.count), "secrets": store.kind,
                "state": config.paths.state.path]) { $1 }
    }

    /// `sidead pair` opened or closed a pairing: the relay's ticket for it lives exactly that long.
    public func pairingOpened(_ open: Bool) { relay?.pairing(open: open) }

    /// A session finished a turn; a phone that asked is told through the relay.
    func sessionFinished(_ turn: FinishedSession) async { await relay?.finished(turn, daemon: self) }

    // MARK: Requests

    func handle(_ request: HTTPRequest, _ connection: DaemonServer.Connection) async -> DaemonServer.Reply {
        // A phone that reaches the daemon through a name or address it hasn't been told about is refused by Host.
        let presented = request.headers["Authorization"]?.hasPrefix("Bearer ") == true
        let token = presented ? String((request.headers["Authorization"] ?? "").dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil
        if presented, await devices.hashes == nil, request.path != ["v1", "pair"], !RequestGate.attempt(request) {
            return .response(.apiError(503, .notReady, "Side A can't read its paired devices right now.", retryAfter: 5))
        }
        let device = await token.asyncMap { await devices.device(token: $0) }.flatMap { $0 }
        if let refusal = await gate.admit(request, source: connection.source, device: device?.id, hosts: state.hosts_, port: UInt16(truncatingIfNeeded: port)) {
            return .response(HTTPResponse(refusal))
        }
        if let device, state.vouch(device.id) { await devices.seen(device.id) }
        if request.path.count >= 2, request.path[0] == "v1", request.path[1] == "ws" {
            guard let device else { return .response(.apiError(401, .unauthorized, "This device isn't paired with Side A. Pair it again.")) }
            return await upgrade(request, device: device.id, connection: connection)
        }
        return .response(await route(request, connection, device: device?.id, rejected: device == nil && presented))
    }

    func route(_ request: HTTPRequest, _ connection: DaemonServer.Connection, device: String?, rejected: Bool) async -> HTTPResponse {
        if request.method == "POST" || request.method == "DELETE", !RequestGate.open(request), !RequestGate.unrecorded(request),
           !Self.idempotentByItself(request), let device {
            guard let key = request.headers["Idempotency-Key"], !key.isEmpty, key.count <= IdempotencyLedger.maxKey else {
                return .apiError(400, .missingIdempotencyKey, "Send an Idempotency-Key.")
            }
            return await idempotent(request, connection, device: device, key: key)
        }
        return await dispatch(request, connection, device: device, rejected: rejected)
    }

    private static let replayWait: Duration = .seconds(60)

    private func idempotent(_ request: HTTPRequest, _ connection: DaemonServer.Connection, device: String, key: String) async -> HTTPResponse {
        let now = Date().timeIntervalSince1970
        switch await ledger.begin(device: device, key: key, method: request.method, path: request.target, body: request.body, now: now) {
        case .replay(let status, let contentType, let body):
            var response = HTTPResponse(status: status, body: body)
            if let contentType { response.headers.add("Content-Type", contentType) }
            response.headers.add("Idempotent-Replay", "true")
            return response
        case .mismatch: return .apiError(422, .idempotencyMismatch, "This Idempotency-Key was used with another request.")
        case .unknown: return .apiError(409, .outcomeUnknown, "Side A quit before it could say whether this reached the computer.")
        case .unavailable: return .apiError(503, .notReady, "Side A couldn't record this request, so it didn't run.")
        case .running:
            guard await ledger.settled(device: device, key: key, within: Self.replayWait) else {
                return .apiError(409, .inProgress, "The first of these is still running.")
            }
            return await idempotent(request, connection, device: device, key: key)
        case .run:
            let response = await dispatch(request, connection, device: device, rejected: false)
            await ledger.finish(device: device, key: key, status: response.status, contentType: response.headers["Content-Type"], body: response.body)
            return response
        }
    }

    private func dispatch(_ request: HTTPRequest, _ connection: DaemonServer.Connection, device: String?, rejected: Bool) async -> HTTPResponse {
        var methods: [String] = []
        let all = coreRoutes(connection: connection, rejected: rejected) + services.routes
        for route in all {
            guard let params = Self.match(route.pattern, request.path) else { continue }
            guard route.method == request.method else { methods.append(route.method); continue }
            return Self.tagged(await route.handle(RouteContext(request: request, device: device ?? "", params: params, daemon: self)), request)
        }
        if !methods.isEmpty {
            var response = HTTPResponse.apiError(405, .badRequest, "\(request.method) isn't served here.")
            response.headers.add("Allow", methods.joined(separator: ", "))
            return response
        }
        return .apiError(404, .notFound, "There's nothing at \(request.path.joined(separator: "/")).")
    }

    static func match(_ pattern: [String], _ path: [String]) -> [String: String]? {
        guard pattern.count == path.count else { return nil }
        var params: [String: String] = [:]
        for (part, segment) in zip(pattern, path) {
            if part.hasPrefix("{") { params[String(part.dropFirst().dropLast())] = segment } else if part != segment { return nil }
        }
        return params
    }

    /// A JSON GET carries its body's hash as an ETag; a phone that already has that body gets a 304 and no bytes.
    static func tagged(_ response: HTTPResponse, _ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET", response.status == 200, response.headers["ETag"] == nil,
              response.headers["Content-Type"] == "application/json" else { return response }
        let tag = "\"\(Data(SHA256.hash(data: response.body).prefix(16)).base64URL)\""
        var headers = HTTPHeaders([("ETag", tag), ("Cache-Control", "private, no-cache")])
        let known = request.headers["If-None-Match"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        if known.contains(where: { $0 == "*" || $0 == tag || $0 == "W/" + tag }) { return HTTPResponse(status: 304, headers: headers) }
        for field in response.headers.fields { headers.add(field.name, field.value) }
        return HTTPResponse(status: 200, headers: headers, body: response.body)
    }

    // MARK: Devices

    public func revoke(_ id: String) async {
        do { try await devices.remove(id) } catch { DaemonLog.line("couldn't save the device list after a removal: \(error.localizedDescription)") }
        await hub.close(device: id, reason: "revoked")
        await ledger.forget(device: id)
        await gate.forget(id)
        state.unvouch(id)
        relay?.devicesChanged(await devices.devices)
        relay?.forget(id)
    }

    func completePairing(_ attemptID: String) async -> PairResponse? {
        guard let (attempt, key) = await pairing.takeApproved(attemptID) else { return nil }
        let request = attempt.request
        let token = DeviceToken.make()
        let device = PairedDevice(id: request.deviceID, name: String(request.device.name.prefix(100)), model: String(request.device.model.prefix(40)),
                                  system: String(request.device.system.prefix(40)), app: String(request.device.app.prefix(20)), build: request.device.build,
                                  hash: DeviceToken.hash(token), secretHash: request.deviceSecretHash, pushKey: key?.data, pushKeyID: key?.keyID,
                                  confirmKey: Self.p256(request.confirmKey), unlockKey: Self.p256(request.unlockKey), push: nil,
                                  capabilities: request.device.capabilities, created: Date().timeIntervalSince1970, lastSeen: nil)
        let sameID = await devices.device(id: device.id) != nil
        do { try await devices.add(device, replacing: request.replaces) } catch {
            await pairing.finished(attemptID, saved: false)
            return nil
        }
        await pairing.finished(attemptID, saved: true)
        relay?.devicesChanged(await devices.devices)
        if let old = request.replaces, old != device.id { await revoke(old) }
        if sameID { await hub.close(device: device.id, reason: "replaced") }
        return PairResponse(token: token, deviceID: device.id, mac: me,
                            relay: relay.flatMap { link in key.map { RelayInfo(url: link.url.absoluteString, installID: link.installID, keyID: $0.keyID.base64URL) } },
                            hello: hello(paired: true))
    }

    /// An X9.63 P-256 public key as the phone sent it, or nil when it isn't one.
    static func p256(_ key: String?) -> String? {
        guard let key, let data = Data(base64URL: key), data.count == 65, data.first == 0x04 else { return nil }
        return key
    }

    // MARK: Events

    public func upgrade(_ request: HTTPRequest, device: String, connection: DaemonServer.Connection) async -> DaemonServer.Reply {
        guard request.path == ["v1", "ws", "events"] else { return .response(.apiError(404, .notFound, "There's nothing at \(request.path.joined(separator: "/")).")) }
        switch WebSocketCodec.handshake(request) {
        case .failure(let error): return .response(.apiError(error.status, .badRequest, error.message))
        case .success(let response):
            guard await hub.socketCount(device: device) < EventHub.socketsPerDevice else {
                return .response(.apiError(429, .rateLimited, "Too many connections from this device.", retryAfter: 10))
            }
            return .upgrade(response, open: { [hub] peer in hub.attach(peer, device: device) })
        }
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        switch self { case .some(let value): await transform(value); case .none: nil }
    }
}
