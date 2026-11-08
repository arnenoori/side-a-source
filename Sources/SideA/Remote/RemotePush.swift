import CryptoKit
import Foundation
import os
import SideACore
import SideAProtocol

/// Notifications to paired phones through the relay: each phone's tokens registered with it, each push sealed per
/// device under its own key, nothing sent to a phone that turned that kind off or has the app open. `PushScheduler` says when.
@MainActor
final class RemotePush {
    /// ok, unreachable or unregistered, for setup.
    private(set) var relayState = "unregistered"
    private weak var controller: RemoteController?
    private var client: RelayClient?
    private let log = Logger(subsystem: "com.arnenoori.sidea", category: "push")
    /// Diagnostic pushes waiting for the phone's receipt, by id.
    private(set) var diagnostics: [String: (device: String, sent: Date, received: Date?)] = [:]

    init(controller: RemoteController) { self.controller = controller }

    private var relay: RelayClient? {
        if let client { return client }
        guard let controller, let base = controller.relayURL, let key = controller.installKey else { return nil }
        client = RelayClient(base: base, key: key)
        return client
    }

    /// Setup's relay row: whether the relay still knows this install, asked at most once a minute.
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
    /// Two phones reporting in turn flip the token at each launch; once an hour says all there is to say.
    static let tokenWarnEvery: TimeInterval = 3_600

    /// This route takes the token alone, so a phone can report from the background. A stolen token could send pushes
    /// elsewhere with it; an address that really moves is rare (a restore, a reinstall), so moving is worth saying, and a
    /// first report isn't.
    static func warns(from previous: String?, to next: String, warned: Date?, now: Date) -> Bool {
        guard let previous, previous != next else { return false }
        return warned.map { now.timeIntervalSince($0) >= tokenWarnEvery } ?? true
    }

    // MARK: Devices

    /// `POST /v1/devices/push`: keep what the phone reported and register it with the relay.
    func register(_ device: String, _ registration: PushRegistration) async -> Bool {
        guard let controller, let record = controller.devices.devices.first(where: { $0.id == device }) else { return false }
        try? controller.devices.update(device) { $0.push = registration }
        let now = Date()
        if Self.warns(from: record.push?.apnsToken, to: registration.apnsToken, warned: tokenWarned[device], now: now) {
            tokenWarned[device] = now
            RemoteLog.shared("device \(device) reported a new push token")
            NotificationRouter.deviceMoved(device, name: record.name)
        }
        perform(activities.reported(device, activities: Array(registration.activityTokens.keys), now: Date().timeIntervalSince1970), state: activities.state)
        // The phone's Live Activity switch comes with this report, and a card it turned off ends now.
        defer { activity(activities.state) }
        guard let relay else { return false }
        let input = RelayClient.Device(apnsToken: registration.apnsToken, bundleID: registration.bundleID,
                                       apnsEnvironment: registration.apnsEnvironment.rawValue, secretHash: record.secretHash,
                                       pushToStartToken: registration.pushToStartToken, appVersion: Self.version(record.app))
        do {
            let verified = try await relay.put(device, input)
            relayState = "ok"
            note(device, verified ? "ok" : "unverified")
            return true
        } catch {
            failed(error, device: device, doing: "register a phone")
            return false
        }
    }

    /// Revoke and Remove: the relay forgets the device. Best effort; an unknown device is no error.
    func forget(_ device: String) {
        activities.forget(device)
        guard let relay else { return }
        Task { try? await relay.delete(device) }
    }

    /// Remote's uninstall: the install and all its devices go.
    func deleteInstall() async {
        try? await relay?.deleteInstall()
        client = nil
        relayState = "unregistered"
    }

    // MARK: Sending

    /// The Mac's presence and the time, for when pushes go; tests supply their own.
    var presence: () -> UserPresence = UserPresence.now
    var clock: () -> Date = Date.init
    private(set) var scheduler = PushScheduler()
    /// The sends the scheduler holds, by its ids.
    private var held: [String: () -> Void] = [:]
    private var wake: Task<Void, Never>?

    /// A request, question or plan that just arrived. Time sensitive: something is waiting on it.
    func request(_ request: RemoteRequest) {
        let category = RemotePushPayload.request(request, mac: RemoteController.macID, now: 0).category
        held[request.id] = { [weak self] in
            guard let self else { return }
            let (category, payload) = RemotePushPayload.request(request, mac: RemoteController.macID, now: clock().timeIntervalSince1970)
            let wanted: (NotificationPrefs) -> Bool = switch payload.kind {
            case .question: \.questions
            case .plan: \.plans
            default: \.requests
            }
            let level = category == .request || category == .requestDestructive ? "time-sensitive" : "active"
            let collapse = Self.collapse(request.id)
            dismissals.sent(collapse, to: send(payload, category: category, collapse: collapse, wanted: wanted,
                                               level: level, timeSensitive: true, expiresIn: 3600))
        }
        run(scheduler.add(request.id, .ask(destructive: category == .requestDestructive), now: clock(), presence: presence()))
    }

    /// A turn that finished, and how long it ran when known: into the Mac's one Ready notification.
    func finished(_ finished: FinishedSession, ran: TimeInterval?) {
        run(scheduler.finished(finished, ran: ran, now: clock(), presence: presence()))
    }

    /// A turn that left Ready.
    func finishedResolved(_ turnID: String) { resolve(turnID) }

    /// Ready's one notification per Mac, updated in place. Active; without a sound soon after one that had it. A phone
    /// that can't show a grouped Ready gets each turn as its own FINISHED push instead, once.
    private func ready(_ turns: [FinishedSession], quiet: Bool) {
        guard !turns.isEmpty else { return }
        let now = clock().timeIntervalSince1970
        let payload = RemotePushPayload.ready(turns, mac: RemoteController.macID, now: now, quiet: quiet)
        send(payload, category: .finished, collapse: Self.readyCollapse, wanted: \.finished,
             level: "active", timeSensitive: false, expiresIn: 3600, sound: !quiet, only: Self.groupsReady)
        var sounded = quiet
        for turn in turns.reversed() where !perTurnSent.contains(turn.turnID) {
            perTurnSent.insert(turn.turnID)
            send(RemotePushPayload.finished(turn, mac: RemoteController.macID, now: now, quiet: sounded), category: .finished,
                 collapse: Self.collapse(turn.turnID), wanted: \.finished, level: "active", timeSensitive: false, expiresIn: 3600,
                 sound: !sounded, only: { !Self.groupsReady($0) })
            sounded = true
        }
        perTurnSent.formIntersection(turns.map(\.turnID))
    }

    /// The turns already pushed one by one to phones without grouped Ready.
    private var perTurnSent: Set<String> = []

    /// Per Mac, so two Macs' Ready notifications on one phone don't replace each other.
    static var readyCollapse: String { opaque("ready-" + RemoteController.macID) }

    /// Whether a paired phone said it shows a grouped Ready.
    nonisolated static func groupsReady(_ device: RemoteDevice) -> Bool { device.readyGroups == true }

    /// Passive, once per session an hour, to phones that keep health notifications on.
    /// A new flag replaces one still held; one that doesn't notify ends it.
    func health(_ session: RemoteSession, _ flag: SessionFlag) {
        guard Self.notifies(flag) else { return healthEnded(session.id) }
        if let last = healthSent[session.id], clock().timeIntervalSince(last) < 3600 { return }
        let id = Self.healthID(session.id)
        held[id] = { [weak self] in
            guard let self else { return }
            let now = clock()
            healthSent[session.id] = now
            let payload = RemotePushPayload.health(session, flag: flag, mac: RemoteController.macID, now: now.timeIntervalSince1970)
            send(payload, category: .health, collapse: Self.opaque("health-" + session.id), wanted: \.health,
                 level: "passive", timeSensitive: false, expiresIn: 3600)
        }
        run(scheduler.add(id, .health, now: clock(), presence: presence()))
    }

    /// The flag cleared or the session went: a health push still held doesn't go.
    func healthEnded(_ session: SessionKey) { resolve(Self.healthID(session)) }

    private static func healthID(_ session: SessionKey) -> String { "health:" + session }

    private func resolve(_ id: String) {
        scheduler.resolve(id)
        held[id] = nil
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

    /// One wake, for the soonest thing the scheduler waits on.
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

    /// Remote off: nothing held goes, and nothing waits to. Turned on again, it starts empty, as the events do: what was
    /// already open then isn't pushed.
    func stopScheduling() {
        wake?.cancel()
        wake = nil
        held = [:]
        scheduler = PushScheduler()
        perTurnSent = []
    }

    /// A full context isn't worth a notification: the flag stays on the session's row, and Restart Fresh is there.
    nonisolated static func notifies(_ flag: SessionFlag) -> Bool { flag.kind != .bloated }

    /// A reply the phone was told is Queued that can't go now. The session may be gone, so this is the only word of it.
    /// Never held: it answers something the phone sent, and whoever sent it may not be at the Mac.
    func queuedDropped(session: SessionKey, title: String?, text: String) {
        let payload = RemotePushPayload.queuedDropped(session: session, title: title, text: text, mac: RemoteController.macID, now: Date().timeIntervalSince1970)
        send(payload, category: .health, collapse: Self.opaque("dropped-" + session), wanted: \.health,
             level: "active", timeSensitive: false, expiresIn: 3600)
    }

    /// An account in use passed 90% or reached its limit in a window; once per threshold until the window resets. Held
    /// while someone is at the Mac, where the menu bar shows it; a later threshold for the window replaces a held one.
    func limit(_ account: RemoteAccount, _ window: UsageWindow, threshold: Int) {
        let key = "\(account.id)|\(window.id)|\(threshold)|\(Int(window.resetsAt ?? 0))"
        guard limitSent.insert(key).inserted else { return }
        let collapse = Self.opaque("limit-" + account.id + "-" + window.id)
        notice("limit:" + collapse) { [weak self] in
            guard let self else { return }
            let payload = RemotePushPayload.limit(account, window: window, mac: RemoteController.macID, now: clock().timeIntervalSince1970)
            send(payload, category: .limit, collapse: collapse, wanted: \.limits, level: "active", timeSensitive: false, expiresIn: 3600)
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
            send(payload, category: .rotation, collapse: "rotation", wanted: { $0.rotation == true }, level: Self.rotationLevel(blocks: blocks),
                 timeSensitive: false, expiresIn: 3600, only: Self.showsRotation)
        }
    }

    private func notice(_ id: String, _ send: @escaping () -> Void) {
        held[id] = send
        run(scheduler.add(id, .notice, now: clock(), presence: presence()))
    }

    /// A move is passive, since work goes on; no account left is active, since work stops.
    nonisolated static func rotationLevel(blocks: Bool) -> String { blocks ? "active" : "passive" }

    /// Whether a paired phone asked for rotation pushes, in words it can read.
    nonisolated static func showsRotation(_ device: RemoteDevice) -> Bool { device.rotationPushes == true }

    private var healthSent: [SessionKey: Date] = [:]
    private var limitSent: Set<String> = []

    /// The phones each request's notification went to, so only they get its "Answered".
    private var dismissals = PushDismissals()

    /// Answered somewhere else: "Answered" replaces the notification on each phone that showed it, other than
    /// `answeredBy`, which already took its own away.
    func dismiss(_ request: RequestID, answeredBy: String? = nil) {
        resolve(request)
        let devices = dismissals.settled(Self.collapse(request), answeredBy: answeredBy)
        guard !devices.isEmpty, let relay else { return }
        for batch in Self.batches(devices) {
            let body = RelayClient.Send(devices: batch, kind: "dismiss", collapseId: Self.collapse(request), priority: 5)
            Task { await deliver(relay, body, doing: "clear a notification") }
        }
    }

    /// One send names at most the relay's limit of devices; more go in further sends rather than fail together.
    nonisolated static func batches(_ devices: [String]) -> [[String]] {
        stride(from: 0, to: devices.count, by: RelayClient.maxDevices).map { Array(devices[$0..<min($0 + RelayClient.maxDevices, devices.count)]) }
    }

    /// Test Connection: one `TEST` push to one phone, with its result, and an id the phone acknowledges.
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

    // MARK: Live Activity

    private var activities = LiveActivities()
    private var ticker: Task<Void, Never>?

    /// From every change to sessions, requests or usage, and once a minute while an activity is up.
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

    private func perform(_ actions: [LiveActivities.Action], state: ActivityContentState) {
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

    // MARK: Delivery

    #if DEBUG
    /// Tests: each push sealed for its devices, before it's handed to the relay (none in tests).
    var sealing: ((PushPayload, PushCategory, String, [String]) -> Void)?
    #endif

    /// The devices it went to.
    @discardableResult
    private func send(_ payload: PushPayload, category: PushCategory, collapse: String, wanted: (NotificationPrefs) -> Bool,
                      level: String, timeSensitive: Bool, expiresIn: Int, sound: Bool = true,
                      only: (RemoteDevice) -> Bool = { _ in true }) -> [String] {
        let data = RemotePushPayload.encoded(payload)
        let watching = controller?.hub
        var sealed: [String: String] = [:]
        for device in targets({ only($0) && $0.push.map { wanted($0.prefs) } ?? false }) {
            guard let key = Self.key(device), device.push != nil else { continue }
            // The app is open on it: the socket already shows everything.
            if Self.skips(watching?.presence(device.id), now: Date()) { continue }
            if let envelope = try? PushEnvelope.seal(data, with: key, category: category, collapseID: collapse, deviceID: device.id) {
                sealed[device.id] = envelope
            }
        }
        #if DEBUG
        if !sealed.isEmpty { sealing?(payload, category, collapse, sealed.keys.sorted()) }
        #endif
        guard !sealed.isEmpty, let relay else { return [] }
        // Each device's own Time Sensitive switch: the relay takes one level per send, so devices that differ go apart.
        let groups = Dictionary(grouping: sealed.keys) { id in
            timeSensitive && controller?.devices.devices.first { $0.id == id }?.push?.prefs.timeSensitiveRequests == false ? "active" : level
        }
        for (level, ids) in groups {
            for batch in Self.batches(ids.sorted()) {
                let body = RelayClient.Send(devices: batch, kind: "alert", category: category.rawValue, collapseId: collapse, priority: 10,
                                            expiresIn: expiresIn, sound: sound, level: level, sealed: sealed.filter { batch.contains($0.key) })
                Task { await deliver(relay, body, doing: "send a notification") }
            }
        }
        return Array(sealed.keys)
    }

    /// A phone in front refreshes its presence every 30 s while its socket is up, and says at once when it leaves the
    /// front; this allows one refresh and some slack. Older than that, the phone may have been suspended without a word.
    nonisolated static let openFresh: TimeInterval = 40

    /// In front and fresh: the app shows it, so no push.
    nonisolated static func skips(_ presence: EventHub.Presence?, now: Date) -> Bool {
        guard let presence, presence.foreground else { return false }
        return now.timeIntervalSince(presence.at) <= openFresh
    }

    private func deliver(_ relay: RelayClient, _ body: some Encodable & Sendable, doing: String) async {
        do {
            for result in try await relay.send(body) { note(result.device, result.result) }
            relayState = "ok"
        } catch {
            failed(error, device: nil, doing: doing)
        }
    }

    private func targets(_ include: (RemoteDevice) -> Bool) -> [RemoteDevice] {
        (controller?.devices.devices ?? []).filter { $0.pushKey != nil && include($0) }
    }

    private func note(_ device: String, _ result: String) {
        guard let controller, controller.devices.devices.first(where: { $0.id == device })?.pushResult != result else { return }
        try? controller.devices.update(device) { $0.pushResult = result }
    }

    private func failed(_ error: Error, device: String?, doing: String) {
        let failure = error as? RelayClient.Failure
        if failure == nil || failure == .unreachable || (failure?.status ?? 0) >= 500 { relayState = "unreachable" }
        log.error("couldn't \(doing, privacy: .public): \(error.localizedDescription, privacy: .public)")
        if let device, let failure, failure.status == 409 || failure.status == 400 { note(device, "rejected") }
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
