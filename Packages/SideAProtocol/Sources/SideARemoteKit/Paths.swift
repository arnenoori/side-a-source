import Foundation
import Network
import SideAProtocol

/// No path answered and the relay turned this phone away (401 or 4401): the Mac doesn't list it, most likely because
/// it was removed there. Not proof enough to unpair: a relay that lost its device list says the same until the Mac
/// reconnects and sends it, so the next race asks the relay again.
public struct RelayRefused: LocalizedError, Sendable, Equatable {
    public init() {}
    public var errorDescription: String? { "The relay turned this iPhone away. If it was removed on the Mac, pair it again." }
}

/// How this process reaches one Mac right now: one of its direct addresses (LAN, tailnet, MagicDNS) or the relay
/// tunnel, raced happy-eyeballs style and switched on the fly (docs/remote/tunnel.md, Paths and RoutedTransport).
/// The TLS key is pinned the same on every path, so which one carries a request is invisible above the transport.
public actor Paths {
    public enum Path: Sendable, Hashable, CustomStringConvertible {
        case direct(URL)
        case relay

        public var isRelay: Bool { self == .relay }
        public var description: String {
            switch self {
            case .direct(let url): url.host.map { "\($0)" } ?? url.absoluteString
            case .relay: "relay"
            }
        }
    }

    public struct Timing: Sendable {
        public var directTimeout: TimeInterval = 2.5
        public var relayTimeout: TimeInterval = 8
        /// After the relay answers, how long a direct address still has to win.
        public var preferDirect: TimeInterval = 0.3
        /// While on the relay, how often the direct addresses are tried again.
        public var recheck: TimeInterval = 30
        /// A direct address takes over from the relay only after answering this many checks in a row.
        public var promoteAfter = 2
        /// After a race finds nothing, no new race for 1 s, doubling to this; a network change or the foreground ends the wait.
        public var quietCap: TimeInterval = 30
        /// A relay that doesn't answer sits out races for 30 s, doubling to this.
        public var relayQuietCap: TimeInterval = 300
        /// After a network change, how long a relay that doesn't answer is asked once more instead of sitting out: its
        /// socket may still be on the interface that went, as when Wi-Fi hands over to cellular.
        public var settle: TimeInterval = 10
        /// The ports to try on an address that refuses the one it names.
        public var siblingPorts: @Sendable (Int) -> [Int] = Paths.siblingPorts(of:)
        public init() {}
    }

    /// The name the relay path's URLs use. It never resolves: the CONNECT proxy ignores it and the Mac accepts it as Host.
    public static let relayHost = "sidea-relay.invalid"
    public static let relayBase = URL(string: "https://\(relayHost)")!

    public private(set) var endpoint: Endpoint
    public private(set) var current: Path?
    /// Bumped on every switch; sockets opened under an older one move.
    private(set) var generation = 0
    nonisolated let trust: PinnedTrust
    nonisolated let direct: NWTransport
    private let timing: Timing
    private let bridge: RelayBridge?
    private var relayTransport: NWTransport?
    private var race: Task<Path?, Never>?
    private var sockets: [ObjectIdentifier: Weak] = [:]
    private var monitor: NWPathMonitor?
    private var lastNetwork: String?
    private var rechecking: Task<Void, Never>?
    private var streak: [URL: Int] = [:]
    private var listeners: [UUID: @Sendable (Path?) -> Void] = [:]
    /// Forgotten: a client made before the unpair finds no path, and nothing races or warms the relay again.
    private var stopped = false
    /// Why each path didn't answer in the last race that found none.
    private var failures: [Path: Error] = [:]
    /// Races in a row that found nothing, and until when a request fails at once instead of racing again.
    private var misses = 0
    private var quietUntil: Date?
    private var relayMisses = 0
    private var relayQuietUntil: Date?
    private var networkChangedAt: Date?
    /// Debug builds launched with SIDEA_RELAY_ONLY=1: no direct address is raced or rechecked, so a test on the same
    /// Wi-Fi as the Mac still goes through the relay.
    private let relayOnly: Bool

    private struct Weak { weak var socket: RoutedSocket? }

    /// Where a Mac whose port was taken may have moved: up to nine above each build's base (RemoteController.basePort).
    public static func siblingPorts(of port: Int) -> [Int] {
        for base in [47800, 47900] where (base...base + 9).contains(port) { return (base...base + 9).filter { $0 != port } }
        return []
    }

    /// `authorization` is the relay header for this Mac (`Bearer d1.…`, or a pairing ticket); nil without a relay.
    public init(endpoint: Endpoint, timing: Timing = Timing(), monitorNetwork: Bool = true,
                authorization: (@Sendable () async -> String?)? = nil) {
        self.endpoint = endpoint; self.timing = timing
        trust = PinnedTrust(.pinned(endpoint.serverKeyHash))
        direct = NWTransport(trust: trust)
        if let relay = endpoint.relay, let authorization {
            let bridge = RelayBridge(route: relay, authorization: authorization)
            bridge.stateChanged = { state in KitLog.log(.transport, "relay \(state)") }
            self.bridge = bridge
        } else {
            bridge = nil
        }
        #if DEBUG
        relayOnly = ProcessInfo.processInfo.environment["SIDEA_RELAY_ONLY"] == "1"
        #else
        relayOnly = false
        #endif
        if monitorNetwork { Task { await self.watchNetwork() } }
    }

    // MARK: Shared

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared: [String: Paths] = [:]

    /// One per Mac and key per process, so the app's engine, its image loads and Test Connection agree on a path.
    public static func shared(for endpoint: Endpoint, credentials: any CredentialStore) -> Paths {
        lock.withLock {
            // The device too: re-paired in the same process, the old route's device id mustn't go out with the new secret.
            let key = [endpoint.macID, endpoint.serverKeyHash, endpoint.relay?.installID ?? "", endpoint.relay?.deviceID ?? ""].joined(separator: "\n")
            if let paths = shared[key] { return paths }
            var authorization: (@Sendable () async -> String?)?
            if let relay = endpoint.relay {
                authorization = { await Paths.bearer(relay, macID: endpoint.macID, credentials: credentials) }
            }
            let paths = Paths(endpoint: endpoint, authorization: authorization)
            shared[key] = paths
            return paths
        }
    }

    /// A Mac was unpaired or re-paired: its paths stop, relay socket and network watch included, its cached reads go, and
    /// the next client for it starts fresh.
    public static func forget(macID: String) {
        ResponseCache.shared.forget(macID: macID)
        let gone = lock.withLock {
            let keys = shared.keys.filter { $0.hasPrefix(macID + "\n") }
            return keys.compactMap { shared.removeValue(forKey: $0) }
        }
        for paths in gone { Task { await paths.stop() } }
    }

    private func stop() {
        stopped = true
        race?.cancel()
        current = nil
        for entry in sockets.values { entry.socket?.moved(to: generation + 1) }
        sockets = [:]
        monitor?.cancel()
        monitor = nil
        rechecking?.cancel()
        bridge?.close()
    }

    /// The relay header for `relay`: its pairing ticket, or the device credential from `credentials`.
    public static func bearer(_ relay: RelayRoute, macID: String, credentials: any CredentialStore) async -> String? {
        guard RelayRoute.allowed(relay.url) else { return nil }
        if let ticket = relay.ticket { return "SideA-Pair \(relay.installID).\(ticket)" }
        guard let device = relay.deviceID, let secret = try? await credentials.relaySecret(for: macID) else { return nil }
        return "Bearer d1.\(relay.installID).\(device).\(secret.base64URL)"
    }


    // MARK: Choosing

    /// The path to use now, racing for one when there is none.
    public func path() async -> Path? {
        guard !stopped else { return nil }
        if let current { return current }
        return await choose()
    }

    /// Calls `changed` on every switch, and once now.
    public func observe(_ changed: @escaping @Sendable (Path?) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = changed
        changed(current)
        return id
    }

    public func stopObserving(_ id: UUID) { listeners[id] = nil }

    /// Races every path and takes the winner. Concurrent callers share one race.
    @discardableResult public func choose() async -> Path? {
        guard !stopped else { return nil }
        if let race { return await race.value }
        // The Mac didn't answer a moment ago: fail now rather than wait out the same timeouts again.
        if let quietUntil, quietUntil > .now { return nil }
        let task = Task { await self.run(self.candidates) }
        race = task
        let winner = await task.value
        race = nil
        if let winner {
            misses = 0
            quietUntil = nil
            await switchTo(winner)
        } else {
            misses += 1
            let wait = min(timing.quietCap, pow(2, Double(misses - 1)))
            quietUntil = .now.addingTimeInterval(wait)
            KitLog.log(.transport, "no path to \(endpoint.name); next race in \(Int(wait)) s")
        }
        return winner
    }

    /// The app came to the foreground: race at once, whatever the backoff says. A resting relay keeps resting:
    /// the foreground doesn't make it any likelier to answer, while a network change might.
    public func foreground() async {
        misses = 0
        quietUntil = nil
        if current == nil { await choose() } else { await networkChanged() }
    }

    /// Test Connection: the path in use, or a fresh race with the relay back in, whatever the backoff says. A test opened
    /// because the Mac dropped would otherwise find the race resting and report it unreachable without trying.
    public func retest() async -> Path? {
        guard !stopped else { return nil }
        // A race already running may have left the relay out; let it finish, then race with everything.
        if let race { _ = await race.value }
        misses = 0
        quietUntil = nil
        relayQuietUntil = nil
        return await path()
    }

    /// A request on `path` failed for want of a connection: race again if it's still the one in use.
    public func failed(_ path: Path) async -> Path? {
        KitLog.log(.transport, "path \(path) failed")
        guard path == current else {
            if let current { return current }
            return await choose()
        }
        KitLog.log(.transport, "path \(path) lost a connection, racing again")
        // What's kept on it went the same way; a request on one would wait out its timeout.
        if path.isRelay { relayTransport?.reset() } else { direct.reset() }
        current = nil
        return await choose()
    }

    /// The network changed: race again, and move if something else wins. The old path keeps working until then.
    public func networkChanged() async {
        guard !stopped else { return }
        misses = 0
        quietUntil = nil
        relayQuietUntil = nil
        guard current != nil else { return }
        if let winner = await run(candidates), winner != current {
            await switchTo(winner)
        }
    }

    /// The Mac reported its addresses in a trusted hello.
    public func update(_ endpoints: Endpoints) {
        endpoint = endpoint.updated(with: endpoints)
    }

    private func switchTo(_ path: Path) async {
        // A race that outlived `stop()` would otherwise bring the path, its recheck and the relay back.
        guard path != current, !stopped else { return }
        let moving = current != nil
        KitLog.log(.transport, "path \(current.map { "\($0) [\(KitLog.route($0.isRelay ? Self.relayHost : $0.description))]" } ?? "none") → \(path) [\(KitLog.route(path.isRelay ? Self.relayHost : path.description))]"
                   + (moving ? ", moving \(sockets.values.filter { $0.socket != nil }.count) sockets" : ""))
        current = path
        generation += 1
        if moving {
            // Make before break: `path` just answered a pinned hello, so sockets elsewhere reconnect straight onto it.
            for entry in sockets.values { entry.socket?.moved(to: generation) }
            sockets = sockets.filter { $0.value.socket != nil }
        }
        streak = [:]
        rechecking?.cancel()
        if path.isRelay { rechecking = Task { await self.recheckWhileRelayed() } } else { Task { await self.warmRelay() } }
        for listener in listeners.values { listener(path) }
    }

    /// The Mac's addresses, then the relay. A Mac paired with no address but the relay has none.
    private var candidates: [Path] {
        let relayResting = relayQuietUntil.map { $0 > .now } ?? false
        let addresses = relayOnly ? [] : endpoint.addresses
        return addresses.filter { $0.host != Self.relayHost && !($0.host ?? "").isEmpty }.map(Path.direct)
            + (bridge == nil || relayResting ? [] : [.relay])
    }

    private enum Outcome: @unchecked Sendable { case answered(Path, Error?), patience }

    /// A relay that didn't answer rests, longer each time, so a relay that isn't there costs no connect per race.
    private func relayAnswered(_ answered: Bool) {
        if answered {
            relayMisses = 0
            relayQuietUntil = nil
        } else {
            relayMisses += 1
            let wait = min(timing.relayQuietCap, 30 * pow(2, Double(relayMisses - 1)))
            relayQuietUntil = .now.addingTimeInterval(wait)
            KitLog.log(.transport, "relay didn't answer; skipping it for \(Int(wait)) s")
        }
    }

    /// Every candidate at once. The first direct address to answer wins at once, the others' probes cancelled; the relay
    /// waits `preferDirect` for a direct answer before it wins.
    private func run(_ candidates: [Path]) async -> Path? {
        let start = ContinuousClock.now
        let (winner, failures) = await race(candidates)
        self.failures = failures
        KitLog.log(.transport, "race \(candidates.map(\.description).joined(separator: ", ")): "
                   + (winner.map { "\($0) in \(KitLog.ms(since: start)) ms" } ?? "nothing answered after \(KitLog.ms(since: start)) ms"))
        return winner
    }

    private func race(_ candidates: [Path]) async -> (Path?, [Path: Error]) {
        let relay = candidates.contains(.relay) ? await relayTransportReady() : nil
        let timing = timing
        return await withTaskGroup(of: Outcome.self) { group -> (Path?, [Path: Error]) in
            for candidate in candidates {
                group.addTask {
                    if case .direct(let url) = candidate {
                        let (reached, error) = await Self.reach(url, direct: self.direct, timing: timing)
                        return .answered(.direct(reached), error)
                    }
                    var error = await Self.probe(candidate, direct: self.direct, relay: relay, timing: timing)
                    // The first try may have gone down a socket the network change killed; the bridge has dropped it since.
                    // Read when it fails, not when the race began: the request that died on the old network can start a race
                    // before the network monitor reports the change.
                    if let failed = error, await self.settling, Self.relayRests(after: failed, settling: false) {
                        KitLog.log(.transport, "relay didn't answer just after a network change, asking again")
                        error = await Self.probe(candidate, direct: self.direct, relay: relay, timing: timing)
                    }
                    return .answered(candidate, error)
                }
            }
            var relayAnswered = false
            var failures: [Path: Error] = [:]
            for await outcome in group {
                switch outcome {
                case .answered(.direct(let url), nil):
                    // The losers' connections are cancelled with their tasks, so this returns now.
                    group.cancelAll()
                    return (.direct(url), [:])
                case .answered(.relay, nil):
                    relayAnswered = true
                    self.relayAnswered(true)
                    group.addTask {
                        try? await Task.sleep(for: .seconds(timing.preferDirect))
                        return .patience
                    }
                case .patience:
                    group.cancelAll()
                    return (.relay, [:])
                case .answered(let path, let error?):
                    failures[path] = error
                    if path.isRelay, Self.relayRests(after: error, settling: settling) { self.relayAnswered(false) }
                }
            }
            return (relayAnswered ? .relay : nil, failures)
        }
    }

    /// Within `Timing.settle` of a network change.
    private var settling: Bool { networkChangedAt.map { Date.now.timeIntervalSince($0) < timing.settle } ?? false }

    /// Whether a relay probe's failure sends the relay to sit out races. Not when the probe was cancelled because a direct
    /// address won, which says nothing about the relay, and not while the network is settling, when the phone may have had
    /// no network at all for a moment.
    static func relayRests(after error: Error, settling: Bool) -> Bool {
        guard !settling, !(error is CancellationError) else { return false }
        return (error as? URLError)?.code != .cancelled
    }

    /// `url`, or when it refuses the connection, the Mac's other ports on that host: a Mac whose port was taken moved up,
    /// and its pinned key is what says it is the Mac. The address that answered, or `url` and why it didn't.
    static func reach(_ url: URL, direct: NWTransport, timing: Timing) async -> (URL, Error?) {
        guard let error = await probe(.direct(url), direct: direct, relay: nil, timing: timing) else { return (url, nil) }
        guard refused(error), let port = url.port else { return (url, error) }
        let siblings = timing.siblingPorts(port).compactMap { sibling -> URL? in
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.port = sibling
            return components.url
        }
        return await withTaskGroup(of: (URL, Error?).self) { group -> (URL, Error?) in
            for sibling in siblings {
                group.addTask { (sibling, await probe(.direct(sibling), direct: direct, relay: nil, timing: timing)) }
            }
            var newKey: Error?
            for await (sibling, failure) in group {
                guard let failure else {
                    group.cancelAll()
                    return (sibling, nil)
                }
                if failure is ServerKeyChanged { newKey = failure }
            }
            return (url, newKey ?? error)
        }
    }

    /// Nothing listens there: the host answered and turned the connection down.
    static func refused(_ error: Error) -> Bool {
        guard let error = error as? URLError, error.code == .cannotConnectToHost else { return false }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ECONNREFUSED)
    }

    /// Any HTTP answer to `GET /v1/hello` over the pinned key, on a new connection, means the Mac is there on that path.
    /// Nil when the Mac answered; otherwise why it didn't.
    static func probe(_ path: Path, direct: NWTransport, relay: NWTransport?, timing: Timing) async -> Error? {
        let transport: NWTransport
        let base: URL
        switch path {
        case .direct(let url): transport = direct; base = url
        case .relay:
            guard let relay else { return URLError(.cannotConnectToHost) }
            transport = relay; base = relayBase
        }
        var request = URLRequest(url: base.appendingPathComponent("v1/hello"))
        request.timeoutInterval = path.isRelay ? timing.relayTimeout : timing.directTimeout
        request.setValue(String(ProtocolVersion.current), forHTTPHeaderField: "X-SideA-Protocol")
        do {
            _ = try await transport.send(request, fresh: true)
            return nil
        } catch {
            return error
        }
    }

    private func recheckWhileRelayed() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(timing.recheck))
            guard !Task.isCancelled, current == .relay else { return }
            for case .direct(let url) in candidates {
                let (reached, error) = await Self.reach(url, direct: direct, timing: timing)
                if error == nil {
                    streak[url, default: 0] += 1
                    if streak[url]! >= timing.promoteAfter { return await switchTo(.direct(reached)) }
                } else {
                    streak[url] = 0
                }
            }
        }
    }

    // MARK: Network

    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let summary = "\(path.status) " + path.availableInterfaces.map { "\($0.type)\($0.name)" }.joined(separator: ",")
            Task { await self?.networkUpdate(summary) }
        }
        monitor.start(queue: DispatchQueue(label: "com.arnenoori.sidea.paths"))
        self.monitor = monitor
    }

    private func networkUpdate(_ summary: String) async {
        defer { lastNetwork = summary }
        guard let lastNetwork, lastNetwork != summary else { return }
        KitLog.log(.transport, "network \(lastNetwork) → \(summary), racing again")
        networkChangedAt = .now
        // Kept connections may be on an interface that's gone, and so may the relay socket: it has to answer a ping.
        direct.reset()
        relayTransport?.reset()
        bridge?.check()
        // A moment for addresses to settle, as Wi-Fi hands over to cellular.
        try? await Task.sleep(for: .milliseconds(300))
        await networkChanged()
    }

    // MARK: Sessions

    nonisolated func transport(_ path: Path) async -> NWTransport? {
        path.isRelay ? await relayTransportReady() : direct
    }

    /// The relay path: the same pinned TLS, dialled to the bridge's loopback port, which hands each connection to the
    /// tunnel as a stream.
    private func relayTransportReady() async -> NWTransport? {
        if let relayTransport { return relayTransport }
        guard let bridge, let port = try? await bridge.port(), let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        if let relayTransport { return relayTransport }
        let transport = NWTransport(trust: trust, poolSize: 2) { _ in .hostPort(host: .ipv4(.loopback), port: nwPort) }
        relayTransport = transport
        return transport
    }

    /// Keeps the relay socket open while on a direct path, so falling back costs no relay handshake.
    public func warmRelay() async {
        guard !stopped else { return }
        _ = await bridge?.warm()
    }

    public var relayState: RelayBridge.State? { bridge?.current }

    public enum RelayCheck: Sendable, Equatable {
        case notSetUp, answered, macOffline, refused
        case failed(String)
    }

    /// Test Connection: whether the Mac answers a pinned hello through the relay now, whichever path is in use, so a
    /// relay that's broken shows while a direct path still hides it. The path in use doesn't change.
    public func checkRelay() async -> RelayCheck {
        guard let bridge, !stopped else { return .notSetUp }
        guard await bridge.warm() else {
            return switch bridge.current {
            case .refused: .refused
            case .open(mac: false): .macOffline
            case .failed(let why): .failed(why)
            default: .failed("The relay didn't answer.")
            }
        }
        guard let error = await Self.probe(.relay, direct: direct, relay: await relayTransportReady(), timing: timing) else {
            relayAnswered(true)
            return .answered
        }
        return error is ServerKeyChanged ? .failed("The Mac answered on the relay with a new security key.") : .failed(error.localizedDescription)
    }

    /// Why the last race found no path, most telling first. A new key counts only when the relay saw it, or every
    /// direct address did: one stale LAN address now on another device isn't the Mac re-keying.
    var unreachable: Error {
        if stopped { return URLError(.cancelled) }
        let changed = failures.compactMapValues { $0 as? ServerKeyChanged }
        let direct = failures.keys.filter { !$0.isRelay }
        if let viaRelay = changed[.relay] { return viaRelay }
        if !direct.isEmpty, direct.allSatisfy({ changed[$0] != nil }), let any = changed.values.first { return any }
        if let denied = failures.values.first(where: { $0 is LocalNetworkDenied }) { return denied }
        if bridge?.current == .refused { return RelayRefused() }
        return URLError(.cannotConnectToHost)
    }

    /// The path for a new socket, and the generation it's registered under, settled together: a switch while the
    /// transport is fetched sends it round again rather than registering it on a path that's no longer current.
    func route(_ socket: RoutedSocket) async -> (path: Path, transport: NWTransport, generation: Int)? {
        for _ in 0..<3 {
            guard let path = await path(), let transport = await transport(path) else { return nil }
            guard path == current else { continue }
            sockets[ObjectIdentifier(socket)] = Weak(socket: socket)
            return (path, transport, generation)
        }
        return nil
    }

    /// `request`'s URL moved onto `path`, whichever of the Mac's addresses it named.
    nonisolated static func rewrite(_ request: URLRequest, onto path: Path) -> URLRequest {
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return request }
        let base: URL
        switch path {
        case .direct(let url): base = url
        case .relay: base = relayBase
        }
        let socket = components.scheme == "wss" || components.scheme == "ws"
        components.scheme = socket ? (base.scheme == "http" ? "ws" : "wss") : base.scheme
        components.host = base.host
        components.port = base.port
        var moved = request
        moved.url = components.url
        return moved
    }
}

/// A `Transport` over whichever path `Paths` picked. A request that fails for want of a connection is sent once more
/// on the path a fresh race picks, when that's safe: a GET, or anything with an `Idempotency-Key` (every Mac POST and
/// DELETE), which the Mac's idempotency store answers rather than runs twice.
public struct RoutedTransport: Transport {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let path = await paths.path() else { throw await paths.unreachable }
        do {
            return try await send(request, on: path)
        } catch let error as URLError where Self.lost.contains(error.code) && Self.repeatable(request) {
            guard let next = await paths.failed(path) else { throw path.isRelay ? await paths.unreachable : error }
            return try await send(request, on: next)
        }
    }

    private func send(_ request: URLRequest, on path: Path) async throws -> (Data, HTTPURLResponse) {
        guard let transport = await paths.transport(path) else { throw URLError(.cannotConnectToHost) }
        return try await transport.send(Paths.rewrite(request, onto: path))
    }

    public typealias Path = Paths.Path

    public func socket(_ request: URLRequest) -> any SocketConnection {
        RoutedSocket(request: request, paths: paths)
    }

    public func learned(_ endpoints: Endpoints) async { await paths.update(endpoints) }

    /// The connection, not the Mac, failed.
    static let lost: Set<URLError.Code> = [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet,
                                           .secureConnectionFailed, .cannotLoadFromNetwork, .dnsLookupFailed, .internationalRoamingOff]

    static func repeatable(_ request: URLRequest) -> Bool {
        request.httpMethod == "GET" || request.httpMethod == nil || request.value(forHTTPHeaderField: "Idempotency-Key") != nil
    }
}

/// A WebSocket on the path in use when it opened. When `Paths` moves, it ends as `SocketClosed(4008)`, which the
/// sync engine and the terminal treat as "reconnect now", and the reconnect lands on the new path.
final class RoutedSocket: SocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let paths: Paths
    private var opened: Task<(socket: any SocketConnection, path: Paths.Path)?, Never>!
    private var generation = 0
    private var hasMoved = false

    init(request: URLRequest, paths: Paths) {
        self.paths = paths
        opened = Task {
            guard let (path, transport, generation) = await paths.route(self) else { return nil }
            self.lock.withLock { self.generation = generation }
            let socket = transport.socket(Paths.rewrite(request, onto: path))
            return (socket, path)
        }
    }

    func moved(to generation: Int) {
        let moving = lock.withLock {
            guard generation > self.generation, !hasMoved else { return false }
            hasMoved = true
            return true
        }
        if moving { Task { await opened.value?.socket.close(code: 4008, reason: "path changed") } }
    }

    private var movedNow: Bool { lock.withLock { hasMoved } }

    private func open() async throws -> any SocketConnection {
        guard let opened = await opened.value else { throw await paths.unreachable }
        if movedNow { throw SocketClosed(code: 4008, reason: "path changed") }
        return opened.socket
    }

    func send(_ message: SocketMessage) async throws {
        do { try await open().send(message) } catch { throw movedNow ? SocketClosed(code: 4008, reason: "path changed") : error }
    }

    func receive() async throws -> SocketMessage {
        do { return try await open().receive() } catch {
            if movedNow { throw SocketClosed(code: 4008, reason: "path changed") }
            await leavePath(after: error)
            throw error
        }
    }

    func sendPing() async throws {
        do { try await open().sendPing() } catch {
            if movedNow { throw SocketClosed(code: 4008, reason: "path changed") }
            await leavePath(after: error)
            throw error
        }
    }

    /// The path itself went: the next socket races for another rather than trying this one again.
    private func leavePath(after error: Error) async {
        if let lost = error as? URLError, RoutedTransport.lost.contains(lost.code), let path = await opened.value?.path {
            _ = await paths.failed(path)
        }
    }

    func close(code: Int, reason: String?) {
        Task { await opened.value?.socket.close(code: code, reason: reason) }
    }
}
