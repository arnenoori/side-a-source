import AppKit
import CryptoKit
import Foundation
import IOKit
import Network
import Observation
import SideACore
import SystemConfiguration

/// Side A Remote: the switch, paired iPhones and the server they reach.
@MainActor @Observable
final class RemoteController {
    static let enabledKey = "remote"
    static let portKey = "remotePort"
    static let lanKey = "remoteLAN"
    static let anywhereKey = "remoteAnywhere"
    /// The Host the phone sends over the relay: it can't resolve, so no browser can send it (docs/remote/tunnel.md).
    nonisolated static let relayHost = "sidea-relay.invalid"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// Kept by the controller from its device list, so the island can ask without reading the Keychain.
    static var hasDevices = false
    /// Remote is on and has a phone to serve: hooks and Stop waiters stay, and events are recorded.
    static var active: Bool { enabled && hasDevices }
    static var basePort: UInt16 { AppCopies.isRelease ? 47800 : 47900 }

    var on = RemoteController.enabled
    private(set) var tailscale: TailscaleStatus?
    /// Nil until checked, or when `socketfilterfw` couldn't be read.
    private(set) var firewall: FirewallStatus?
    private(set) var listening: [String: RemoteServer.ListenerState] = [:]
    private(set) var port: UInt16
    private(set) var pairing: PairingSession?
    private(set) var keyID: String?
    var error: String?
    /// Whether the security key signs; nothing listens until it has.
    let key = KeyCheck()
    /// Every port in the range was busy.
    private(set) var portsRanOut = false
    @ObservationIgnored private(set) var opened = false
    /// Tests count the probes.
    @ObservationIgnored var probe: @Sendable () async -> TailscaleStatus = { await TailscaleCLI.shared.status() }
    /// Tests stand in for a signature that takes its time.
    var signs: @Sendable (RemoteKeychain.Identity) -> Bool {
        get { key.signs }
        set { key.signs = newValue }
    }
    /// Open WebSockets per device, for "Connected now".
    private(set) var connected: [String: Int] = [:]
    private(set) var tunnelStatus: TunnelClient.Status = .off

    @ObservationIgnored private(set) weak var store: AccountStore?
    /// Runs the bridge for Clean Up, which moves and deletes files; tests point it at a throwaway home.
    @ObservationIgnored var cleanupBridge: (@MainActor @Sendable ([String], TimeInterval) async throws -> Data)?
    @ObservationIgnored private(set) lazy var devices = DeviceStore(keychain: keychain)
    nonisolated let cache = RemoteCache()
    @ObservationIgnored private let keychain: RemoteKeychain
    /// Set only by the test harness: serve exactly these addresses, with no Tailscale, from any process.
    @ObservationIgnored private let fixed: [String]?
    @ObservationIgnored private var identity: RemoteKeychain.Identity?
    @ObservationIgnored var server: RemoteServer?
    @ObservationIgnored var hub: EventHub?
    @ObservationIgnored private(set) var terminals: TerminalHub?
    @ObservationIgnored private(set) var transcripts: TranscriptStream?
    @ObservationIgnored private(set) var events: RemoteEvents?
    @ObservationIgnored private(set) var tunnel: TunnelClient?
    /// The open pairing sheet's relay ticket, in its QR code.
    @ObservationIgnored private(set) var pairTicket: Data?
    @ObservationIgnored let epoch = String(UInt64.random(in: 1...UInt64.max), radix: 16)
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var busySince: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored lazy var idempotencyURL = (store?.root ?? URL(fileURLWithPath: NSTemporaryDirectory()))
        .appendingPathComponent("remote/idempotency.sqlite")
    @ObservationIgnored lazy var approvals = ApprovalsLog(url: (store?.root ?? URL(fileURLWithPath: NSTemporaryDirectory()))
        .appendingPathComponent("remote/approvals.json"))
    /// Sparkle's background check, set by the app: whether it could start one now. Nil (the demo, tests) never checks.
    @ObservationIgnored var checkForUpdates: (@MainActor () -> Bool)?

    /// `port`, tests only: one the kernel handed out, so a test never binds the range a real copy uses.
    init(store: AccountStore, keychain: RemoteKeychain, addresses: [String]? = nil, port fixedPort: UInt16? = nil) {
        self.store = store; self.keychain = keychain; fixed = addresses
        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        // The harness may use any port, so lanes testing side by side keep out of each other's way.
        let range = addresses != nil ? 1_024...65_535 : Int(Self.basePort)...Int(Self.basePort) + 9
        port = fixedPort ?? (range.contains(saved) ? UInt16(saved) : Self.basePort)
    }

    /// Demo mode and `swift run` never serve: the demo's data is fictional, and outside an app there is no Keychain identity.
    var available: Bool { fixed != nil || (Bundle.main.bundleURL.pathExtension == "app" && store?.isDemo == false) }

    var mac: MacInfo {
        MacInfo(id: Self.macID, name: Self.harness("SIDEA_HARNESS_NAME") ?? Self.macName(Host.current().localizedName ?? "Mac", release: AppCopies.isRelease))
    }

    /// Side A Dev says so, since a phone can pair with both copies on one Mac.
    nonisolated static func macName(_ name: String, release: Bool) -> String { release ? name : name + " Dev" }

    /// Debug builds only: two harnesses on one Mac pass these to look like two Macs (SIDEA_HARNESS_MAC_ID, _NAME).
    static func harness(_ name: String) -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
        #else
        return nil
        #endif
    }

    /// The tailnet address first; a Mac without Tailscale is reached on its LAN alone.
    var endpoints: Endpoints? {
        if let fixed, let address = fixed.first {
            let lans = fixed.dropFirst().map { Self.hostPort($0, port) }
            return Endpoints(tailnet: Self.hostPort(address, port), lan: lans.first, lans: lans.isEmpty ? nil : lans)
        }
        let lans = boundLAN.map { Self.hostPort($0, port) }
        if let address = boundTailnet.first {
            return Endpoints(tailnet: Self.hostPort(address, port), name: tailscale?.dnsName.map { "\($0):\(port)" },
                             lan: lans.first, lans: lans.isEmpty ? nil : lans)
        }
        guard let primary = lans.first else { return nil }
        return Endpoints(tailnet: primary, lan: primary, lans: lans)
    }

    /// Off unless turned on: Tailscale and the relay tunnel reach the Mac from anywhere, so nothing needs a port open to the Wi-Fi.
    var lanOn: Bool { UserDefaults.standard.object(forKey: Self.lanKey) as? Bool ?? false }

    /// Reach this Mac from anywhere: on unless turned off, whenever there's a relay to reach it through.
    var anywhereOn: Bool { UserDefaults.standard.object(forKey: Self.anywhereKey) as? Bool ?? true }

    // MARK: Lifecycle

    func start() {
        guard available else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.macWillSleep() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.opened == true { self?.devices.flush() } }
        })
        if on {
            open()
            bringUp()
        }
        refresh()
    }

    /// The log file, the paired devices (a Keychain read) and the network probes wait until Remote is on, so a Mac
    /// that never turns it on pays for none of them.
    private func open() {
        guard !opened else { return }
        opened = true
        if fixed == nil, store?.isDemo == false { RemoteLog.shared.open() }
        let info = Bundle.main.infoDictionary
        RemoteLog.shared("Side A \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")) "
                         + "\(Bundle.main.bundleIdentifier ?? "") at \(Bundle.main.bundlePath); port \(port), \(devices.devices.count) paired")
        Self.hasDevices = !devices.devices.isEmpty
        if devices.unreadable != nil { error = devices.unreadable }
    }

    func setEnabled(_ value: Bool) {
        if value { open() }
        RemoteLog.shared("Remote turned \(value ? "on" : "off")")
        on = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        // Remote serves hosted sessions, so Side A's tmux runs while it's on, or while terminal hosting is.
        Task { await store?.syncHosting() }
        if value {
            bringUp()
            refresh()
        } else {
            tearDown()
            // The notch keeps its hooks when it is on.
            if !Island.on { Task { await store?.setIsland(nil, "off") } }
        }
        store?.startNotifications()
    }

    func setLAN(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.lanKey)
        rebind()
    }

    func setAnywhere(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.anywhereKey)
        if value { startTunnel() } else { stopTunnel() }
        rebind()
    }

    /// Before a Sparkle relaunch: phones reconnect quietly to the new copy.
    func handOff() { server?.goodbye("update") }

    /// Before the Mac sleeps: phones say so instead of guessing, and reconnect when it wakes.
    func macWillSleep() { server?.goodbye(ServerEvent.byeSleep) }

    private func bringUp() {
        guard available else { return }
        do {
            guard let identity = try keychain.identity() else { return }
            self.identity = identity
            keyID = SPKI.keyID(identity.spkiHash.base64URL)
        } catch {
            key.unreadable()
            return
        }
        guard key.state == .signed else {
            if let identity { key.check(identity) { [weak self] in if self?.on == true { self?.bringUp() } } }
            return
        }
        if server == nil, let identity {
            let server = RemoteServer(identity: identity, epoch: epoch, idempotency: IdempotencyStore(url: idempotencyURL),
                                      handler: RemoteRoutes.handler(self))
            server.proxy = { request, port, target, cookie in await PreviewProxy.forward(request, port: port, target: target, cookie: cookie) }
            server.stateChanged = { [weak self] states in
                Task { @MainActor in self?.listenersChanged(states) }
            }
            server.authenticated = { [weak self] id in
                Task { @MainActor in self?.devices.seen(id) }
            }
            server.connectionClosed = { [weak self] id in
                Task { @MainActor in self?.pairing?.dropped(connection: id) }
            }
            server.devicesUnavailable = { [weak self] in
                Task { @MainActor in self?.reloadDevices() }
            }
            let hub = EventHub(queue: server.queue, epoch: epoch, snapshot: { [weak self] in
                self?.events?.snapshot() ?? { seq, epoch in StateSnapshot(seq: seq, epoch: epoch) }
            }, hello: { [weak self] in
                self?.hello(paired: true) ?? Hello(app: "", build: 0, mac: MacInfo(id: "", name: ""), capabilities: [], epoch: "", serverTime: 0,
                                                   remoteOn: false, endpoints: Endpoints(tailnet: ""), keyID: "")
            })
            hub.greeted = { [weak self] device, capabilities in
                Task { @MainActor in self?.noteCapabilities(device, capabilities) }
            }
            hub.socketsChanged = { [weak self] counts in
                Task { @MainActor in self?.socketsChanged(counts) }
            }
            let terminals = TerminalHub(queue: server.queue, epoch: epoch) { [weak self] in self?.store?.hosted }
            store?.hosted.onRefresh = { [weak self, weak terminals] in
                self?.events?.hostedChanged()
                guard let terminals else { return }
                terminals.queue.async { terminals.evaluateAll() }
            }
            store?.hosted.onEnded = { [weak terminals] name, status, reason in terminals?.ended(name, status: status, reason: reason) }
            store?.hosted.onAttention = { [weak self] name, attention in self?.events?.hostedAttention(name, attention) }
            server.opened = { [weak hub, weak terminals] peer in
                switch peer.path {
                case ["v1", "ws", "events"]: hub?.attach(peer)
                case let path where path.count == 4 && path.starts(with: ["v1", "ws", "term"]): terminals?.attach(peer, name: path[3])
                default: peer.close(4404, "no such socket")
                }
            }
            server.farewell = { [weak hub] peer, reason in hub?.farewell(peer, reason: reason) }
            if let store {
                events = RemoteEvents(store: store, hub: hub, queue: server.queue)
                transcripts = TranscriptStream(store: store, hub: hub)
            }
            self.hub = hub
            self.terminals = terminals
            server.macID = Self.macID
            self.server = server
            sweeper = Task { [weak self] in
                while !Task.isCancelled {
                    self?.sweepOrphans()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
        recordIfActive()
        server?.setDevices(devices.hashes, keys: devices.confirmKeys)
        if monitor == nil, fixed == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            monitor.start(queue: DispatchQueue(label: "com.arnenoori.sidea.remote.path"))
            self.monitor = monitor
        }
        startTunnel()
        rebind()
    }

    // MARK: Tunnel

    private func startTunnel() {
        guard on, anywhereOn, tunnel == nil, let server, let base = relayURL, let key = installKey else { return }
        let tunnel = TunnelClient(base: base, key: key, register: { try await RelayClient(base: base, key: key).register() }) { [weak server] done in
            guard let server else { return done(nil) }
            server.tunnelPort(done)
        }
        tunnel.statusChanged = { [weak self] status in
            Task { @MainActor in self?.tunnelStatus = status }
        }
        server.setTunnel(true)
        if devices.unreadable == nil { tunnel.setDevices(tunnelDevices) }
        if let pairTicket { tunnel.setPairing(ticket: pairTicket) }
        tunnel.start()
        self.tunnel = tunnel
    }

    private func stopTunnel() {
        tunnel?.stop()
        tunnel = nil
        server?.setTunnel(false)
        tunnelStatus = .off
    }

    private var tunnelDevices: [TunnelControl.Device] {
        devices.devices.map { TunnelControl.Device(id: $0.id, secretHash: $0.secretHash) }
    }

    static func portBusy(_ port: UInt16) -> String { "Port \(port) is in use by another app." }

    /// Every minute while Remote serves: a pairing whose phone never used its token is revoked (see DeviceStore.orphans).
    @ObservationIgnored private var sweeper: Task<Void, Never>?

    func sweepOrphans(now: Date = Date()) {
        for device in devices.orphans(now: now) {
            RemoteLog.shared("pairing: \(device.name) (device \(device.id.prefix(6))) never connected within \(Int(DeviceStore.claimTime / 60)) minutes; removed")
            revoke(device.id)
        }
    }

    func tearDown() {
        sweeper?.cancel(); sweeper = nil
        stopTunnel()
        codex.stop()
        events?.stop()
        events = nil
        push.stopScheduling()
        previews.revokeAll()
        hub = nil
        transcripts?.stop()
        transcripts = nil
        terminals = nil
        server?.stop()
        server = nil
        monitor?.cancel(); monitor = nil
        listening = [:]
        connected = [:]
        portsRanOut = false
        endPairing()
    }

    /// Tailscale's state and the addresses to bind, re-read on launch, wake, network changes and while the tab is open.
    /// Off, nothing is probed: finding the CLI can take a login shell.
    func refresh() {
        guard on else { return }
        reloadDevices()
        tunnel?.networkChanged()
        guard fixed == nil else { return rebind() }
        Task {
            let status = await probe()
            tailscale = status
            rebind()
            // Loopback is exempt, so a blocked Mac answers itself and drops only the phone; this is the one place it shows.
            if on {
                let checked = await Firewall.status()
                if checked != firewall { RemoteLog.shared("firewall: \(checked.map { "\($0)" } ?? "couldn't be read")") }
                firewall = checked
            }
        }
    }

    private var interfaces: RemoteAddresses { RemoteAddresses.current(primary: Self.primaryInterface()) }

    /// The interface the default route uses, whose LAN address goes first: the Wi-Fi the phone is likely on.
    private static func primaryInterface() -> String? {
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return global?["PrimaryInterface"] as? String
    }

    /// The tailnet addresses Tailscale reports, cross-checked against the utun interfaces actually holding them.
    var boundTailnet: [String] {
        guard let status = tailscale, status.state == .ready else { return [] }
        let held = interfaces.tailnet
        return held.isEmpty ? status.addresses : status.addresses.filter(held.contains)
    }

    var boundLAN: [String] { lanOn ? interfaces.lan : [] }

    private func rebind() {
        guard on, let server else { return }
        let addresses = fixed ?? boundTailnet + boundLAN
        var names = Set<String>()
        if let name = tailscale?.dnsName { names.insert(name) }
        if lanOn, let local = Host.current().name, local.hasSuffix(".local") { names.insert(local) }
        if tunnel != nil { names.insert(Self.relayHost) }
        server.serve(addresses: addresses, port: port, names: names)
    }

    private func listenersChanged(_ states: [String: RemoteServer.ListenerState]) {
        listening = states
        // The previous copy may still be exiting; after ten seconds busy, move up a port (at most nine).
        if states.values.contains(.failed(RemoteServer.portInUse)) {
            if busySince == nil {
                busySince = Date()
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    guard busySince != nil, listening.values.contains(.failed(RemoteServer.portInUse)) else { return }
                    busySince = nil
                    guard let next = Self.nextPort(after: port, base: Self.basePort) else { portsRanOut = true; return }
                    port = next
                    UserDefaults.standard.set(Int(next), forKey: Self.portKey)
                    server?.serve(addresses: [], port: next)
                    rebind()
                }
            }
        } else {
            busySince = nil
        }
    }

    /// The port to try when this one stays busy: one up, at most nine above the base. A harness's port may sit anywhere,
    /// up to the top of the range.
    nonisolated static func nextPort(after port: UInt16, base: UInt16) -> UInt16? {
        port < base + 9 ? port + 1 : nil
    }

    /// Recording, and the live loop behind it, run exactly while Remote is active.
    private func recordIfActive() {
        if Self.active { events?.start(); codex.start(); Task { await inbox.refresh() } } else { events?.stop(); codex.stop(); push.stopScheduling() }
    }

    func socketsChanged(_ counts: [String: Int]) {
        connected = counts
        for id in counts.keys { devices.seen(id) }
    }

    // MARK: Relay

    @ObservationIgnored private(set) lazy var push = RemotePush(controller: self)
    @ObservationIgnored private(set) lazy var previews = RemotePreviews(controller: self)
    /// Codex sessions started in a terminal, reached through Codex's app server.
    @ObservationIgnored private(set) lazy var codex = CodexTerminals(store: store)
    /// Claude sessions started in a terminal, reached through their inbox hook (opt-in).
    @ObservationIgnored private(set) lazy var inbox = ClaudeInbox(store: store)

    /// SIDEA_RELAY_URL for a local relay; release builds use production, every other build staging. The demo (and the
    /// harness) only ever uses SIDEA_RELAY_URL, so it never reaches a real relay unasked.
    @ObservationIgnored lazy var relayURL: URL? = ProcessInfo.processInfo.environment["SIDEA_RELAY_URL"].flatMap(URL.init(string:))
        ?? (store?.isDemo != false ? nil
            : URL(string: Bundle.main.bundleIdentifier == AppCopies.releaseID ? "https://push.getsidea.com" : "https://push-staging.getsidea.com"))

    /// Made with the first pairing; the relay learns of it on the first registration.
    var installKey: Curve25519.Signing.PrivateKey? {
        do { return try keychain.installKey() } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    var installID: String? { installKey.map { RelaySignature.installID($0.publicKey.rawRepresentation) } }

    // MARK: Pairing

    /// Whether Pair iPhone can open now, and if not, what stands in the way.
    enum PairReadiness: Equatable {
        case ready, starting, keyWaiting, keyBroken, noNetwork, devicesUnreadable
        case cantListen(String)
    }

    /// Ready exactly when a phone could reach the sheet: a listener is up or the relay tunnel is.
    var pairReadiness: PairReadiness {
        if devices.unreadable != nil { return .devicesUnreadable }
        if listening.values.contains(.ready) || tunnel != nil { return .ready }
        switch key.state {
        case .waiting: return .keyWaiting
        case .refused, .unreadable: return .keyBroken
        case .unchecked, .checking, .signed: break
        }
        if portsRanOut { return .cantListen(Self.portBusy(port)) }
        if let failure = listening.values.compactMap({ if case .failed(let why) = $0 { why } else { nil } }).first, failure != RemoteServer.portInUse {
            return .cantListen("Side A couldn't listen: \(failure)")
        }
        if endpoints == nil, !(anywhereOn && relayURL != nil) { return .noNetwork }
        return .starting
    }

    func beginPairing() {
        guard on else { return }
        pairing?.end()
        pairing = PairingSession(installID: installID)
        pairTicket = Data(Secret.bytes(16))
        tunnel?.setPairing(ticket: pairTicket)
        refresh()
    }

    func endPairing() {
        pairing?.end()
        pairing = nil
        pairTicket = nil
        tunnel?.setPairing(ticket: nil)
    }

    /// With the tunnel up, the code also names the relay, so a phone on another network can pair; with no direct address
    /// at all, the relay is the only way.
    var qrLink: String? {
        guard let pairing, let identity else { return nil }
        var relay: (url: URL, installID: String, ticket: Data)?
        if tunnel != nil, let installID, let relayURL, let pairTicket { relay = (relayURL, installID, pairTicket) }
        guard endpoints != nil || relay != nil else { return nil }
        return PairingSession.link(address: endpoints?.tailnet, lan: endpoints?.lans ?? [], spki: identity.spkiHash, mac: mac,
                                   tailnetName: tailscale?.tailnet, code: pairing.code.code, relay: relay)
    }

    var spki: Data? { identity?.spkiHash }

    /// For Copy Diagnostics: a release build's key should say teamid:…, never cdhash:….
    var keyAccess: String { keychain.keyAccess() }

    /// On Pair: a token shown once, its hash kept with the device, the phone's old record dropped.
    /// A key the phone registers is kept only if it is one: base64url X9.63 P-256, 65 bytes.
    static func p256(_ key: String?) -> String? {
        guard let key, let raw = Secret.base64url(key), raw.count == 65, (try? P256.Signing.PublicKey(x963Representation: raw)) != nil else { return nil }
        return key
    }

    func completePairing(_ attemptID: String) -> PairResponse? {
        guard let (attempt, key) = pairing?.takeApproved(attemptID) else { return nil }
        let request = attempt.request
        let token = DeviceToken.make()
        let device = RemoteDevice(id: request.deviceID, name: String(request.device.name.prefix(100)), model: String(request.device.model.prefix(40)),
                                  system: String(request.device.system.prefix(40)), app: String(request.device.app.prefix(20)),
                                  build: request.device.build, hash: DeviceToken.hash(token), secretHash: request.deviceSecretHash,
                                  pushKey: key?.data, pushKeyID: key?.keyID,
                                  confirmKey: Self.p256(request.confirmKey), unlockKey: Self.p256(request.unlockKey),
                                  created: Date().timeIntervalSince1970, lastSeen: nil)
        let replacedSameID = devices.devices.contains { $0.id == device.id }
        do { try devices.add(device, replacing: request.replaces) } catch {
            RemoteLog.shared("pairing: \(device.name) approved, but saving it failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
            pairing?.finished(attemptID, saved: false)
            return nil
        }
        pairing?.finished(attemptID, saved: true)
        RemoteLog.shared("pairing: paired \(device.name) (device \(device.id.prefix(6)))" + (request.replaces.map { ", replacing \($0.prefix(6))" } ?? ""))
        if let old = request.replaces, old != device.id { invalidate(old) }
        // Paired again under the same id: what the old token opened goes with it.
        if replacedSameID { invalidate(device.id, keepPush: true) }
        devicesChanged()
        // A phone that can't be asked anything is no use: Claude Code's hooks come on with the first pairing.
        if store?.island.installed[.claude] != true { Task { await store?.setIsland(.claude, "on") } }
        let relay = key.flatMap { key in installID.flatMap { id in relayURL.map { RelayInfo(url: $0.absoluteString, installID: id, keyID: key.keyID.base64URL) } } }
        return PairResponse(token: token, deviceID: device.id, mac: mac, relay: relay, hello: hello(paired: true))
    }

    // MARK: Devices

    func revoke(_ id: String) {
        do { try devices.remove(id) } catch { self.error = error.localizedDescription; return }
        invalidate(id)
        devicesChanged()
    }

    /// Everything a device's token opened: its sockets, idempotency records, previews and, unless it was only paired
    /// again under the same id with its new push key already saved, its push key. The one place for this, so a
    /// removal, a replacement and a reset can't each forget something. Tunnel streams are covered twice: what runs in
    /// them is ordinary server connections, closed here, and devicesChanged sends the relay the new list, on which it
    /// closes the phone's socket.
    private func invalidate(_ id: String, keepPush: Bool = false) {
        if !keepPush { server?.revoke(id); push.forget(id) }
        previews.revoke(device: id)
        store?.island.dropQueued(device: id)
    }

    /// A device list that couldn't be read gets another try, at most every few seconds, each time a phone asks and on
    /// wake and network changes. Nothing was lost meanwhile, so everyone carries on where they were.
    func reloadDevices(now: Date = Date()) {
        guard opened, let was = devices.unreadable, now.timeIntervalSince(lastDeviceReload) >= Self.deviceReloadEvery else { return }
        lastDeviceReload = now
        devices.load()
        guard devices.unreadable == nil else { return }
        RemoteLog.shared("paired devices readable again: \(devices.devices.count)")
        if error == was { error = nil }
        devicesChanged()
    }

    nonisolated static let deviceReloadEvery: TimeInterval = 5
    @ObservationIgnored private var lastDeviceReload = Date.distantPast

    /// After "Paired devices couldn't be read": start over with no devices.
    func resetDevices() {
        let gone = devices.devices.map(\.id)
        do { try devices.reset() } catch { self.error = error.localizedDescription; return }
        for id in gone { invalidate(id) }
        error = nil
        devicesChanged()
    }

    /// A new identity: every phone's pin stops matching, so every device goes.
    func makeNewKey() {
        tearDown()
        keychain.deleteIdentity()
        identity = nil
        key.reset()
        for device in devices.devices {
            try? devices.remove(device.id)
            invalidate(device.id)
        }
        devicesChanged()
        if on { bringUp(); refresh() }
    }

    private func devicesChanged() {
        let had = Self.hasDevices
        Self.hasDevices = !devices.devices.isEmpty
        server?.setDevices(devices.hashes, keys: devices.confirmKeys)
        tunnel?.setDevices(tunnelDevices)
        if had && !Self.hasDevices, !Island.on { Task { await store?.setIsland(nil, "off") } }
        recordIfActive()
        store?.startNotifications()
    }

    /// Remove Side A: the device item, the identity and the idempotency records go.
    func uninstall() async {
        tearDown()
        if (try? keychain.installKey(create: false)) != nil { await push.deleteInstall() }
        keychain.deleteInstallKey()
        keychain.deleteDevices()
        keychain.deleteIdentity()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: idempotencyURL.path + suffix) }
        approvals.forget()
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
    }

    #if DEBUG
    /// Tests: what checks a signature when no server listens.
    var confirmCheck: (@Sendable (HTTPRequest, String, ConfirmPurpose, String, ConfirmProof) -> HTTPResponse?)?
    #endif

    // MARK: Hello

    static let capabilities: Set<Capability> = [.confirmSigned, .confirmActions, .events, .answersQuestions, .answersPlans, .answersMode, .replyFollowUp, .replyNote, .interrupt, .images, .diffs,
                                                .uploads, .setup, .options, .push, .transcriptStream, .ports, .interruptNextStep,
                                                .quit, .mac, .history, .search, .cleanup, .incidents, .autopilot, .autopilotToggle, .autopilotAnswers,
                                                .accountsUse, .worth, .rotation, .repliesDropped]

    /// Remembers what a phone's `hello` said it can show; the keychain is written only when that changes.
    func noteCapabilities(_ device: String, _ capabilities: Set<Capability>) {
        let rotation = capabilities.contains(.rotation), groups = capabilities.contains(.readyGroups)
        guard let known = devices.devices.first(where: { $0.id == device }),
              known.rotationPushes ?? false != rotation || known.readyGroups ?? false != groups else { return }
        try? devices.update(device) {
            $0.rotationPushes = rotation
            $0.readyGroups = groups
        }
    }

    /// Hosting only while tmux is there to host.
    var capabilities: Set<Capability> {
        // Hosted Claude changes its settings through its own pickers.
        var capabilities = store?.hosted.available == true ? Self.capabilities.union([.hosted, .replySteer, .terminal, .continueOnPhone, .restart, .sessionSettings, .hostedTrust])
            : Self.capabilities
        if checkForUpdates != nil { capabilities.insert(.updateCheck) }
        if codex.offered { capabilities.formUnion([.replyTerminal, .sessionSettings]) }
        if inbox.installed { capabilities.insert(.replyInbox) }
        return capabilities
    }

    /// Without a token (`paired` nil) or with one the Mac doesn't know (false), only what a phone needs before pairing:
    /// versions and the switch. Anyone on the same Wi-Fi can ask, so the Mac's name, id, addresses and key stay out; the
    /// QR code carries those.
    func hello(paired: Bool?) -> Hello {
        let info = Bundle.main.infoDictionary ?? [:]
        let known = paired == true
        return Hello(protocolVersion: ProtocolVersion.current, minProtocol: 1, maxProtocol: ProtocolVersion.current,
                     app: info["CFBundleShortVersionString"] as? String ?? "0", build: Int(info["CFBundleVersion"] as? String ?? "") ?? 0,
                     mac: known ? mac : MacInfo(id: "", name: ""), capabilities: known ? capabilities : [], minClientBuild: RemotePolicy.minClientBuild, epoch: epoch,
                     serverTime: Date().timeIntervalSince1970, paired: paired, remoteOn: on,
                     endpoints: known ? endpoints ?? Endpoints(tailnet: "") : Endpoints(tailnet: ""), keyID: known ? keyID ?? "" : "")
    }

    /// The phone's key for this Mac: a hash of the hardware UUID, so the UUID itself never leaves.
    static let macID: String = {
        if let id = harness("SIDEA_HARNESS_MAC_ID") { return id }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        return macID(hardware: uuid ?? "unknown", bundleID: Bundle.main.bundleIdentifier, release: AppCopies.isRelease)
    }()

    /// Release keeps the id phones already hold. Side A Dev has its own, or the phone's one record per Mac would make each
    /// pairing overwrite the other's.
    nonisolated static func macID(hardware uuid: String, bundleID: String?, release: Bool) -> String {
        let seed = release ? uuid : uuid + "\n" + (bundleID ?? "")
        return IDs.hashed(seed)
    }

    static func hostPort(_ address: String, _ port: UInt16) -> String { address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)" }
}
