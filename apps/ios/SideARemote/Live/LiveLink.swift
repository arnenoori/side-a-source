import Foundation
import Network
import Observation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

/// Feeds the stores from one paired Mac: the sync engine's state into sessions, requests, accounts
/// and the Mac chip, and a transcript feed for the session on screen. Answers and replies leave
/// through the engine's outbox, so a dropped connection doesn't lose them.
@Observable
final class LiveLink {
    /// The Macs whose socket is live right now, by id.
    static var liveMacs: Set<String> { Set(liveOwners.keys) }
    /// Which link made each Mac live: a stopped link takes away only its own, never a replacement's for the same Mac.
    @ObservationIgnored private static var liveOwners: [String: ObjectIdentifier] = [:]
    @ObservationIgnored private var stopped = false
    private(set) var mac: PairedMac
    private(set) var state = RemoteState()
    let engine: SyncEngine
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var updates: Task<Void, Never>?
    /// Answers on their way, by request, until the outbox settles them. A new tap replaces the entry.
    @ObservationIgnored private var sent: [RequestID: Sent] = [:]
    @ObservationIgnored private let path = NWPathMonitor()
    @ObservationIgnored private var saving: Task<Void, Never>?
    /// Transcripts on screen, which their feeds keep; prefetch leaves them alone.
    @ObservationIgnored private var following: Set<SessionKey> = []
    /// Each prefetched session's `statusAt` then, so it's fetched again only once it has moved on.
    @ObservationIgnored private var prefetched: [SessionKey: Timestamp?] = [:]
    /// The engine goes through `Paths` only when no transport was handed in; a test's own transport has no path to show.
    @ObservationIgnored private let routed: Bool
    @ObservationIgnored private var routeWatch: Task<Void, Never>?
    let flights: ReplyFlights

    private struct Sent {
        var attempt: AnswerAttempt
        let session: SessionKey
        let answer: RemoteAnswer
        let mode: PermissionMode?
        /// The key that signed it: Face ID's for a destructive Allow from the sheet, else the unlock key.
        let signer: DeviceKeys.Signer
    }

    @ObservationIgnored private var seenQueueDrops: [SessionKey: Int] = [:]
    @ObservationIgnored private var dropsRefresh: Task<Void, Never>?

    init(mac: PairedMac, outbox: Outbox, transport: (any Transport)? = nil) {
        self.mac = mac
        routed = transport == nil
        engine = SyncEngine(endpoint: mac.endpoint, credentials: KeychainCredentials(), outbox: outbox, transport: transport)
        flights = ReplyFlights(engine: engine, outbox: outbox, mac: mac)
        flights.link = self
    }

    deinit {
        updates?.cancel()
        routeWatch?.cancel()
        path.cancel()
    }

    /// Forgotten or replaced: nothing of this link keeps running.
    func stop() {
        stopped = true
        setLive(false)
        updates?.cancel()
        saving?.cancel()
        routeWatch?.cancel()
        path.cancel()
        if PushRegistrar.shared.observers[mac.endpoint.macID] != nil { PushRegistrar.shared.observers[mac.endpoint.macID] = nil }
        Task { [engine] in await engine.stop() }
    }

    func attach(_ model: AppModel) {
        self.model = model
        flights.model = model
        let engine = engine
        model.requests.onAnswer = { [weak self] request, answer, mode, confirm in self?.send(request, answer, mode: mode, confirm: confirm) }
        model.transcripts.onRetry = { [weak self] answered in self?.retry(answered) }
        PushRegistrar.shared.observers[mac.endpoint.macID] = { [weak self] in self?.reportPush() }
        model.transcripts.onLoadEarlier = { session in Task { try? await engine.transcript(session).loadEarlier() } }
        model.transcripts.onLoadWhole = { session, seq in try await engine.message(session, seq: seq) }
        // A network change retries at once instead of waiting out the backoff.
        path.pathUpdateHandler = { [weak model] update in
            let vpn = update.availableInterfaces.contains { $0.type == .other }
            Task { @MainActor in
                model?.mac.vpnUp = vpn
                await engine.reconnectNow()
            }
        }
        path.start(queue: .global(qos: .utility))
        if routed { watchRoute(model) }
        Task { await flights.restoreFlights() }
        // Off the main actor, so the hello goes out now rather than once the first frames are drawn.
        Task.detached(priority: .userInitiated) { await engine.start() }
        updates = Task { [weak self] in
            for await state in engine.updates {
                guard let self else { return }
                self.apply(state)
            }
        }
    }

    /// Through a stream, so switches reach the model in the order `Paths` made them.
    private func watchRoute(_ model: AppModel) {
        let paths = Paths.shared(for: mac.endpoint, credentials: KeychainCredentials())
        let (changes, continuation) = AsyncStream.makeStream(of: Paths.Path?.self, bufferingPolicy: .bufferingNewest(1))
        routeWatch = Task { [weak model] in
            let id = await paths.observe { continuation.yield($0) }
            for await path in changes {
                let route = MacConnection.Route(path)
                if model?.mac.route != route { model?.mac.route = route }
            }
            await paths.stopObserving(id)
        }
    }

    func setForeground(_ foreground: Bool) {
        if !foreground { save() }
        Task { [engine, mac] in
            // Back in front: race the paths now rather than wait out a backoff from while it was away.
            if foreground { await Paths.shared(for: mac.endpoint, credentials: KeychainCredentials()).foreground() }
            await engine.setForeground(foreground)
        }
    }

    /// Runs while a transcript is on screen: loads the newest page, then follows it until the view
    /// goes away.
    func follow(_ session: SessionKey) async {
        following.insert(session)
        defer { following.remove(session) }
        let feed = await engine.watch(session)
        let windows = await feed.windows()
        let start = ContinuousClock.now
        try? await feed.loadLatest()
        let shown = model?.transcripts.messages[session]?.count ?? 0
        RemoteLog.log(.sync, "transcript \(session.prefix(8)) latest page in \(Launch.ms(since: start)) ms, \(shown) shown before it")
        for await window in windows {
            model?.transcripts.set(window.messages, hasEarlier: window.hasEarlier, for: session)
            saveSoon()
        }
        await engine.unwatch(session)
    }

    private func send(_ request: RemoteRequest, _ answer: RemoteAnswer, mode: PermissionMode?, confirm: String?) {
        sent[request.id] = nil
        Task { [engine, mac] in
            // In the app the phone is unlocked, so the unlock key signs without asking; the Mac decides whether it needs it.
            let signer: DeviceKeys.Signer = confirm == nil ? .unlock : .confirm
            var confirm = confirm
            if confirm == nil, let subject = try? Self.subject(request.id, answer, mode: mode) {
                confirm = await mac.sign(.unlock, purpose: .allow, subject: subject)
            }
            let item = await engine.answer(request.id, answer, mode: mode, confirm: confirm)
            guard let session = request.sessionID else { return }
            sent[request.id] = Sent(attempt: .sending(item: item.id, retried: false), session: session, answer: answer, mode: mode, signer: signer)
            track(state)
        }
    }

    /// 409 `outcome_unknown` is never retried by the outbox; the user's Retry sends the same
    /// answer under a new key.
    private func retry(_ answered: TranscriptStore.AnsweredRequest) {
        guard !DeviceKeys.appLocked, let entry = sent[answered.id], case .unknown(let item) = entry.attempt else { return }
        sent[answered.id]?.attempt = .retrying(item: item)
        model?.transcripts.deliver(answered.id, in: entry.session, .sending)
        Task { [engine, mac] in
            // A signature is good for its moment only, so the retry is signed again by the same key: Face ID asks again.
            var confirm: String?
            if let subject = try? Self.subject(answered.id, entry.answer, mode: entry.mode) {
                confirm = await mac.sign(entry.signer, purpose: .allow, subject: subject, reason: "Allow \(RequestText.visible(answered.request.detail))")
                guard confirm != nil || entry.signer == .unlock else {
                    if case .retrying = sent[answered.id]?.attempt { sent[answered.id]?.attempt = .unknown(item: item) }
                    return model?.transcripts.deliver(answered.id, in: entry.session, .unknown) ?? ()
                }
            }
            let again = await engine.retry(itemID: item, confirm: confirm)
            guard case .retrying = sent[answered.id]?.attempt else { return }
            if let again {
                sent[answered.id]?.attempt = .sending(item: again.id, retried: true)
            } else {
                sent[answered.id] = nil
                model?.transcripts.deliver(answered.id, in: entry.session, .failed("Open the session to check, then answer again."))
            }
        }
    }

    /// What an answer's confirm signs: an Allow that switches mode signs the mode.
    static func subject(_ request: RequestID, _ answer: RemoteAnswer, mode: PermissionMode?) throws -> String? {
        if let mode { return try ConfirmMessage.subject(requestID: request, allowMode: mode) }
        return try ConfirmMessage.subject(requestID: request, answer: answer)
    }

    /// Moves each sent answer's line along: sending, then delivered, answered elsewhere, unknown or failed.
    func track(_ state: RemoteState) {
        for (session, drops) in state.queueDrops where drops != seenQueueDrops[session] {
            seenQueueDrops[session] = drops
            if state.hello?.capabilities.contains(.repliesDropped) == true {
                refreshDrops()
            } else {
                model?.transcripts.failQueued(in: session, reason: DroppedReply.Reason.sessionEnded.unsentReason)
            }
        }
        guard let transcripts = model?.transcripts else { return }
        settleDropped(state, in: transcripts)
        for (id, entry) in sent {
            if case .sending(let item, _) = entry.attempt, case .failed(let error)? = state.outcomes[item] { model?.tools.noteRefusal(error) }
            let (delivery, next) = entry.attempt.advanced(in: state, request: id)
            if let delivery {
                transcripts.deliver(id, in: entry.session, delivery)
            } else if transcripts.answered[entry.session]?.first(where: { $0.id == id })?.delivery == .unknown {
                transcripts.deliver(id, in: entry.session, .answeredElsewhere)
            }
            if let next { sent[id]?.attempt = next } else { sent[id] = nil }
        }
        flights.trackSteering(state)
    }

    /// A live drop says only which session: the snapshot says which reply, so a phone that heard it and one that was away
    /// settle it the same way, once. The next snapshot covers a refresh that never gets through.
    private func refreshDrops() {
        guard dropsRefresh == nil else { return }
        dropsRefresh = Task { [engine] in
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
                if (try? await engine.refresh()) != nil { break }
            }
            dropsRefresh = nil
        }
    }

    /// Until the first snapshot the state has no drops to read, and settling against none would forget them all.
    private func settleDropped(_ state: RemoteState, in transcripts: TranscriptStore) {
        guard state.epoch != nil else { return }
        let dropped = state.droppedReplies
        let key = "settledDrops." + mac.endpoint.macID
        let settled = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let now = transcripts.settle(dropped, device: mac.deviceID, settled: settled)
        if now != settled { UserDefaults.standard.set(Array(now), forKey: key) }
    }

    /// A burst of updates saves once, a few seconds after it settles.
    private func saveSoon() {
        saving?.cancel()
        saving = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        saving?.cancel()
        guard let model, state.epoch != nil else { return }
        model.cache(finished: state.finished).save(mac.endpoint.macID)
    }

    /// The APNs token and notification settings to the Mac: on each connection, since the Mac is the
    /// relay's source of truth, and whenever either changes.
    func reportPush() {
        guard state.connection.isLive else { return }
        Task { [engine] in await PushRegistrar.shared.report(to: await engine.client) }
    }

    /// Live for its Mac until it drops or stops; a state that arrives after `stop` doesn't make it live again.
    private func setLive(_ live: Bool) {
        let macID = mac.endpoint.macID, me = ObjectIdentifier(self)
        if live, !stopped {
            Self.liveOwners[macID] = me
        } else if Self.liveOwners[macID] == me {
            Self.liveOwners[macID] = nil
        }
    }

    func apply(_ state: RemoteState) {
        let connected = state.connection.isLive && !self.state.connection.isLive
        self.state = state
        setLive(state.connection.isLive)
        if connected {
            Launch.mark("live")
            reportPush()
            sweepNotifications()
        }
        if state.epoch != nil { Launch.mark("snapshot", "\(state.sessions.count) sessions") }
        if let hello = state.hello, hello.paired == true { mac = mac.updating(hello.endpoints) }
        guard let model else { return }
        // Until the first snapshot the engine's state is empty, and the cache drawn at launch stays.
        if state.epoch != nil {
            model.sessions.replace(Array(state.sessions.values), finished: state.finished)
            model.requests.replace(state.requests) { [mac] id in state.resolved[id]?.line(thisDevice: mac.deviceID) }
            model.accounts.replace(Array(state.accounts.values))
            saveSoon()
        }
        model.tools.apply(state)
        model.mac.apply(state, name: mac.endpoint.name,
                        onTailnet: Tailscale.isTailnet((state.address ?? mac.endpoint.baseURL).host() ?? ""), hasRelay: mac.endpoint.relay != nil)
        track(state)
        if state.connection.isLive {
            WidgetPublisher.shared.refresh()
            prefetch()
        }
    }

    /// Once a connection: the open list read fresh, then any request notification left up for one no longer in it.
    private func sweepNotifications() {
        let asked = Date.now
        Task { [engine, mac] in
            do { try await engine.refreshRequests() } catch { return }
            let state = await engine.state
            let open = Set(state.requests.keys).union(state.pending.compactMap(\.answering))
            await DeliveredRequests.sweep(mac: mac.endpoint.macID, open: open, asked: asked, onlyMac: PairedMac.all().count == 1)
        }
    }

    /// The transcripts likely opened next, what needs you and then the newest working sessions: their newest page,
    /// without subscribing, so opening one draws at once and its feed only catches up.
    private func prefetch() {
        guard let model, state.epoch != nil else { return }
        let likely = (model.sessions.rows(.needsYou) + model.sessions.rows(.working)).prefix(4)
        let due = likely.filter { !following.contains($0.id) && prefetched[$0.id] != .some($0.statusAt) }.map(\.id)
        guard !due.isEmpty else { return }
        for session in likely where due.contains(session.id) { prefetched[session.id] = .some(session.statusAt) }
        Task { [engine] in
            let start = ContinuousClock.now
            for session in due {
                guard let page = try? await engine.client.transcript(session, .latest), !following.contains(session) else { continue }
                model.transcripts.set(page.messages, hasEarlier: page.before != nil, for: session)
            }
            RemoteLog.log(.sync, "prefetched \(due.count) transcripts in \(Launch.ms(since: start)) ms")
            saveSoon()
        }
    }
}

/// One tap's answer on its way, under its own outbox item, so it never reads what an earlier tap's key came to.
enum AnswerAttempt: Equatable {
    case sending(item: String, retried: Bool)
    /// Retry was tapped and it's being signed: no outcome to read until it's queued.
    case retrying(item: String)
    /// 409 `outcome_unknown`, kept for Retry.
    case unknown(item: String)

    /// What the row shows (nil: leave it, the request settled elsewhere) and what's left; nil once settled.
    func advanced(in state: RemoteState, request: RequestID) -> (delivery: TranscriptStore.Delivery?, next: AnswerAttempt?) {
        switch self {
        case .retrying:
            return (.sending, self)
        case .unknown:
            return state.resolved[request] == nil ? (.unknown, self) : (nil, nil)
        case .sending(let item, let retried):
            let delivery = TranscriptStore.Delivery(state.outcomes[item], retried: retried)
            switch delivery {
            case .sending: return (delivery, self)
            case .unknown: return (delivery, .unknown(item: item))
            default: return (delivery, nil)
            }
        }
    }
}

extension TranscriptStore.Delivery {
    /// An outbox outcome as the answer's line shows it; nil while a retry is in flight.
    init(_ outcome: OutboxOutcome?, retried: Bool) {
        self = switch outcome {
        case .delivered?: .delivered
        // A retry that finds the request settled means the first attempt landed.
        case .answeredElsewhere? where retried: .delivered
        case .answeredElsewhere?: .answeredElsewhere
        // Gone after a retry isn't a refusal; the first attempt may be why.
        case .failed(let error)? where retried && error.code == .requestNotFound: .gone
        case .unknown?: .unknown
        case .failed(let error)?: .failed(error.message)
        case .notDelivered?: .failed("The Mac couldn't be reached in time.")
        case nil: .sending
        }
    }
}

extension RequestResolution {
    /// What the transcript says about a request settled away from this screen.
    func line(thisDevice: String) -> String {
        switch by {
        case .mac: answer == .allow ? "Allowed on Mac" : answer == .deny ? "Denied on Mac" : "Answered on Mac"
        // The notification's own actions answer as this device, without the app.
        case .device where deviceID == thisDevice: "Answered from a notification"
        case .device: "Answered on \(deviceName ?? "another device")"
        case .terminal: "Answered in the terminal"
        case .handedBack: "Handed back to the terminal"
        case .sessionEnded: "Session ended"
        case .turnFinished: "Turn finished"
        case .autoAnswered: answer == .approvePlan ? "Plan approved after a minute" : "Answered with recommended after a minute"
        default: "Answered elsewhere"
        }
    }
}

extension MacConnection {
    /// A drop shows as "Reconnecting…" for a minute, then as offline with the reason.
    /// `onTailnet`: the Mac's address needs Tailscale, so a missing VPN explains the drop, unless the relay reaches it anyway.
    func apply(_ remote: RemoteState, name: String, onTailnet: Bool = true, hasRelay: Bool = false, now: Date = .now) {
        if self.name != name { self.name = name }
        if let mac = remote.mac {
            onPower = mac.onPower
            battery = mac.battery
            memoryUsed = Double(mac.memoryUsed) / 1_000_000_000
            memoryTotal = Double(mac.memoryTotal) / 1_000_000_000
            keepAwake = mac.keepAwake
        }
        let next: State
        switch remote.connection {
        case .live:
            next = .live
            lastSeen = now
        case .idle, .connecting, .offline:
            if remote.macAsleep { next = .offline(.macAsleep); break }
            if remote.relayRefused { next = .offline(.relayRefused); break }
            switch state {
            case .live: next = .reconnecting(since: now)
            case .reconnecting(let since) where now.timeIntervalSince(since) < 60: next = state
            case .connecting where remote.connection == .connecting || remote.connection == .idle: next = .connecting
            default: next = .offline(vpnUp || !onTailnet || hasRelay ? .macUnreachable : .tailscaleOff)
            }
        case .unpaired:
            next = .offline(.revoked)
        case .keyChanged:
            next = .offline(.keyChanged)
        case .needsUpdate(let macIsOld):
            next = .offline(macIsOld ? .incompatible(installed: remote.hello?.app) : .appOutdated)
        }
        if state != next { state = next }
    }
}
