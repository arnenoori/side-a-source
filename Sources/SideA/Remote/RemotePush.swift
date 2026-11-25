import CryptoKit
import Foundation
import os
import SideACore
import SideAProtocol

@MainActor
final class RemotePush {
    private(set) var relayState = "unregistered"
    weak var controller: RemoteController?
    private var client: RelayClient?
    private let log = Logger(subsystem: "com.arnenoori.sidea", category: "push")
    private(set) var diagnostics: [String: (device: String, sent: Date, received: Date?)] = [:]

    let delivery = PushDelivery()
    /// Requests whose answer is still wanted: an alert for one stops retrying, and is held back or sent late, only while it is.
    var open: Set<String> = []
    var watched: [String: Watched] = [:]
    var watchTimer: Task<Void, Never>?
    /// Alerts to a request, question or plan that a relaunch would leave on a phone with nothing behind them.
    var outstanding = PushDismissals()
    var outstandingURL: URL?
    var swept = false
    var presenceOf: (String) -> EventHub.Presence? = { _ in nil }

    #if DEBUG
    var sealing: ((PushPayload, PushCategory, String, [String]) -> Void)?
    #endif

    init(controller: RemoteController) {
        self.controller = controller
        outstandingURL = controller.store?.root.appendingPathComponent("remote/pending-pushes.json")
        presenceOf = { [weak controller] device in controller?.hub?.presence(device) }
        delivery.noted = { [weak self] device, result in
            self?.relayState = "ok"
            self?.note(device, result)
        }
        delivery.failed = { [weak self] error in self?.failed(error, device: nil, doing: "send a notification") }
        delivery.relay = { [weak self] in self?.relay }
    }

    var relay: RelayClient? {
        if let client { return client }
        guard let controller, let base = controller.relayURL, let key = controller.readInstallKey() else { return nil }
        client = RelayClient(base: base, key: key)
        return client
    }

    func checkRelay() async -> String {
        guard let relay else { return relayState }
        if let checked, Date().timeIntervalSince(checked) < 60 { return relayState }
        checked = Date()
        do {
            relayState = try await relay.registered() ? "ok" : "unregistered"
        } catch {
            failed(error, device: nil, doing: "check the relay")
        }
        return relayState
    }

    private var checked: Date?
    private(set) var tokenWarned: [String: Date] = [:]
    static let tokenWarnEvery: TimeInterval = 3_600

    static func warns(from previous: String?, to next: String, warned: Date?, now: Date) -> Bool {
        guard let previous, previous != next else { return false }
        return warned.map { now.timeIntervalSince($0) >= tokenWarnEvery } ?? true
    }

    func register(_ device: String, _ registration: PushRegistration) async -> Bool {
        guard let controller, let record = controller.devices.devices.first(where: { $0.id == device }) else { return false }
        do { try controller.devices.update(device) { $0.push = registration } } catch {
            RemoteLog.shared("couldn't save device \(device.prefix(6))'s push registration: \(error.localizedDescription)")
        }
        let now = Date()
        if Self.warns(from: record.push?.apnsToken, to: registration.apnsToken, warned: tokenWarned[device], now: now) {
            tokenWarned[device] = now
            RemoteLog.shared("device \(device) reported a new push token")
            NotificationRouter.deviceMoved(device, name: record.name)
        }
        perform(activities.reported(device, activities: Array(registration.activityTokens.keys), now: Date().timeIntervalSince1970), state: activities.state)
        defer { activity(activities.state) }
        return await put(device, registration, secretHash: record.secretHash, app: record.app)
    }

    private(set) var unacknowledged: Set<String> = [] {
        didSet { if unacknowledged.isEmpty { attempts = 0 } }
    }
    @ObservationIgnored private var retrying: Task<Void, Never>?
    private(set) var attempts = 0
    var retryAfter: Duration = .seconds(15)
    var putDevice: ((String, RelayClient.Device) async throws -> Bool)?

    private func put(_ device: String, _ registration: PushRegistration, secretHash: String, app: String) async -> Bool {
        let input = RelayClient.Device(apnsToken: registration.apnsToken, bundleID: registration.bundleID,
                                       apnsEnvironment: registration.apnsEnvironment.rawValue, secretHash: secretHash,
                                       pushToStartToken: registration.pushToStartToken, appVersion: Self.version(app),
                                       notifyQuiet: registration.prefs.macQuiet)
        let send: (String, RelayClient.Device) async throws -> Bool
        if let putDevice { send = putDevice } else if let relay { send = { try await relay.put($0, $1) } } else { return false }
        do {
            let verified = try await send(device, input)
            relayState = "ok"
            note(device, verified ? "ok" : "unverified")
            unacknowledged.remove(device)
            return true
        } catch {
            if failed(error, device: device, doing: "register a phone") {
                unacknowledged.insert(device)
                scheduleRetry()
            } else {
                unacknowledged.remove(device)
            }
            return false
        }
    }

    private func scheduleRetry() {
        guard retrying == nil, !unacknowledged.isEmpty else { return }
        let wait = retryAfter * min(1 << min(attempts, 4), 10)
        attempts += 1
        retrying = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            retrying = nil
            await retryUnacknowledged()
        }
    }

    private func retryUnacknowledged() async {
        for device in unacknowledged.sorted() {
            guard let record = controller?.devices.devices.first(where: { $0.id == device }), let registration = record.push else {
                unacknowledged.remove(device)
                continue
            }
            _ = await put(device, registration, secretHash: record.secretHash, app: record.app)
        }
    }

    func relayMayBeBack() {
        guard !unacknowledged.isEmpty else { return }
        retrying?.cancel()
        retrying = nil
        attempts = 0
        Task { [weak self] in await self?.retryUnacknowledged() }
    }

    /// Revoke and Remove: the relay forgets the device. Best effort; an unknown device is no error.
    func forget(_ device: String) {
        activities.forget(device)
        unacknowledged.remove(device)
        guard let relay else { return }
        Task { try? await relay.delete(device) }
    }

    func deleteInstall() async {
        do { try await relay?.deleteInstall() } catch {
            RemoteLog.shared("the relay didn't delete this install: \(error.localizedDescription)")
        }
        client = nil
        relayState = "unregistered"
    }

    var presence: () -> UserPresence = UserPresence.now
    var clock: () -> Date = Date.init
    private(set) var scheduler = PushScheduler()
    var held: [String: () -> Void] = [:]
    private var wake: Task<Void, Never>?

    func request(_ request: RemoteRequest) {
        let (category, first) = RemotePushPayload.request(request, mac: RemoteController.macID, now: 0)
        open.insert(request.id)
        held[request.id] = { [weak self] in
            guard let self else { return }
            let (category, payload) = RemotePushPayload.request(request, mac: RemoteController.macID, now: clock().timeIntervalSince1970)
            let wanted: (NotificationPrefs) -> Bool = switch payload.kind {
            case .question: \.questions
            case .plan: \.plans
            default: \.requests
            }
            var spec = PushSpec(payload: payload, category: category, collapse: Self.collapse(request.id), wanted: wanted,
                                level: category == .request || category == .requestDestructive ? "time-sensitive" : "active", timeSensitive: true)
            spec.alive = { [weak self] in self?.open.contains(request.id) == true }
            sendRequest(spec, id: request.id)
        }
        run(scheduler.add(request.id, .ask(destructive: category == .requestDestructive), now: clock(), presence: presence()))
        logHeld(request.id, kind: first.t)
    }

    func finished(_ finished: FinishedSession, ran: TimeInterval?) {
        if (ran ?? .infinity) < PushScheduler.shortTurn { skipped("finished", finished.turnID, "short-turn") }
        run(scheduler.finished(finished, ran: ran, now: clock(), presence: presence()))
    }

    /// The relay's only removal is its "Answered" push, so Ready shrinks in place while turns are left.
    func finishedResolved(_ turnID: String, reason: Island.ReadyReason = .replied) {
        let shown = scheduler.ready.contains { $0.turnID == turnID }
        let silently = reason == .expired || reason == .released
        resolve(turnID)
        clear(Self.collapse(turnID), silently: silently)
        guard shown else { return }
        let left = scheduler.ready
        guard !left.isEmpty else { return clear(Self.readyCollapse, silently: silently) }
        let showing = Set(dismissals.showing(Self.readyCollapse))
        guard !showing.isEmpty else { return }
        var spec = PushSpec(payload: RemotePushPayload.ready(left, mac: RemoteController.macID, now: clock().timeIntervalSince1970, quiet: true, faceID: needsFaceID),
                            category: .finished, collapse: Self.readyCollapse, wanted: \.finished, level: "passive", sound: false)
        spec.only = { showing.contains($0.id) }
        spec.reason = "ready-shrank"
        send(spec)
    }

    private func ready(_ turns: [FinishedSession], quiet: Bool) {
        guard !turns.isEmpty else { return }
        let now = clock().timeIntervalSince1970
        var group = PushSpec(payload: RemotePushPayload.ready(turns, mac: RemoteController.macID, now: now, quiet: quiet, faceID: needsFaceID),
                             category: .finished, collapse: Self.readyCollapse, wanted: \.finished, level: "active", sound: !quiet)
        group.only = Self.groupsReady
        dismissals.sent(Self.readyCollapse, to: send(group).sent)
        var sounded = quiet
        for turn in turns.reversed() where !perTurnSent.contains(turn.turnID) {
            perTurnSent.insert(turn.turnID)
            let payload = RemotePushPayload.finished(turn, mac: RemoteController.macID, now: now, quiet: sounded, faceID: needsFaceID(turn.sessionID))
            var each = PushSpec(payload: payload, category: .finished, collapse: Self.collapse(turn.turnID), wanted: \.finished, level: "active", sound: !sounded)
            each.only = { !Self.groupsReady($0) }
            dismissals.sent(each.collapse, to: send(each).sent)
            sounded = true
        }
        perTurnSent.formIntersection(turns.map(\.turnID))
    }

    private func needsFaceID(_ session: SessionKey) -> Bool {
        guard let store = controller?.store, let mode = SessionCommands(store: store).permissionMode(session) else { return false }
        return ConfirmPolicy.session(mode: mode) == .biometric
    }

    private var perTurnSent: Set<String> = []

    /// Per Mac, so two Macs' Ready notifications on one phone don't replace each other.
    static var readyCollapse: String { opaque("ready-" + RemoteController.macID) }

    nonisolated static func groupsReady(_ device: RemoteDevice) -> Bool { device.readyGroups == true }

    func health(_ session: RemoteSession, _ flag: SessionFlag) {
        guard Self.notifies(flag) else { return healthEnded(session.id) }
        if let last = healthSent[session.id], clock().timeIntervalSince(last) < 3600 {
            return skipped("health", Self.opaque("health-" + session.id), "already-warned-within-an-hour")
        }
        let id = Self.healthID(session.id)
        held[id] = { [weak self] in
            guard let self else { return }
            let now = clock()
            healthSent[session.id] = now
            let payload = RemotePushPayload.health(session, flag: flag, mac: RemoteController.macID, now: now.timeIntervalSince1970)
            send(PushSpec(payload: payload, category: .health, collapse: Self.opaque("health-" + session.id), wanted: \.health, level: "passive"))
        }
        run(scheduler.add(id, .health, now: clock(), presence: presence()))
        logHeld(id, kind: "health", collapse: Self.opaque("health-" + session.id))
    }

    func healthEnded(_ session: SessionKey) { resolve(Self.healthID(session)) }

    private static func healthID(_ session: SessionKey) -> String { "health:" + session }

    func resolve(_ id: String) {
        if held[id] != nil { skipped("held", Self.collapse(id), "settled-before-sent") }
        scheduler.resolve(id)
        held[id] = nil
        open.remove(id)
        watched[id] = nil
        schedule()
    }

    private func run(_ actions: [PushScheduler.Action]) {
        for action in actions {
            switch action {
            case .send(let id): held.removeValue(forKey: id)?()
            case .ready(let turns, let quiet): ready(turns, quiet: quiet)
            }
        }
        schedule()
    }

    private func schedule() {
        wake?.cancel()
        wake = nil
        guard let delay = scheduler.nextCheck(now: clock(), presence: presence()) else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            wake = nil
            tick()
        }
    }

    func tick() { run(scheduler.tick(now: clock(), presence: presence())) }

    func stopScheduling() {
        retrying?.cancel()
        retrying = nil
        attempts = 0
        unacknowledged = []
        wake?.cancel()
        wake = nil
        held = [:]
        scheduler = PushScheduler()
        perTurnSent = []
        endActivities()
        open = []
        watched = [:]
        watchTimer?.cancel()
        watchTimer = nil
    }

    nonisolated static func notifies(_ flag: SessionFlag) -> Bool { flag.kind != .bloated }

    func queuedDropped(session: SessionKey, title: String?, text: String) {
        let payload = RemotePushPayload.queuedDropped(session: session, title: title, text: text, mac: RemoteController.macID, now: Date().timeIntervalSince1970)
        send(PushSpec(payload: payload, category: .health, collapse: Self.opaque("dropped-" + session), wanted: \.health, level: "active"))
    }

    func limit(_ account: RemoteAccount, _ window: UsageWindow, threshold: Int) {
        let key = "\(account.id)|\(window.id)|\(threshold)|\(Int(window.resetsAt ?? 0))"
        guard limitSent.insert(key).inserted else {
            return skipped("limit", Self.opaque("limit-" + account.id + "-" + window.id), "already-sent-for-this-threshold")
        }
        let collapse = Self.opaque("limit-" + account.id + "-" + window.id)
        notice("limit:" + collapse) { [weak self] in
            guard let self else { return }
            let payload = RemotePushPayload.limit(account, window: window, mac: RemoteController.macID, now: clock().timeIntervalSince1970)
            send(PushSpec(payload: payload, category: .limit, collapse: collapse, wanted: \.limits, level: "active"))
        }
    }

    /// Autopilot moved sessions or ran out of accounts. Only phones that said they can show one get it: an older phone's
    /// Service Extension has no words for this kind, and the relay would still wake it. Held while someone is at the Mac;
    /// the latest replaces one still held, as it would the notification.
    func rotation(title: String, body: String?, account: String?, resetsAt: Timestamp?, blocks: Bool) {
        notice("rotation") { [weak self] in
            guard let self else { return }
            let payload = RemotePushPayload.rotation(title: title, body: body, account: account, resetsAt: resetsAt, mac: RemoteController.macID,
                                                     now: clock().timeIntervalSince1970)
            var spec = PushSpec(payload: payload, category: .rotation, collapse: "rotation", wanted: { $0.rotation == true }, level: Self.rotationLevel(blocks: blocks))
            spec.only = Self.showsRotation
            send(spec)
        }
    }

    private func notice(_ id: String, _ send: @escaping () -> Void) {
        held[id] = send
        run(scheduler.add(id, .notice, now: clock(), presence: presence()))
        logHeld(id, kind: id.hasPrefix("limit:") ? "limit" : id, collapse: id.hasPrefix("limit:") ? String(id.dropFirst(6)) : id)
    }

    nonisolated static func rotationLevel(blocks: Bool) -> String { blocks ? "active" : "passive" }

    nonisolated static func showsRotation(_ device: RemoteDevice) -> Bool { device.rotationPushes == true }

    private var healthSent: [SessionKey: Date] = [:]
    private var limitSent: Set<String> = []

    var dismissals = PushDismissals()

    /// One send names at most the relay's limit of devices; more go in further sends rather than fail together.
    nonisolated static func batches(_ devices: [String]) -> [[String]] {
        stride(from: 0, to: devices.count, by: RelayClient.maxDevices).map { Array(devices[$0..<min($0 + RelayClient.maxDevices, devices.count)]) }
    }

    func test(_ device: String) async -> DiagnosticPush {
        let id = "diag-" + UUID().uuidString.prefix(8).lowercased()
        guard let relay, let record = controller?.devices.devices.first(where: { $0.id == device }), record.push != nil,
              let key = Self.key(record) else { return DiagnosticPush(id: id, relay: .unreachable) }
        let payload = RemotePushPayload.test(mac: RemoteController.macID, name: controller?.mac.name ?? "your Mac", now: Date().timeIntervalSince1970)
        guard let sealed = try? PushEnvelope.seal(RemotePushPayload.encoded(payload), with: key, category: .test, collapseID: id, deviceID: device) else {
            return DiagnosticPush(id: id, relay: .rejected)
        }
        diagnostics[id] = (device, Date(), nil)
        let body = RelayClient.Send(devices: [device], kind: "alert", category: PushCategory.test.rawValue, collapseId: id, priority: 10,
                                    expiresIn: 300, sound: false, level: "passive", sealed: [device: sealed])
        do {
            let result = try await relay.send(body).first?.result ?? "rejected"
            relayState = "ok"
            note(device, result)
            return DiagnosticPush(id: id, relay: DiagnosticPush.Relay(rawValue: result))
        } catch {
            failed(error, device: device, doing: "send a test notification")
            return DiagnosticPush(id: id, relay: .unreachable)
        }
    }

    func received(_ id: String, from device: String) -> Bool {
        guard diagnostics[id]?.device == device else { return false }
        diagnostics[id]?.received = Date()
        return true
    }

    private var activities = LiveActivities()
    private var ticker: Task<Void, Never>?

    func activity(_ state: ActivityContentState) {
        let devices = targets { $0.push != nil }.map {
            LiveActivities.Device(id: $0.id, wanted: $0.push?.prefs.liveActivity == true, canStart: $0.push?.pushToStartToken != nil)
        }
        perform(activities.changed(state, devices: devices, now: Date().timeIntervalSince1970), state: state)
        if !activities.active { ticker?.cancel(); ticker = nil } else if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard let self else { return }
                    activity(activities.state)
                }
            }
        }
    }

    private func endActivities() {
        ticker?.cancel()
        ticker = nil
        let devices = (controller?.devices.devices ?? []).map { LiveActivities.Device(id: $0.id, wanted: false, canStart: false) }
        perform(activities.changed(activities.state, devices: devices, now: Date().timeIntervalSince1970), state: activities.state)
        activities = LiveActivities()
    }

    #if DEBUG
    var acting: (([LiveActivities.Action]) -> Void)?
    var ticking: Bool { ticker != nil }
    #endif

    private func perform(_ actions: [LiveActivities.Action], state: ActivityContentState) {
        #if DEBUG
        if !actions.isEmpty { acting?(actions) }
        #endif
        guard let relay else { return }
        for action in actions {
            switch action {
            case .start(let device): activitySend(relay, device, "start", id: nil, state: state, priority: 10)
            case .update(let device, let id, let priority): activitySend(relay, device, "update", id: id, state: state, priority: priority)
            case .end(let device, let id): activitySend(relay, device, "end", id: id, state: state, dismissal: Date().timeIntervalSince1970)
            }
        }
    }

    private func activitySend(_ relay: RelayClient, _ device: String, _ event: String, id: String?, state: ActivityContentState,
                              priority: Int = 5, dismissal: Double? = nil) {
        let body = RelayClient.Activity(devices: [device], event: event, activityId: id, contentState: state,
                                        staleDate: event == "end" ? nil : Date().timeIntervalSince1970 + 3600, dismissalDate: dismissal, priority: priority)
        Task { await deliver(relay, body, doing: "\(event) the Live Activity") }
    }

    private func deliver(_ relay: RelayClient, _ body: some Encodable & Sendable, doing: String) async {
        do {
            for result in try await relay.send(body) { note(result.device, result.result) }
            relayState = "ok"
        } catch {
            failed(error, device: nil, doing: doing)
        }
    }

    func targets(_ include: (RemoteDevice) -> Bool) -> [RemoteDevice] {
        (controller?.devices.devices ?? []).filter { $0.pushKey != nil && include($0) }
    }

    func note(_ device: String, _ result: String) {
        guard let controller, controller.devices.devices.first(where: { $0.id == device })?.pushResult != result else { return }
        do { try controller.devices.update(device) { $0.pushResult = result } } catch {
            RemoteLog.shared("couldn't save device \(device.prefix(6))'s push result: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func failed(_ error: Error, device: String?, doing: String) -> Bool {
        let failure = error as? RelayClient.Failure
        let transient = failure == nil || failure == .unreachable || (failure?.status ?? 0) >= 500
        if transient { relayState = "unreachable" }
        log.error("couldn't \(doing, privacy: .public): \(error.localizedDescription, privacy: .public)")
        if let device, let failure, failure.status == 409 || failure.status == 400 { note(device, "rejected") }
        return transient
    }

    nonisolated static func key(_ device: RemoteDevice) -> PushKey? {
        guard let key = device.pushKey, let id = device.pushKeyID else { return nil }
        return PushKey(key: SymmetricKey(data: key), keyID: id)
    }

    /// The relay's collapse ids are up to 64 characters of [A-Za-z0-9_-].
    /// A collapse id for something the relay shouldn't learn the name of: a session's or an account's id.
    nonisolated static func opaque(_ id: String) -> String { Data(SHA256.hash(data: Data(id.utf8)).prefix(24)).base64URL }

    nonisolated static func collapse(_ id: String) -> String {
        let clean = String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" })
        return clean.isEmpty || clean.count > 64 ? Data(SHA256.hash(data: Data(id.utf8)).prefix(24)).base64URL : clean
    }

    /// A version string the relay accepts: up to 32 of [0-9A-Za-z.+() -].
    nonisolated static func version(_ app: String) -> String {
        let clean = String(app.filter { $0.isASCII && ($0.isLetter || $0.isNumber || ".+() -".contains($0)) }.prefix(32))
        return clean.isEmpty ? "0" : clean
    }
}
