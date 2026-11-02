import CryptoKit
import Foundation
import os
import SideACore
import SideAProtocol

/// Notifications to paired phones through the relay: each phone's tokens registered with it, each push sealed per
/// device under its own key, nothing sent to a phone that turned that kind off or is looking at the session.
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

    // MARK: Devices

    /// `POST /v1/devices/push`: keep what the phone reported and register it with the relay.
    func register(_ device: String, _ registration: PushRegistration) async -> Bool {
        guard let controller, let record = controller.devices.devices.first(where: { $0.id == device }) else { return false }
        try? controller.devices.update(device) { $0.push = registration }
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

    /// A request, question or plan that just arrived.
    func request(_ request: RemoteRequest) {
        let (category, payload) = RemotePushPayload.request(request, mac: RemoteController.macID, now: Date().timeIntervalSince1970)
        let wanted: (NotificationPrefs) -> Bool = switch payload.t {
        case "question": \.questions
        case "plan": \.plans
        default: \.requests
        }
        let level = category == .request || category == .requestDestructive ? "time-sensitive" : "active"
        let collapse = Self.collapse(request.id)
        dismissals.sent(collapse, to: send(payload, category: category, collapse: collapse, session: request.sessionID, wanted: wanted,
                                           level: level, timeSensitive: true, expiresIn: 3600))
    }

    func finished(_ finished: FinishedSession) {
        let payload = RemotePushPayload.finished(finished, mac: RemoteController.macID, now: Date().timeIntervalSince1970)
        send(payload, category: .finished, collapse: Self.collapse(finished.turnID), session: finished.sessionID, wanted: \.finished,
             level: "active", timeSensitive: false, expiresIn: 3600)
    }

    /// Passive, once per session an hour, to phones that keep health notifications on.
    func health(_ session: RemoteSession, _ flag: SessionFlag) {
        let now = Date()
        if let last = healthSent[session.id], now.timeIntervalSince(last) < 3600 { return }
        healthSent[session.id] = now
        let payload = RemotePushPayload.health(session, flag: flag, mac: RemoteController.macID, now: now.timeIntervalSince1970)
        send(payload, category: .health, collapse: Self.opaque("health-" + session.id), session: session.id, wanted: \.health,
             level: "passive", timeSensitive: false, expiresIn: 3600)
    }

    /// A reply the phone was told is Queued that can't go now. The session may be gone, so this is the only word of it.
    func queuedDropped(session: SessionKey, title: String?, text: String) {
        let payload = RemotePushPayload.queuedDropped(session: session, title: title, text: text, mac: RemoteController.macID, now: Date().timeIntervalSince1970)
        send(payload, category: .health, collapse: Self.opaque("dropped-" + session), session: session, wanted: \.health,
             level: "active", timeSensitive: false, expiresIn: 3600)
    }

    /// An account in use passed 90% or reached its limit in a window; once per threshold until the window resets.
    func limit(_ account: RemoteAccount, _ window: UsageWindow, threshold: Int) {
        let key = "\(account.id)|\(window.id)|\(threshold)|\(Int(window.resetsAt ?? 0))"
        guard limitSent.insert(key).inserted else { return }
        let payload = RemotePushPayload.limit(account, window: window, mac: RemoteController.macID, now: Date().timeIntervalSince1970)
        send(payload, category: .limit, collapse: Self.opaque("limit-" + account.id + "-" + window.id), session: nil, wanted: \.limits,
             level: "active", timeSensitive: false, expiresIn: 3600)
    }

    /// Autopilot moved sessions or ran out of accounts. Only phones that said they can show one get it: an older phone's
    /// Service Extension has no words for this kind, and the relay would still wake it.
    func rotation(title: String, body: String?, account: String?, resetsAt: Timestamp?) {
        let payload = RemotePushPayload.rotation(title: title, body: body, account: account, resetsAt: resetsAt, mac: RemoteController.macID,
                                                 now: Date().timeIntervalSince1970)
        send(payload, category: .rotation, collapse: "rotation", session: nil, wanted: { $0.rotation == true }, level: "active", timeSensitive: false,
             expiresIn: 3600, only: Self.showsRotation)
    }

    /// Whether a paired phone asked for rotation pushes, in words it can read.
    nonisolated static func showsRotation(_ device: RemoteDevice) -> Bool { device.rotationPushes == true }

    private var healthSent: [SessionKey: Date] = [:]
    private var limitSent: Set<String> = []

    /// The phones each request's notification went to, so only they get its "Answered".
    private var dismissals = PushDismissals()

    /// Answered somewhere else: "Answered" replaces the notification on each phone that showed it, other than
    /// `answeredBy`, which already took its own away.
    func dismiss(_ request: RequestID, answeredBy: String? = nil) {
        let devices = dismissals.settled(Self.collapse(request), answeredBy: answeredBy)
        guard !devices.isEmpty, let relay else { return }
        let body = RelayClient.Send(devices: devices, kind: "dismiss", collapseId: Self.collapse(request), priority: 5)
        Task { await deliver(relay, body, doing: "clear a notification") }
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

    /// The devices it went to.
    @discardableResult
    private func send(_ payload: PushPayload, category: PushCategory, collapse: String, session: SessionKey?, wanted: (NotificationPrefs) -> Bool,
                      level: String, timeSensitive: Bool, expiresIn: Int, only: (RemoteDevice) -> Bool = { _ in true }) -> [String] {
        let data = RemotePushPayload.encoded(payload)
        let watching = controller?.hub
        var sealed: [String: String] = [:]
        for device in targets({ only($0) && $0.push.map { wanted($0.prefs) } ?? false }) {
            guard let key = Self.key(device), let push = device.push else { continue }
            // Watching the session in the app: the socket already showed it.
            if push.prefs.suppressWhileWatching, let session, let presence = watching?.presence(device.id),
               presence.foreground, presence.viewing == session { continue }
            if let envelope = try? PushEnvelope.seal(data, with: key, category: category, collapseID: collapse, deviceID: device.id) {
                sealed[device.id] = envelope
            }
        }
        guard !sealed.isEmpty, let relay else { return [] }
        // Each device's own Time Sensitive switch: the relay takes one level per send, so devices that differ go apart.
        let groups = Dictionary(grouping: sealed.keys) { id in
            timeSensitive && controller?.devices.devices.first { $0.id == id }?.push?.prefs.timeSensitiveRequests == false ? "active" : level
        }
        for (level, ids) in groups {
            let body = RelayClient.Send(devices: ids.sorted(), kind: "alert", category: category.rawValue, collapseId: collapse, priority: 10,
                                        expiresIn: expiresIn, sound: true, level: level, sealed: sealed.filter { ids.contains($0.key) })
            Task { await deliver(relay, body, doing: "send a notification") }
        }
        return Array(sealed.keys)
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
