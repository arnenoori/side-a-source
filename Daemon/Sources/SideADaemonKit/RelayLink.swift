import Crypto
import Foundation
import NIOCore
import NIOPosix
import SideACore
import SideAProtocol

/// Everything the daemon does with the relay, as the Mac does it: the tunnel that lets a phone in from anywhere, the phone's
/// push registration, and the pushes themselves, sealed so the relay can't read them. One install key, kept with the
/// daemon's other secrets, signs all of it; the relay is not changed for this (relay/DEPLOY.md).
final class RelayLink: @unchecked Sendable {
    let url: URL
    let installID: String
    let http: RelayHTTP
    private let key: Curve25519.Signing.PrivateKey
    private let wantsTunnel: Bool
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var tunnel: RelayTunnel?
    private var ticketValue: Data?
    private var unacknowledged: Set<String> = []
    private var retrying: Task<Void, Never>?
    private var attempts = 0
    private var diagnostics: [String: (device: String, at: Date, result: String?)] = [:]
    private var tunnelStatus: RelayTunnel.Status = .off
    /// How long to wait before registering a phone again after the relay refused; tests shorten it.
    var retryAfter: Duration = .seconds(15)

    init(config: RelayConfig, store: any SecretStore) throws {
        url = config.url
        key = try RelayIdentity.loadOrCreate(in: store)
        http = RelayHTTP(base: config.url, key: key, fetch: config.fetch)
        installID = http.installID
        wantsTunnel = config.tunnel
    }

    var ticket: Data? { lock.withLock { ticketValue } }

    var status: String {
        guard wantsTunnel else { return "push only" }
        switch lock.withLock({ tunnelStatus }) {
        case .off: return "off"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .waiting(let why): return "waiting (\(why))"
        }
    }

    // MARK: Lifecycle

    func start(_ daemon: SideADaemon) async {
        if wantsTunnel {
            let register: @Sendable () async throws -> Void = { [http] in try await http.register() }
            if let tunnel = try? RelayTunnel(base: url, key: key, loop: group.next(), register: register, target: { [weak daemon] in
                guard let port = daemon?.port, port > 0 else { return nil }
                return UInt16(truncatingIfNeeded: port)
            }) {
                tunnel.statusChanged = { @Sendable [weak self, weak daemon] (status: RelayTunnel.Status) in
                    self?.lock.withLock { self?.tunnelStatus = status }
                    FileHandle.standardError.write(Data("sidead: relay tunnel \(status)\n".utf8))
                    if status == .connected { self?.retryNow(daemon) }
                }
                lock.withLock { self.tunnel = tunnel }
                tunnel.setDevices(Self.tunnelDevices(await daemon.devices.devices))
                if let ticket { tunnel.setPairing(ticket: ticket) }
                tunnel.start()
            }
        }
        for device in await daemon.devices.devices where device.push != nil { unacknowledged.insert(device.id) }
        await retryUnacknowledged(daemon)
    }

    func stop() async {
        retrying?.cancel()
        let tunnel = lock.withLock { self.tunnel }
        await tunnel?.stop(goodbye: TunnelControl.Goodbye.quit)
        try? await group.shutdownGracefully()
    }

    static func tunnelDevices(_ devices: [PairedDevice]) -> [TunnelControl.Device] {
        devices.map { TunnelControl.Device(id: $0.id, secretHash: $0.secretHash) }
    }

    func devicesChanged(_ devices: [PairedDevice]) {
        lock.withLock { tunnel }?.setDevices(Self.tunnelDevices(devices))
    }

    /// A pairing opened or closed: the relay lets a phone that has this ticket through to the pairing, and no other.
    @discardableResult
    func pairing(open: Bool) -> Data? {
        let value: Data? = open ? Data((0..<16).map { _ in UInt8.random(in: 0...255) }) : nil
        lock.withLock { ticketValue = value }
        lock.withLock { tunnel }?.setPairing(ticket: value)
        return value
    }

    // MARK: Registering phones

    func register(_ device: PairedDevice, _ registration: PushRegistration, daemon: SideADaemon) async {
        if await put(device, registration) { return }
        lock.withLock { unacknowledged.insert(device.id) }
        scheduleRetry(daemon)
    }

    private func put(_ device: PairedDevice, _ registration: PushRegistration) async -> Bool {
        let input = RelayHTTP.Device(apnsToken: registration.apnsToken, bundleID: registration.bundleID, apnsEnvironment: registration.apnsEnvironment.rawValue,
                                     secretHash: device.secretHash, pushToStartToken: registration.pushToStartToken, appVersion: RelayHTTP.version(device.app),
                                     notifyQuiet: registration.prefs.macQuiet)
        do {
            _ = try await http.put(device.id, input)
            lock.withLock { _ = unacknowledged.remove(device.id) }
            return true
        } catch let failure as RelayHTTP.Failure where failure.status == 400 || failure.status == 409 {
            lock.withLock { _ = unacknowledged.remove(device.id) }
            return false
        } catch {
            return false
        }
    }

    private func scheduleRetry(_ daemon: SideADaemon) {
        lock.lock(); defer { lock.unlock() }
        guard retrying == nil, !unacknowledged.isEmpty else { return }
        let wait = retryAfter * min(1 << min(attempts, 4), 10)
        attempts += 1
        retrying = Task { [weak self, weak daemon] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, let daemon else { return }
            self.lock.withLock { self.retrying = nil }
            await self.retryUnacknowledged(daemon)
        }
    }

    private func retryNow(_ daemon: SideADaemon?) {
        guard let daemon else { return }
        Task { await retryUnacknowledged(daemon) }
    }

    private func retryUnacknowledged(_ daemon: SideADaemon) async {
        let ids = lock.withLock { unacknowledged }
        guard !ids.isEmpty else { return lock.withLock { attempts = 0 } }
        for device in await daemon.devices.devices where ids.contains(device.id) {
            guard let registration = device.push else { lock.withLock { _ = unacknowledged.remove(device.id) }; continue }
            _ = await put(device, registration)
        }
        if !lock.withLock({ unacknowledged.isEmpty }) { scheduleRetry(daemon) } else { lock.withLock { attempts = 0 } }
    }

    func forget(_ device: String) {
        lock.withLock { _ = unacknowledged.remove(device) }
        Task { try? await http.delete(device) }
    }

    // MARK: Pushes

    nonisolated static let openFresh: TimeInterval = 40

    /// A phone in front refreshes its presence every 30 s while its socket is up; this allows one refresh and some slack.
    static func skips(_ presence: EventHub.Presence?, now: Date) -> Bool {
        guard let presence, presence.foreground else { return false }
        return now.timeIntervalSince(presence.at) <= openFresh
    }

    /// A session finished a turn: every phone that asked for those, and isn't looking at the app, gets it.
    func finished(_ turn: FinishedSession, daemon: SideADaemon) async {
        let payload = RemotePushPayload.finished(turn, mac: HostInfo.machineID(), now: Date().timeIntervalSince1970)
        let collapse = RelayHTTP.collapse(turn.turnID)
        await send(RemotePushPayload.encoded(payload), category: .finished, collapse: collapse, daemon: daemon, expiresIn: 3600, sound: true,
                   wanted: \.finished)
    }

    private func send(_ plaintext: Data, category: PushCategory, collapse: String, daemon: SideADaemon, expiresIn: Int, sound: Bool,
                      wanted: KeyPath<NotificationPrefs, Bool>) async {
        var sealed: [String: String] = [:]
        for device in await daemon.devices.devices {
            guard let registration = device.push, registration.prefs[keyPath: wanted], let raw = device.pushKey, let keyID = device.pushKeyID else { continue }
            if Self.skips(await daemon.hub.presence(device.id), now: Date()) { continue }
            let pushKey = PushKey(key: SymmetricKey(data: raw), keyID: keyID)
            if let envelope = try? PushEnvelope.seal(plaintext, with: pushKey, category: category, collapseID: collapse, deviceID: device.id) {
                sealed[device.id] = envelope
            }
        }
        let ids = sealed.keys.sorted()
        var at = 0
        while at < ids.count {
            let batch = Array(ids[at..<min(at + RelayHTTP.maxDevices, ids.count)])
            at += RelayHTTP.maxDevices
            let body = RelayHTTP.Send(devices: batch, kind: "alert", category: category.rawValue, collapseId: collapse, priority: 10, expiresIn: expiresIn,
                                      sound: sound, level: "active", sealed: sealed.filter { batch.contains($0.key) })
            _ = try? await http.send(body)
        }
    }

    // MARK: Diagnostics

    /// Settings > Test Notification on the phone: one passive push to that phone, answered by `received` when it arrives.
    func test(_ deviceID: String, daemon: SideADaemon) async -> DiagnosticPush {
        let id = "diag-" + UUID().uuidString.prefix(8).lowercased()
        guard let device = await daemon.devices.device(id: deviceID), device.push != nil, let raw = device.pushKey, let keyID = device.pushKeyID else {
            return DiagnosticPush(id: id, relay: .unreachable)
        }
        let payload = RemotePushPayload.test(mac: HostInfo.machineID(), name: daemon.config.name, now: Date().timeIntervalSince1970)
        guard let sealed = try? PushEnvelope.seal(RemotePushPayload.encoded(payload), with: PushKey(key: SymmetricKey(data: raw), keyID: keyID),
                                                  category: .test, collapseID: id, deviceID: deviceID) else {
            return DiagnosticPush(id: id, relay: .rejected)
        }
        lock.withLock { diagnostics[id] = (deviceID, Date(), nil) }
        let body = RelayHTTP.Send(devices: [deviceID], kind: "alert", category: PushCategory.test.rawValue, collapseId: id, priority: 10, expiresIn: 300,
                                  sound: false, level: "passive", sealed: [deviceID: sealed])
        do {
            let result = try await http.send(body).first?.result ?? "rejected"
            return DiagnosticPush(id: id, relay: DiagnosticPush.Relay(rawValue: result))
        } catch {
            return DiagnosticPush(id: id, relay: .unreachable)
        }
    }

    func received(_ id: String, from device: String) -> Bool {
        lock.withLock {
            guard let entry = diagnostics[id], entry.device == device else { return false }
            diagnostics[id]?.result = "received"
            return true
        }
    }
}
