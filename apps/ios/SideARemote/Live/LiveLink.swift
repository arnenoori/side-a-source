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

    private struct Sent {
        var attempt: AnswerAttempt
        let session: SessionKey
        let answer: RemoteAnswer
        let mode: PermissionMode?
        /// The key that signed it: Face ID's for a destructive Allow from the sheet, else the unlock key.
        let signer: DeviceKeys.Signer
    }

    /// Replies from the tap until they settle, by outbox item, and in the outbox's file beside the item.
    @ObservationIgnored private var flights: [String: ReplyFlight] = [:]
    @ObservationIgnored private var seenQueueDrops: [SessionKey: Int] = [:]
    private let outbox: Outbox
    /// Flight writes, in order.
    @ObservationIgnored private var flightWrites: Task<Void, Never>?
    @ObservationIgnored private var takeBacks: [String: (session: SessionKey, turn: String?, keepText: Bool)] = [:]
    @ObservationIgnored private var steers: [String: SessionKey] = [:]
    /// Sessions whose waiting note this phone has seen as mail, so mail going away reads as taken.
    @ObservationIgnored private var mailSeen: [SessionKey: Date] = [:]

    private enum ReplySignature {
        case signed(String)
        /// Nothing asked for one: it goes as it is, and an older Mac takes it.
        case notRequired
        /// Asked for, and not made: Face ID was cancelled, the app is locked, or there's no key. Nothing goes.
        case declined
    }

    init(mac: PairedMac, outbox: Outbox, transport: (any Transport)? = nil) {
        self.mac = mac
        self.outbox = outbox
        engine = SyncEngine(endpoint: mac.endpoint, credentials: KeychainCredentials(), outbox: outbox, transport: transport)
    }

    deinit {
        updates?.cancel()
        path.cancel()
    }

    /// Forgotten or replaced: nothing of this link keeps running.
    func stop() {
        updates?.cancel()
        saving?.cancel()
        path.cancel()
        if PushRegistrar.shared.observers[mac.endpoint.macID] != nil { PushRegistrar.shared.observers[mac.endpoint.macID] = nil }
        Task { [engine] in await engine.stop() }
    }

    func attach(_ model: AppModel) {
        self.model = model
        let engine = engine
        model.requests.onAnswer = { [weak self] request, answer, mode, confirm in self?.send(request, answer, mode: mode, confirm: confirm) }
        model.transcripts.onRetry = { [weak self] answered in self?.retry(answered) }
        PushRegistrar.shared.observers[mac.endpoint.macID] = { [weak self] in self?.reportPush() }
        model.transcripts.onLoadEarlier = { session in Task { try? await engine.transcript(session).loadEarlier() } }
        model.transcripts.onLoadWhole = { session, seq in try await engine.message(session, seq: seq) }
        // A network change retries at once instead of waiting out the backoff (section 3).
        path.pathUpdateHandler = { [weak model] update in
            let vpn = update.availableInterfaces.contains { $0.type == .other }
            Task { @MainActor in
                model?.mac.vpnUp = vpn
                await engine.reconnectNow()
            }
        }
        path.start(queue: .global(qos: .utility))
        Task { await restoreFlights() }
        // Off the main actor, so the hello goes out now rather than once the first frames are drawn.
        Task.detached(priority: .userInitiated) { await engine.start() }
        updates = Task { [weak self] in
            for await state in engine.updates {
                guard let self else { return }
                self.apply(state)
            }
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
        let feed = await engine.transcript(session)
        await engine.setViewing(session)
        let start = ContinuousClock.now
        try? await feed.loadLatest()
        let shown = model?.transcripts.messages[session]?.count ?? 0
        RemoteLog.log(.sync, "transcript \(session.prefix(8)) latest page in \(Launch.ms(since: start)) ms, \(shown) shown before it")
        for await window in feed.updates {
            model?.transcripts.set(window.messages, hasEarlier: window.hasEarlier, for: session)
            saveSoon()
        }
        await feed.close()
        await engine.setViewing(nil)
    }

    private func send(_ request: RemoteRequest, _ answer: RemoteAnswer, mode: PermissionMode?, confirm: String?) {
        sent[request.id] = nil
        Task { [engine, mac] in
            // In the app the phone is unlocked, so the unlock key signs without asking; the Mac decides whether it needs it.
            let signer: DeviceKeys.Signer = confirm == nil ? .unlock : .confirm
            var confirm = confirm
            if confirm == nil, let subject = try? Self.subject(request.id, answer, mode: mode) {
                confirm = await DeviceKeys.header(.unlock, macID: mac.endpoint.macID, deviceID: mac.deviceID, purpose: .allow, subject: subject)
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
                confirm = await DeviceKeys.header(entry.signer, macID: mac.endpoint.macID, deviceID: mac.deviceID, purpose: .allow,
                                                  subject: subject, reason: "Allow \(RequestText.visible(answered.request.detail))")
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
            model?.transcripts.failQueued(in: session, reason: "This session ended before it could be sent.")
        }
        guard let transcripts = model?.transcripts else { return }
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
        trackSteering(state)
    }

    /// `resending` is what an earlier attempt took from the tray, in place of what's there now.
    func reply(_ text: String, turn: String, to session: SessionKey, mode: ReplyMode, submit: ReplySubmit? = nil, resending: [String]? = nil) {
        // Sending again from the field, past "Not sent · Retry": the photos that reply carried go with this one.
        let unsent = flights.filter { $0.value.session == session && $0.value.isUnsent }
        for (item, flight) in unsent {
            model?.tools.attachments.carry(from: flight.turn, to: turn)
            setFlight(nil, item: item)
        }
        let attachments = resending ?? Array(((model?.tools.attachments.take(session, for: turn) ?? []) + unsent.values.flatMap(\.body.attachments))
            .prefix(ComposerAttachments.limit))
        // A finished session takes the reply as a follow-up to its last turn.
        let body = RemoteReply(text: text, mode: mode, attachments: attachments, turnID: state.finished[session]?.turnID, submit: submit)
        fly(body, turn: turn, session: session)
    }

    /// A new flight: signed first, and in the queue only if that's settled.
    private func fly(_ body: RemoteReply, turn: String, session: SessionKey, needs: ConfirmLevel? = nil) {
        let item = UUID().uuidString.lowercased()
        setFlight(ReplyFlight(session: session, turn: turn, body: body, at: Date.now.timeIntervalSince1970, needs: needs), item: item)
        Task { [engine] in
            let signed = await signature(body, session: session, level: needs)
            guard flights[item] != nil else { return }
            let confirm: String?
            switch signed {
            case .declined: return settleUnsent(item, reason: "Not confirmed.")
            case .notRequired: confirm = nil
            case .signed(let header): confirm = header
            }
            flights[item]?.phase = .queued(resigned: false)
            setFlight(flights[item], item: item)
            await flightWrites?.value
            await engine.reply(session, body, confirm: confirm, id: item)
            track(state)
        }
    }

    /// The reply's signature, by what the session's mode asks of it here (the Mac decides again from its own), or by
    /// `level` when the Mac has said. Asked for means no send without it; a Mac without `confirmActions` asks for nothing.
    private func signature(_ body: RemoteReply, session: SessionKey, level: ConfirmLevel? = nil) async -> ReplySignature {
        let signs = state.hello?.capabilities.contains(.confirmActions) == true
        let required = level ?? (signs ? ConfirmPolicy.reply(body, sessionMode: state.sessions[session]?.settings?.mode) : nil)
        guard let subject = try? ConfirmMessage.subject(action: .reply, target: session, body: body) else {
            return required == nil ? .notRequired : .declined
        }
        let signed = await DeviceKeys.header((required ?? .unlock) == .unlock ? .unlock : .confirm, macID: mac.endpoint.macID, deviceID: mac.deviceID,
                                             purpose: .action, subject: subject, reason: "Send this reply")
        if let signed { return .signed(signed) }
        return required == nil ? .notRequired : .declined
    }

    /// An unknown or undelivered reply again under a new key; one the Mac refused goes fresh. Either way it carries what
    /// it did and signs again, since a signature is good for its moment only.
    func retry(item: String, text: String, turn: String, session: SessionKey) {
        guard var flight = flights[item] else {
            return reply(text, turn: turn, to: session, mode: model?.replyMode(session) ?? .auto)
        }
        model?.tools.attachments.carry(from: flight.turn, to: turn)
        flight.turn = turn
        switch state.outcomes[item] {
        case .unknown?, .notDelivered?:
            flight.phase = .signing
            setFlight(flight, item: item)
            Task { [engine, flight] in
                let signed = await signature(flight.body, session: session, level: flight.needs)
                let confirm: String?
                switch signed {
                case .declined: return settleUnsent(item, reason: "Not confirmed.")
                case .notRequired: confirm = nil
                case .signed(let header): confirm = header
                }
                if let again = await engine.retry(itemID: item, confirm: confirm) {
                    var queued = flight
                    queued.phase = .queued(resigned: false)
                    setFlight(nil, item: item)
                    setFlight(queued, item: again.id)
                    track(self.state)
                } else {
                    setFlight(nil, item: item)
                    refly(flight, turn: turn, session: session)
                }
            }
        default:
            setFlight(nil, item: item)
            refly(flight, turn: turn, session: session)
        }
    }

    /// A note stays a note; `auto` is decided afresh, since the session may have moved on.
    private func refly(_ flight: ReplyFlight, turn: String, session: SessionKey) {
        let body = flight.body
        let mode = body.mode == .auto ? model?.replyMode(session) ?? .auto : body.mode
        fly(RemoteReply(text: body.text, mode: mode, keys: body.keys, attachments: body.attachments, turnID: state.finished[session]?.turnID, submit: body.submit),
            turn: turn, session: session, needs: flight.needs)
    }

    /// Once more, signed as the Mac asked; cancelled, nothing goes and the reply waits for Retry at that level.
    private func resign(_ item: String, _ flight: ReplyFlight, level: ConfirmLevel, refused: APIError) {
        var waiting = flight
        waiting.phase = .resigning
        waiting.needs = level
        setFlight(waiting, item: item)
        Task { [engine, waiting] in
            guard case .signed(let confirm) = await signature(flight.body, session: flight.session, level: level) else {
                return settleUnsent(item, reason: refused.message)
            }
            let again = UUID().uuidString.lowercased()
            var queued = waiting
            queued.phase = .queued(resigned: true)
            setFlight(nil, item: item)
            setFlight(queued, item: again)
            await flightWrites?.value
            await engine.reply(flight.session, flight.body, confirm: confirm, id: again)
            track(state)
        }
    }

    /// Back into the field with "Not sent · Retry". That shows one reply per session; a turn no longer there shows none.
    private func settleUnsent(_ item: String, reason: String) {
        guard var flight = flights[item] else { return }
        for (other, earlier) in flights where other != item && earlier.session == flight.session && earlier.isUnsent {
            setFlight(nil, item: other)
        }
        flight.phase = .unsent(reason: reason)
        setFlight(flight, item: item)
        if model?.transcripts.fail(flight.turn, in: flight.session, reason: reason, item: item) == false { setFlight(nil, item: item) }
    }

    private func setFlight(_ flight: ReplyFlight?, item: String) {
        flights[item] = flight
        let previous = flightWrites
        flightWrites = Task { [outbox, mac] in
            await previous?.value
            await outbox.setFlight(flight, item: item, mac: mac.endpoint.macID)
        }
    }

    /// What a kill left: turns still in the outbox show as sending and settle as usual, and the rest wait for Retry.
    private func restoreFlights() async {
        let macID = mac.endpoint.macID
        let saved = await outbox.flights(for: macID)
        guard !saved.isEmpty, let transcripts = model?.transcripts else { return }
        let queued = Set(await outbox.items(for: macID).map(\.id))
        let settled = await engine.state.outcomes
        let now = Date.now.timeIntervalSince1970
        for (item, var flight) in saved.sorted(by: { $0.value.at < $1.value.at }) where flights[item] == nil {
            if flight.expired(now: now) {
                setFlight(nil, item: item)
                continue
            }
            let phase = flight.restored(inQueue: queued.contains(item) || settled[item] != nil)
            flight.phase = phase
            flights[item] = flight
            transcripts.adopt(flight.turn, text: flight.body.text, at: Date(timeIntervalSince1970: flight.at), to: flight.session)
            if case .unsent(let reason) = phase { settleUnsent(item, reason: reason) } else { setFlight(flight, item: item) }
        }
        track(state)
    }

    /// This Mac is forgotten: what it was sent or refused goes too.
    func forgetFlights() {
        flights = [:]
        let previous = flightWrites
        flightWrites = Task { [outbox, mac] in
            await previous?.value
            await outbox.removeFlights(for: mac.endpoint.macID)
        }
    }

    func interrupt(_ session: SessionKey, when: InterruptRequest.When) {
        Task { [engine] in
            let item = await engine.interrupt(session, when: when)
            steers[item.id] = session
            track(state)
        }
    }

    func takeBack(_ session: SessionKey, turn: String?, keepText: Bool = true) {
        Task { [engine] in
            let item = await engine.takeBack(sessionID: session)
            takeBacks[item.id] = (session, turn, keepText)
            track(state)
        }
    }

    /// Replies become sent turns or waiting notes, or go back to the field; Take Back returns a note's
    /// text; a refused steer says so under the field.
    private func trackSteering(_ state: RemoteState) {
        guard let transcripts = model?.transcripts else { return }
        for (item, flight) in flights {
            guard case .queued = flight.phase, let outcome = state.outcomes[item] else { continue }
            switch flight.next(after: outcome) {
            // The signature ran out in the queue, or the session's mode asks for more than this phone knew: once more, signed as asked.
            case .resign(let level):
                if case .failed(let error) = outcome { resign(item, flight, level: level, refused: error) }
            case .delivered(let body):
                setFlight(nil, item: item)
                let result = body.flatMap { try? JSONDecoder().decode(ReplyResult.self, from: $0) }
                if result?.delivery == .note {
                    transcripts.mark(flight.turn, in: flight.session, .note)
                    mailSeen[flight.session] = mailSeen[flight.session] ?? .distantFuture
                } else if result?.delivery == .inbox {
                    // The hook took it at once, which is as read as a note gets.
                    transcripts.mark(flight.turn, in: flight.session, .read)
                } else if result?.delivery == .queued {
                    transcripts.mark(flight.turn, in: flight.session, .queued)
                } else {
                    transcripts.mark(flight.turn, in: flight.session, .sent)
                }
            case .unsent(let reason):
                settleUnsent(item, reason: reason)
            }
        }
        for (item, back) in takeBacks {
            guard let outcome = state.outcomes[item] else { continue }
            takeBacks[item] = nil
            switch outcome {
            case .delivered:
                if let turn = back.turn { transcripts.withdraw(turn, in: back.session, restoring: back.keepText) }
            // Nothing left to take: the session read it first. An Edit keeps its text as a new message.
            case .failed(let error) where error.code == .notFound:
                if let turn = back.turn {
                    if back.keepText { transcripts.editTooLate(turn, in: back.session) }
                    transcripts.mark(turn, in: back.session, .read)
                }
            default:
                if let turn = back.turn { transcripts.mark(turn, in: back.session, .note) }
                transcripts.notice("Couldn't take it back. Try again.", in: back.session)
            }
        }
        for (item, session) in steers {
            guard let outcome = state.outcomes[item] else { continue }
            steers[item] = nil
            switch outcome {
            case .delivered, .answeredElsewhere: break
            case .failed(let error): transcripts.notice("Couldn't stop it. \(error.message)", in: session)
            case .unknown, .notDelivered: transcripts.notice("Couldn't reach the Mac to stop it.", in: session)
            }
        }
        // A note the Mac showed as mail and no longer does was read. One read before the phone ever saw
        // the mail counts after half a minute.
        for (session, seen) in mailSeen {
            guard let transcripts = model?.transcripts, let note = transcripts.pendingNote(session), note.state == .note else {
                mailSeen[session] = nil
                continue
            }
            let mail = state.sessions[session]?.mail
            if mail?.kind == .note {
                mailSeen[session] = .now
            } else if seen != .distantFuture || Date.now.timeIntervalSince(note.at) > 30 {
                transcripts.noteRead(in: session)
                mailSeen[session] = nil
            }
        }
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

    func apply(_ state: RemoteState) {
        let connected = state.connection.isLive && !self.state.connection.isLive
        self.state = state
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

extension ReplyFlight {
    var isUnsent: Bool { if case .unsent = phase { true } else { false } }
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
