import Foundation
import Network
import Observation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

@Observable
final class LiveLink {
    static var liveMacs: Set<String> { Set(liveOwners.keys) }
    /// Which link made each Mac live: a stopped link takes away only its own, never a replacement's for the same Mac.
    @ObservationIgnored private static var liveOwners: [String: ObjectIdentifier] = [:]
    @ObservationIgnored private var stopped = false
    private(set) var mac: PairedMac
    private(set) var state = RemoteState()
    let engine: SyncEngine
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var sent: [RequestID: Sent] = [:]
    @ObservationIgnored private let path = NWPathMonitor()
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var following: Set<SessionKey> = []
    @ObservationIgnored private var prefetched: [SessionKey: Timestamp?] = [:]
    @ObservationIgnored private let routed: Bool
    @ObservationIgnored private var routeWatch: Task<Void, Never>?
    @ObservationIgnored private var reconnectingEnds: Task<Void, Never>?
    let flights: ReplyFlights

    private struct Sent {
        var attempt: AnswerAttempt
        let session: SessionKey
        let answer: RemoteAnswer
        let mode: PermissionMode?
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

    func stop() {
        stopped = true
        setLive(false)
        updates?.cancel()
        saving?.cancel()
        routeWatch?.cancel()
        reconnectingEnds?.cancel()
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
        model.transcripts.onDraftsChanged = { [weak self] in self?.saveSoon() }
        model.transcripts.photosBack = { [weak model] photos, session in
            for photo in photos { model?.tools.attachments.giveBack(photo.ids, of: photo.turn, to: session) }
        }
        PushRegistrar.shared.observers[mac.endpoint.macID] = { [weak self] in self?.reportPush() }
        model.transcripts.onLoadEarlier = { session in Task { try? await engine.transcript(session).loadEarlier() } }
        model.transcripts.onLoadWhole = { session, seq in
            if let ref = SubagentRef(key: session) { return try await engine.message(ref.parent, seq: seq, agent: ref.agentID) }
            return try await engine.message(session, seq: seq)
        }
        path.pathUpdateHandler = { [weak model] update in
            let vpn = update.availableInterfaces.contains { $0.type == .other }
            let up = update.status == .satisfied
            Task { @MainActor in
                model?.mac.vpnUp = vpn
                PushRegistrar.shared.reportOwed()
                await engine.setNetwork(up)
                if up { await engine.reconnectNow() }
            }
        }
        path.start(queue: .global(qos: .utility))
        if routed { watchRoute(model) }
        Task { await flights.restoreFlights() }
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
        routeWatch = Task { [weak model, engine] in
            let id = await paths.observe { continuation.yield($0) }
            for await path in changes {
                let route = MacConnection.Route(path)
                if model?.mac.route != route { model?.mac.route = route }
                if path != nil { await engine.reconnectNow() }
            }
            await paths.stopObserving(id)
        }
    }

    func setForeground(_ foreground: Bool) {
        if !foreground { save() }
        flights.inFront = foreground
        if foreground {
            model?.mac.foregrounded()
            PushRegistrar.shared.reportOwed()
            // A notification's reply may have been held or queued while this process slept.
            Task { await flights.restoreFlights() }
        }
        Task { [engine, mac] in
            if foreground { await Paths.shared(for: mac.endpoint, credentials: KeychainCredentials()).foreground() }
            await engine.setForeground(foreground)
        }
    }

    func follow(_ session: SessionKey) async {
        following.insert(session)
        defer { following.remove(session) }
        let feed = await engine.watch(session)
        let windows = await feed.windows()
        let start = ContinuousClock.now
        await loadLatest(feed, session)
        let shown = model?.transcripts.messages[session]?.count ?? 0
        RemoteLog.log(.sync, "transcript \(session.prefix(8)) latest page in \(Launch.ms(since: start)) ms, \(shown) shown before it")
        for await window in windows {
            model?.transcripts.set(window.messages, hasEarlier: window.hasEarlier, for: session)
            saveSoon()
        }
        await engine.unwatch(session)
    }

    /// A session just started is listed before its agent writes the transcript, which 404s until then (a trust dialog
    /// can hold it for minutes).
    private func loadLatest(_ feed: TranscriptFeed, _ session: SessionKey) async {
        var wait = Duration.milliseconds(500)
        model?.transcripts.loadFailed(false, for: session)
        while !Task.isCancelled {
            do {
                try await feed.loadLatest()
                model?.transcripts.loadFailed(false, for: session)
                return
            } catch let failure as RemoteFailure where ![404, 409, 503].contains(failure.status) {
                model?.transcripts.loadFailed(true, for: session)
                return
            } catch is RemoteFailure {
                // Not written yet: it's still starting, so the page keeps waiting rather than failing.
            } catch {
                if !Task.isCancelled { model?.transcripts.loadFailed(true, for: session) }
            }
            try? await Task.sleep(for: wait)
            wait = min(wait * 2, .seconds(4))
        }
    }

    private func send(_ request: RemoteRequest, _ answer: RemoteAnswer, mode: PermissionMode?, confirm: String?) {
        sent[request.id] = nil
        Task { [engine, mac] in
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

    static func subject(_ request: RequestID, _ answer: RemoteAnswer, mode: PermissionMode?) throws -> String? {
        if let mode { return try ConfirmMessage.subject(requestID: request, allowMode: mode) }
        return try ConfirmMessage.subject(requestID: request, answer: answer)
    }

    func track(_ state: RemoteState) {
        for (session, drops) in state.queueDrops where drops != seenQueueDrops[session] {
            seenQueueDrops[session] = drops
            if state.macCan(.repliesDropped) {
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

    /// The next snapshot covers a refresh that never gets through.
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

    private func placeKeptAnswers(_ state: RemoteState, in transcripts: TranscriptStore) {
        // Only the Mac's list as it is now can say a question has closed.
        guard state.connection.isLive, state.caughtUp else { return }
        let macID = mac.endpoint.macID
        for kept in NotificationDrafts.answers(mac: macID) {
            if state.requests[kept.request] != nil {
                transcripts.drafts[kept.session] = NotificationDrafts.joined(transcripts.drafts[kept.session], kept.text)
            } else if !state.pending.contains(where: { $0.answering == kept.request }) {
                transcripts.notice("The question closed before your answer from the notification could go: \u{201C}\(kept.text.prefix(80))\u{201D}",
                                   in: kept.session)
            } else {
                continue
            }
            NotificationDrafts.dropAnswer(kept.request, mac: macID)
        }
    }

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
        guard let model else { return }
        // Before the first snapshot there's nothing finished to say, and the cache's own list stays.
        let finished = state.epoch != nil ? state.finished : StateCache.load(mac.endpoint.macID)?.finished ?? [:]
        model.cache(finished: finished).save(mac.endpoint.macID)
    }

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
        let finishedMoved = state.epoch != nil && state.finished.mapValues(\.turnID) != self.state.finished.mapValues(\.turnID)
        let restarted = self.state.epoch != nil && state.epoch != nil && state.epoch != self.state.epoch
        self.state = state
        if finishedMoved, !connected { sweepFinished(state) }
        setLive(state.connection.isLive)
        if connected {
            Launch.mark("live")
            reportPush()
            sweepNotifications()
        }
        if state.epoch != nil { Launch.mark("snapshot", "\(state.sessions.count) sessions") }
        if let hello = state.hello, hello.paired == true { mac = mac.updating(hello.endpoints, capabilities: hello.capabilities, os: hello.mac.os) }
        guard let model else { return }
        if restarted {
            model.transcripts.restarted(mac: mac.endpoint.name, receipts: Set(state.sessions.values.flatMap { $0.receipts ?? [] }.map(\.id)))
        }
        // Until the first snapshot the engine's state is empty, and the cache drawn at launch stays.
        if state.epoch != nil {
            model.sessions.replace(Array(state.sessions.values), finished: state.finished)
            model.requests.replace(state.requests) { [mac] id in state.resolved[id]?.line(thisDevice: mac.deviceID, host: mac.endpoint.kind.isMac ? "Mac" : mac.endpoint.name) }
            model.accounts.replace(Array(state.accounts.values))
            placeKeptAnswers(state, in: model.transcripts)
            saveSoon()
        }
        model.tools.apply(state)
        model.deliverWaitingReplies()
        applyConnection(state, to: model.mac)
        track(state)
        if state.connection.isLive {
            WidgetPublisher.shared.refresh()
            prefetch()
        }
    }

    private func applyConnection(_ state: RemoteState, to connection: MacConnection) {
        connection.kind = mac.endpoint.kind
        connection.apply(state, name: mac.endpoint.name,
                         onTailnet: Tailscale.isTailnet((state.address ?? mac.endpoint.baseURL).host() ?? ""), hasRelay: mac.endpoint.relay != nil)
        if state.mac != nil { MacShapes.set(portable: connection.portable, for: mac.endpoint.macID) }
        reconnectingEnds?.cancel()
        guard case .reconnecting(let since) = connection.state else { return }
        let left = since.addingTimeInterval(MacConnection.reconnectingFor(state.connection)).timeIntervalSinceNow
        reconnectingEnds = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(left, 0) + 0.1))
            guard !Task.isCancelled, let self else { return }
            applyConnection(self.state, to: connection)
        }
    }

    private func sweepNotifications() {
        let asked = Date.now
        Task { [engine, mac] in
            do { try await engine.refreshRequests() } catch { return }
            let state = await engine.state
            let open = Set(state.requests.keys).union(state.pending.compactMap(\.answering))
            await DeliveredRequests.sweep(mac: mac.endpoint.macID, open: open, asked: asked, onlyMac: PairedMac.all().count == 1,
                                          finished: state.epoch == nil ? nil : state.finished.mapValues(\.turnID))
        }
    }

    private func sweepFinished(_ state: RemoteState) {
        guard state.connection.isLive else { return }
        let asked = Date.now, finished = state.finished.mapValues(\.turnID)
        // Requests only after a fresh read: a push can come before its event.
        Task { [mac] in await DeliveredRequests.sweep(mac: mac.endpoint.macID, open: nil, asked: asked, onlyMac: false, finished: finished) }
    }

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

enum AnswerAttempt: Equatable {
    case sending(item: String, retried: Bool)
    case retrying(item: String)
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
    init(_ outcome: OutboxOutcome?, retried: Bool) {
        self = switch outcome {
        case .delivered?: .delivered
        // A retry that finds the request settled means the first attempt landed.
        case .answeredElsewhere? where retried: .delivered
        case .answeredElsewhere?: .answeredElsewhere
        // Gone after a retry isn't a refusal; the first attempt may be why.
        case .failed(let error)? where retried && error.code == .requestNotFound: .gone
        case .unknown?, .notDelivered?: .unknown
        case .failed(let error)?: .failed(error.message)
        case nil: .sending
        }
    }
}

extension RequestResolution {
    func line(thisDevice: String, host: String = "Mac") -> String {
        switch by {
        case .mac: answer == .allow ? "Allowed on \(host)" : answer == .deny ? "Denied on \(host)" : "Answered on \(host)"
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
    static func reconnectingFor(_ connection: Connection) -> TimeInterval { connection.cause == .noNetwork ? 5 : 60 }

    func apply(_ remote: RemoteState, name: String, onTailnet: Bool = true, hasRelay: Bool = false, now: Date = .now) {
        if reportedName != name { reportedName = name }
        if let mac = remote.mac {
            onPower = mac.onPower
            battery = mac.battery
            portable = mac.battery != nil
            memoryUsed = Double(mac.memoryUsed) / 1_000_000_000
            memoryTotal = Double(mac.memoryTotal) / 1_000_000_000
            keepAwake = mac.keepAwake
        }
        let next: State
        switch remote.connection {
        case .live:
            next = .live
            lastSeen = now
        case .offline(_, _, .macAsleep):
            next = .offline(.macAsleep)
        case .offline(_, _, .relayRefused):
            next = .offline(.relayRefused)
        case .idle, .connecting, .offline:
            switch state {
            case .live: next = .reconnecting(since: now)
            case .reconnecting(let since) where now.timeIntervalSince(since) < Self.reconnectingFor(remote.connection): next = state
            case .connecting where remote.connection == .connecting || remote.connection == .idle: next = .connecting
            default:
                next = remote.connection.cause == .noNetwork ? .offline(.noNetwork)
                    : .offline(vpnUp || !onTailnet || hasRelay ? .macUnreachable : .tailscaleOff)
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
