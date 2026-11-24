import Foundation
import SideACore
import SideAProtocol

/// One notification to send: what it says, to which phones, and what holds it back or ends it.
struct PushSpec {
    var payload: PushPayload
    var category: PushCategory
    var collapse: String
    var wanted: (NotificationPrefs) -> Bool
    var level: String
    var timeSensitive = false
    var expiresIn = 3600
    var sound = true
    var only: (RemoteDevice) -> Bool = { _ in true }
    /// False once what it announces is settled, so a retry or a late send is dropped.
    var alive: () -> Bool = { true }
    /// Why it went, for the decision log; nil: because the user is away from the Mac.
    var reason: String?
    /// It takes the place of a notification already sent, whatever the phone is doing and whatever its settings.
    var replaces = false
}

struct PushOutcome {
    var sent: [String] = []
    /// Phones that were in front on the push's session, which is why they didn't get it yet.
    var watching: [String] = []
}

struct Watched {
    var spec: PushSpec
    var devices: Set<String>
}

extension RemotePush {
    /// Every send is one decision per phone, logged: sent (with the relay's word, once it has it), suppressed (a phone is
    /// watching), or skipped (a setting, no key, nothing to send to).
    @discardableResult
    func send(_ spec: PushSpec) -> PushOutcome {
        let data = RemotePushPayload.encoded(spec.payload)
        var sealed: [String: String] = [:]
        var outcome = PushOutcome()
        for device in controller?.devices.devices ?? [] {
            if let why = Self.passedOver(device, spec) { decided(spec, device.id, "skipped", why); continue }
            if !spec.replaces, holds(device, spec) {
                outcome.watching.append(device.id)
                decided(spec, device.id, "suppressed", "watching")
                continue
            }
            guard let key = Self.key(device), let envelope = try? PushEnvelope.seal(data, with: key, category: spec.category, collapseID: spec.collapse, deviceID: device.id) else {
                decided(spec, device.id, "skipped", "couldn't-seal")
                continue
            }
            sealed[device.id] = envelope
        }
        #if DEBUG
        if !sealed.isEmpty { sealing?(spec.payload, spec.category, spec.collapse, sealed.keys.sorted()) }
        #endif
        guard !sealed.isEmpty else { return outcome }
        guard delivery.canSend else {
            for device in sealed.keys.sorted() { decided(spec, device, "skipped", "no-relay") }
            return outcome
        }
        let why = spec.reason ?? (presence().away(for: PushScheduler.atMac) ? "user-away" : "not-held")
        // Each device's own Time Sensitive switch: the relay takes one level per send, so devices that differ go apart.
        let groups = Dictionary(grouping: sealed.keys) { id in
            spec.timeSensitive && controller?.devices.devices.first { $0.id == id }?.push?.prefs.timeSensitiveRequests == false ? "active" : spec.level
        }
        for (level, ids) in groups.sorted(by: { $0.key < $1.key }) {
            for batch in Self.batches(ids.sorted()) {
                let body = RelayClient.Send(devices: batch, kind: "alert", category: spec.category.rawValue, collapseId: spec.collapse, priority: 10,
                                            expiresIn: spec.expiresIn, sound: spec.sound, level: level, sealed: sealed.filter { batch.contains($0.key) })
                delivery.alert(body, kind: spec.payload.t, reason: why, follows: spec.replaces, alive: spec.alive) { [weak self] results in
                    self?.delivered(spec, results)
                }
            }
        }
        outcome.sent = Array(sealed.keys)
        return outcome
    }

    nonisolated static func passedOver(_ device: RemoteDevice, _ spec: PushSpec) -> String? {
        guard spec.only(device) else { return "not-this-phone" }
        guard let push = device.push else { return "no-registration" }
        guard spec.replaces || spec.wanted(push.prefs) else { return "setting-off" }
        guard device.pushKey != nil, device.pushKeyID != nil else { return "no-push-key" }
        return nil
    }

    private func decided(_ spec: PushSpec, _ device: String, _ decision: String, _ reason: String) {
        delivery.line(spec.payload.t, spec.collapse, device: device, decision, reason)
    }

    func skipped(_ kind: String, _ id: String, _ reason: String) { delivery.line(kind, Self.collapse(id), device: nil, "skipped", reason) }

    /// A push the scheduler is keeping back, for the log: the user is at the Mac, or the grace for a request hasn't run out.
    func logHeld(_ id: String, kind: String, collapse: String? = nil) {
        guard scheduler.held.contains(where: { $0.id == id }) else { return }
        delivery.line(kind, collapse ?? Self.collapse(id), device: nil, "held", presence().away(for: PushScheduler.atMac) ? "grace" : "at-mac")
    }

    /// A request's alert, remembered as shown to the phones that took it, so a later answer (or a relaunch) can take it away.
    private func delivered(_ spec: PushSpec, _ results: [String: String]) {
        guard Self.outstandingKinds.contains(spec.payload.t), spec.alive(), !spec.replaces else { return }
        let shown = results.filter { $0.value == "ok" }.keys.sorted()
        guard !shown.isEmpty else { return }
        outstanding.sent(spec.collapse, to: shown)
        saveOutstanding()
    }

    nonisolated static let outstandingKinds: Set<String> = [PushKind.request.rawValue, PushKind.question.rawValue, PushKind.plan.rawValue]

    // MARK: Quiet while watching

    func holds(_ device: RemoteDevice, _ spec: PushSpec) -> Bool {
        guard let presence = presenceOf(device.id) else { return false }
        return PushWatching.holds(prefs: device.push?.prefs, foreground: presence.foreground, viewing: presence.viewing, at: presence.at,
                                  now: clock(), session: spec.payload.sid)
    }

    /// A request goes out; phones that were watching its session are remembered, and get it once they stop.
    func sendRequest(_ spec: PushSpec, id: String) {
        let outcome = send(spec)
        dismissals.sent(spec.collapse, to: outcome.sent)
        guard !outcome.watching.isEmpty else { return }
        watched[id] = Watched(spec: spec, devices: Set(outcome.watching))
        armWatching()
    }

    /// A phone's presence changed (it left the front, closed the session, lost its socket): a request it was watching,
    /// still waiting, now goes to it.
    func watchingChanged() {
        for (id, entry) in watched {
            guard open.contains(id) else { watched[id] = nil; continue }
            let free = entry.devices.filter { device in controller?.devices.devices.first { $0.id == device }.map { !holds($0, entry.spec) } ?? true }
            guard !free.isEmpty else { continue }
            var spec = entry.spec
            spec.only = { free.contains($0.id) }
            spec.reason = "stopped-watching"
            let outcome = send(spec)
            dismissals.sent(spec.collapse, to: outcome.sent)
            let rest = entry.devices.subtracting(free).union(outcome.watching)
            watched[id] = rest.isEmpty ? nil : Watched(spec: entry.spec, devices: rest)
        }
        armWatching()
    }

    /// A phone that went quiet without a word is let go by its lease running out, which nothing announces: look again.
    func armWatching() {
        guard !watched.isEmpty else { watchTimer?.cancel(); watchTimer = nil; return }
        guard watchTimer == nil else { return }
        watchTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            watchTimer = nil
            watchingChanged()
        }
    }

    // MARK: Taking a notification away

    func dismiss(_ request: RequestID, answeredBy: String? = nil) {
        resolve(request)
        clear(Self.collapse(request), answeredBy: answeredBy)
    }

    /// Who ended a request, when nobody answered it; nil when someone did.
    nonisolated static func unanswered(_ by: Island.Resolution) -> String? {
        switch by {
        case .handedBack: "Handed back to the terminal"
        case .finished: "The turn ended before it was answered"
        case .gone: "The session ended"
        case .mac, .notification, .remote, .terminal, .auto: nil
        }
    }

    /// A request ended with no answer. The relay's removal says "Answered", so the notification is replaced with what happened.
    func withdrawn(_ request: RemoteRequest, why: String) {
        resolve(request.id)
        let collapse = Self.collapse(request.id)
        let devices = dismissals.settled(collapse, answeredBy: nil)
        forgetOutstanding(collapse)
        replaceAlert(collapse, devices, RemotePushPayload.withdrawn(request, why: why, mac: RemoteController.macID, now: clock().timeIntervalSince1970), reason: "not-answered")
    }

    private func replaceAlert(_ collapse: String, _ devices: [String], _ payload: PushPayload, reason: String) {
        guard !devices.isEmpty else { return }
        var spec = PushSpec(payload: payload, category: .health, collapse: collapse, wanted: { _ in true }, level: "passive", sound: false)
        spec.only = { devices.contains($0.id) }
        spec.replaces = true
        spec.reason = reason
        send(spec)
    }

    /// `silently`: nobody acted, so the notification stays as it was; the relay's removal would say "Answered".
    func clear(_ collapse: String, answeredBy: String? = nil, silently: Bool = false) {
        let devices = dismissals.settled(collapse, answeredBy: answeredBy)
        forgetOutstanding(collapse)
        guard !devices.isEmpty else { return }
        guard !silently else { return delivery.line("dismiss", collapse, device: nil, "skipped", "nobody-answered") }
        guard delivery.canSend else { return }
        for batch in Self.batches(devices) {
            delivery.dismiss(RelayClient.Send(devices: batch, kind: "dismiss", collapseId: collapse, priority: 5), reason: "answered")
        }
    }

    // MARK: After a relaunch

    private func forgetOutstanding(_ collapse: String) {
        guard !outstanding.showing(collapse).isEmpty else { return }
        _ = outstanding.settled(collapse, answeredBy: nil)
        saveOutstanding()
    }

    private func saveOutstanding() {
        guard let url = outstandingURL else { return }
        let all = Dictionary(uniqueKeysWithValues: outstanding.all.map { ($0.collapse, $0.devices) })
        if all.isEmpty { try? FileManager.default.removeItem(at: url); return }
        do { try PrivateFile.write(all, to: url) } catch {
            RemoteLog.shared("couldn't save which requests a phone is showing: \(error.localizedDescription)")
        }
    }

    /// Once per launch: a request that was showing on a phone when the Mac last quit can't be answered now (the agent's
    /// hook died with it), so its notification is replaced with a plain "closed" rather than left to be tapped.
    func sweepStaleAlerts() {
        guard !swept, let url = outstandingURL else { return }
        swept = true
        guard let saved = try? PrivateFile.read([String: [String]].self, from: url) else { return }
        try? FileManager.default.removeItem(at: url)
        let paired = Set(controller?.devices.devices.map(\.id) ?? [])
        for (collapse, devices) in saved.sorted(by: { $0.key < $1.key }) where !open.contains(where: { Self.collapse($0) == collapse }) {
            replaceAlert(collapse, devices.filter(paired.contains), RemotePushPayload.closedAfterRestart(mac: RemoteController.macID, now: clock().timeIntervalSince1970),
                         reason: "after-relaunch")
        }
    }
}
