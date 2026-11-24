import Foundation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import UserNotifications

/// Replies, steers and Take Backs from the tap until they settle, for one `LiveLink`, which feeds it each state.
final class ReplyFlights {
    nonisolated deinit {}

    weak var link: LiveLink?
    weak var model: AppModel?
    let engine: SyncEngine
    let mac: PairedMac

    /// Replies from the tap until they settle, by outbox item, and in the outbox's file beside the item.
    var flights: [String: ReplyFlight] = [:]
    /// Flights `restoreFlights` took while queued, perhaps by another process that settles them without this one hearing.
    private var adopted: Set<String> = []
    private let outbox: Outbox
    /// Flight writes, in order.
    var flightWrites: Task<Void, Never>?
    private var takeBacks: [String: (session: SessionKey, turn: String?, keepText: Bool)] = [:]
    private var steers: [String: (session: SessionKey, then: ((Bool) -> Void)?)] = [:]
    /// Sessions whose waiting note this phone watches in their mail, so mail going away reads as taken.
    private var noteMail: [SessionKey: NoteMail] = [:]
    /// Face ID only asks in front, so replies that waited for the Mac go from here.
    var inFront = true { didSet { if inFront { deliverWaiting() } } }
    var heldDelivery = HeldDelivery.idle
    /// `heldDelivery`'s wait for the link to catch up.
    var catchingUp: Task<Void, Never>?
    /// The cache's finished turns, read once for `mark` while the engine has none.
    var cachedFinished: [SessionKey: FinishedSession]?

    enum ReplySignature {
        case signed(String)
        /// Nothing asked for one: it goes as it is, and an older Mac takes it.
        case notRequired
        /// Asked for, and not made: Face ID was cancelled, the app is locked, or there's no key. Nothing goes.
        case declined
    }

    init(engine: SyncEngine, outbox: Outbox, mac: PairedMac) {
        self.engine = engine; self.outbox = outbox; self.mac = mac
    }

    var state: RemoteState { link?.state ?? RemoteState() }

    func track(_ state: RemoteState) { link?.track(state) }

    enum Photos {
        case fromTray
        /// What an earlier attempt took from the tray, in place of what's there now.
        case taken([String])
        /// The tray is left alone: it holds photos for the message being typed, not for a queued reply sent now.
        case none
    }

    /// `promotes`: a queued reply's id, which the Mac sends now in the same step as taking it out of the queue.
    func reply(_ text: String, turn: String, to session: SessionKey, mode: ReplyMode, submit: ReplySubmit? = nil, photos: Photos = .fromTray,
               key: String? = nil, promotes: String? = nil) {
        // An unsent reply's photos ride only on its own words sent again (never its key: the Mac answers a reused key
        // without typing). Under another message they'd go where nobody put them, so they return to the tray instead.
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = model?.transcripts.unsent[session]?.item
        var carried: [String] = [], back: [ReplyFlight] = []
        for (item, flight) in flights where flight.session == session && flight.isUnsent && item != shown {
            let theirs = flight.body.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !theirs.isEmpty, words.contains(theirs) {
                model?.tools.attachments.carry(from: flight.turn, to: turn)
                carried += flight.body.attachments
            } else {
                back.append(flight)
            }
            setFlight(nil, item: item)
        }
        let own: [String] = switch photos {
        case .fromTray: model?.tools.attachments.take(session, for: turn) ?? []
        case .taken(let ids): ids
        case .none: []
        }
        let attachments = Array((own + carried).prefix(ComposerAttachments.limit))
        for flight in back { model?.tools.attachments.giveBack(flight.body.attachments, of: flight.turn, to: session) }
        // A finished session takes the reply as a follow-up to its last turn.
        var body = RemoteReply(text: text, mode: mode, attachments: attachments, turnID: state.finished[session]?.turnID, submit: submit)
        body.seen = seen(session)
        body.promotes = promotes
        fly(body, turn: turn, session: session, key: key)
    }

    /// Where the session stands as Send is pressed, for a Mac that refuses a reply once it has moved on. An older Mac
    /// would refuse the signature over a field it doesn't decode, so it gets none.
    private func seen(_ session: SessionKey) -> String? {
        state.macCan(.repliesSeen) ? mark(session) : nil
    }


    func signingLevel(_ body: RemoteReply, session: SessionKey, asked: ConfirmLevel?) -> ConfirmLevel? {
        asked ?? (state.macCan(.confirmActions) ? ConfirmPolicy.reply(body, sessionMode: state.sessions[session]?.settings?.mode) : nil)
    }

    private func refused(_ item: String) -> Bool { if case .failed? = state.outcomes[item] { true } else { false } }

    /// Under the first attempt's family (`ReplyReceipt.family`), which the Mac answers from that attempt if it typed it.
    static func retryKey(_ item: String) -> String {
        ReplyReceipt.retry(of: ReplyReceipt.family(item), Int64(Date.now.timeIntervalSince1970 * 1000))
    }

    /// A new flight: signed first, and in the queue only if that's settled. Behind a held reply to the same session it is
    /// held too, so the two arrive in the order they were sent. `key` is the item; `wire`, an earlier attempt's key it goes
    /// under, `body` being that attempt's.
    private func fly(_ body: RemoteReply, turn: String, session: SessionKey, needs: ConfirmLevel? = nil, key: String? = nil, wire: String? = nil) {
        if Self.holds(state.connection) || flights.values.contains(where: { $0.session == session && $0.phase == .waiting }) {
            return hold(body, turn: turn, session: session, needs: needs, key: key, wire: wire)
        }
        let item = key ?? UUID().uuidString.lowercased()
        setFlight(ReplyFlight(session: session, turn: turn, body: body, at: Date.now.timeIntervalSince1970, needs: needs, since: mark(session),
                              key: wire),
                  item: item)
        Task { [engine] in
            let signed = await signature(body, session: session, level: needs)
            guard flights[item] != nil else { return }
            let confirm: String?
            switch signed {
            case .declined: return settleUnsent(item, reason: "Not confirmed.")
            case .notRequired: confirm = nil
            case .signed(let header): confirm = header
            }
            flights[item]?.move(.signed)
            flights[item]?.queuedAt = Date.now.timeIntervalSince1970
            setFlight(flights[item], item: item)
            await flightWrites?.value
            await engine.reply(session, body, confirm: confirm, id: item, key: wire)
            track(state)
        }
    }

    /// The reply's signature, by what the session's mode asks of it here (the Mac decides again from its own), or by
    /// `level` when the Mac has said. Asked for means no send without it; a Mac without `confirmActions` asks for nothing.
    func signature(_ body: RemoteReply, session: SessionKey, level: ConfirmLevel? = nil) async -> ReplySignature {
        if model?.tools.needsKeys == true { return .notRequired }
        let required = signingLevel(body, session: session, asked: level)
        guard let subject = try? ConfirmMessage.subject(action: .reply, target: session, body: body) else {
            return required == nil ? .notRequired : .declined
        }
        let signed = await mac.sign((required ?? .unlock) == .unlock ? .unlock : .confirm, purpose: .action, subject: subject, reason: "Send this reply")
        if let signed { return .signed(signed) }
        return required == nil ? .notRequired : .declined
    }

    /// It carries what it did and signs again, since a signature is good for its moment only.
    func retry(item: String, text: String, turn: String, session: SessionKey) {
        guard var flight = flights[item] else {
            return reply(text, turn: turn, to: session, mode: model?.replyMode(session) ?? .auto, key: refused(item) ? nil : Self.retryKey(item))
        }
        model?.tools.attachments.carry(from: flight.turn, to: turn)
        flight.turn = turn
        // Queued once, it may have been typed with the answer lost: only its own key lets the Mac's record replay that.
        let wire = flight.queuedAt == nil ? nil : flight.key ?? item
        let outcome = state.outcomes[item]
        switch outcome {
        // Joined with others (`joined`), it is new words, never queued as they are: under no earlier key.
        case .unknown? where flight.queuedAt != nil, .notDelivered? where flight.queuedAt != nil:
            flight.move(.send)
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
                    queued.move(.signed)
                    queued.since = mark(session)
                    queued.queuedAt = Date.now.timeIntervalSince1970
                    queued.key = again.key
                    setFlight(nil, item: item)
                    setFlight(queued, item: again.id)
                    track(self.state)
                } else if outcome == .notDelivered, let wire {
                    setFlight(nil, item: item)
                    fly(flight.body, turn: turn, session: session, needs: flight.needs, key: Self.retryKey(item), wire: wire)
                } else {
                    setFlight(nil, item: item)
                    refly(flight, turn: turn, session: session, key: Self.retryKey(item))
                }
            }
        case .failed?:
            setFlight(nil, item: item)
            refly(flight, turn: turn, session: session)
        // No outcome here (a relaunch, aged out, or another process sent it): whether the first landed isn't known.
        default:
            setFlight(nil, item: item)
            if let wire {
                fly(flight.body, turn: turn, session: session, needs: flight.needs, key: Self.retryKey(item), wire: wire)
            } else {
                refly(flight, turn: turn, session: session, key: Self.retryKey(item))
            }
        }
    }

    /// A note stays a note; `auto` is decided afresh, since the session may have moved on.
    private func refly(_ flight: ReplyFlight, turn: String, session: SessionKey, key: String? = nil) {
        let body = flight.body
        let mode = body.mode == .auto ? model?.replyMode(session) ?? .auto : body.mode
        var again = RemoteReply(text: body.text, mode: mode, keys: body.keys, attachments: body.attachments, turnID: state.finished[session]?.turnID,
                                submit: body.submit)
        again.seen = seen(session)
        again.promotes = body.promotes
        fly(again, turn: turn, session: session, needs: flight.needs, key: key)
    }

    /// Once more, signed as the Mac asked; cancelled, nothing goes and the reply waits for Retry at that level.
    private func resign(_ item: String, _ flight: ReplyFlight, level: ConfirmLevel, refused: APIError) {
        if model?.tools.needsKeys == true { return settleUnsent(item, reason: "Pair this \(ThisDevice.kind) again to do this from it.") }
        if level == .biometric, !inFront {
            setFlight(nil, item: item)
            return hold(flight.body, turn: flight.turn, session: flight.session, needs: level, wire: flight.key, since: flight.since)
        }
        var waiting = flight
        waiting.move(.resign)
        waiting.needs = level
        setFlight(waiting, item: item)
        Task { [engine, waiting] in
            guard case .signed(let confirm) = await signature(flight.body, session: flight.session, level: level) else {
                return settleUnsent(item, reason: refused.message)
            }
            let again = UUID().uuidString.lowercased()
            var queued = waiting
            queued.move(.signed)
            queued.queuedAt = Date.now.timeIntervalSince1970
            setFlight(nil, item: item)
            setFlight(queued, item: again)
            await flightWrites?.value
            await engine.reply(flight.session, flight.body, confirm: confirm, id: again, key: flight.key)
            track(state)
        }
    }

    /// Back into the field with "Not sent · Retry". That shows one reply per session; a turn no longer there shows none.
    /// Away from the app, a notification says so, since a reply sent from one may have waited hours for this.
    func settleUnsent(_ item: String, reason: String, tell: Bool = true) {
        guard var flight = flights[item] else { return }
        if tell, !inFront { Self.notifyUnsent(flight, reason: reason, mac: mac.endpoint.macID, title: state.sessions[flight.session]?.title) }
        let earlier = flights.filter { $0.key != item && $0.value.session == flight.session && $0.value.isUnsent }
            .sorted { $0.value.at < $1.value.at }
        for (other, _) in earlier { setFlight(nil, item: other) }
        // Joined, they go again as one new message under a new key, which can't replay an earlier one that landed.
        let mayHave = ([(item, flight)] + earlier).contains { $0.1.queuedAt != nil && !refused($0.0) }
        let said = !earlier.isEmpty && mayHave
            ? reason + " Some of it may have reached \(mac.endpoint.kind.the(mac.endpoint.name)) already: check the session before sending it again." : reason
        flight = Self.joined(flight, after: earlier.map(\.value))
        flight.move(.unsent(reason: said))
        setFlight(flight, item: item)
        if model?.transcripts.fail(flight.turn, in: flight.session, reason: said, item: item, joining: earlier.map(\.value.body.text)) == false {
            setFlight(nil, item: item)
        }
    }

    /// The session shows one unsent reply, so a second failure carries the first's words and photos rather than dropping them.
    static func joined(_ flight: ReplyFlight, after earlier: [ReplyFlight]) -> ReplyFlight {
        guard !earlier.isEmpty else { return flight }
        let body = flight.body
        let text = (earlier.map(\.body.text) + [body.text]).joined(separator: "\n\n")
        let attachments = (earlier.flatMap(\.body.attachments) + body.attachments).prefix(ComposerAttachments.limit)
        let joined = RemoteReply(text: text, mode: body.mode, keys: body.keys, attachments: Array(attachments), turnID: body.turnID, submit: body.submit)
        // No earlier key: the Mac's record refuses other words under one.
        return ReplyFlight(session: flight.session, turn: flight.turn, body: joined, at: flight.at, phase: flight.phase, needs: flight.needs,
                           since: flight.since)
    }

    func setFlight(_ flight: ReplyFlight?, item: String) {
        flights[item] = flight
        let previous = flightWrites
        flightWrites = Task { [outbox, mac] in
            await previous?.value
            await outbox.setFlight(flight, item: item, mac: mac.endpoint.macID)
        }
    }

    /// What a kill left: turns still in the outbox show as sending and settle as usual, and the rest wait for Retry.
    func restoreFlights() async {
        let macID = mac.endpoint.macID
        let saved = await outbox.flights(for: macID)
        guard let transcripts = model?.transcripts else { return }
        let queued = Set(await outbox.items(for: macID).map(\.id))
        let settled = await engine.state.outcomes
        let now = Date.now.timeIntervalSince1970
        // Taken from the file while another process (a notification's Reply) was still sending it. That process has
        // since held or settled it and nothing here hears of it, so it is read again rather than left Sending for good.
        for item in adopted {
            guard let known = flights[item], case .queued = known.phase else {
                adopted.remove(item)
                continue
            }
            guard settled[item] == nil, !queued.contains(item), saved[item]?.phase != known.phase else { continue }
            flights[item] = nil
            adopted.remove(item)
            if saved[item] == nil { transcripts.discard(known.turn, in: known.session) }
        }
        for (item, var flight) in saved.sorted(by: { $0.value.at < $1.value.at }) where flights[item] == nil {
            if flight.expired(now: now) {
                setFlight(nil, item: item)
                continue
            }
            let before = flight.phase
            flight.move(.restored(inQueue: queued.contains(item) || settled[item] != nil))
            let phase = flight.phase, changed = phase != before
            flights[item] = flight
            if case .queued = phase, settled[item] == nil { adopted.insert(item) }
            transcripts.adopt(flight.turn, text: flight.body.text, at: Date(timeIntervalSince1970: flight.at), to: flight.session)
            // Written back only when it changed, so a newer phase the other process wrote meanwhile isn't overwritten.
            if case .unsent(let reason) = phase { settleUnsent(item, reason: reason, tell: false) } else if changed { setFlight(flight, item: item) }
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

    /// `then` hears whether the Mac took it, once it has answered: Interrupt and Send queues its reply only after that.
    func interrupt(_ session: SessionKey, when: InterruptRequest.When, send: Bool = false, resend: Bool = false, then: ((Bool) -> Void)? = nil) {
        Task { [engine] in
            let item = await engine.interrupt(session, when: when, send: send, resend: resend)
            steers[item.id] = (session, then)
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
    func trackSteering(_ state: RemoteState) {
        guard let transcripts = model?.transcripts else { return }
        for (item, flight) in flights {
            transcripts.bind(flight.turn, item: item, in: flight.session)
            guard case .queued = flight.phase, let outcome = state.outcomes[item] else { continue }
            switch flight.next(after: outcome) {
            // The signature ran out in the queue, or the session's mode asks for more than this phone knew: once more, signed as asked.
            case .resign(let level):
                if case .failed(let error) = outcome { resign(item, flight, level: level, refused: error) }
            case .delivered(let body):
                setFlight(nil, item: item)
                // A Stop can still give it back, and its photos with it.
                transcripts.keepPhotos(flight.body.attachments, on: flight.turn, in: flight.session)
                if flight.body.promotes != nil { transcripts.dropQueued(flight.body.text, in: flight.session) }
                let delivery = body.flatMap { try? JSONDecoder().decode(ReplyResult.self, from: $0) }?.delivery ?? .typed
                if let stage = delivery.stage { transcripts.mark(flight.turn, in: flight.session, stage) }
                if delivery == .note { noteMail[flight.session] = (noteMail[flight.session] ?? .unwatched).next(.delivered).state }
            case .unsent where flight.unanswered(outcome, now: Date.now.timeIntervalSince1970):
                // Posted, so perhaps typed: whenever it goes again, it goes under this key.
                var held = flight
                held.move(.unanswered)
                held.key = flight.key ?? item
                setFlight(held, item: item)
            case .unsent(let reason):
                // A queued reply the Mac wouldn't send now is still queued there, or already gone: its words aren't the field's.
                if flight.body.promotes != nil, case .failed(let error) = outcome {
                    setFlight(nil, item: item)
                    model?.sendNowRefused(flight.turn, in: flight.session, error)
                } else {
                    settleUnsent(item, reason: reason)
                }
            }
        }
        // Before the held ones go: one the Mac's receipt already names isn't sent again or given back.
        for (session, row) in state.sessions {
            if let receipts = row.receipts, transcripts.apply(receipts, in: session) { model?.stopGaveBack(session) }
        }
        deliverWaiting()
        for (item, back) in takeBacks {
            guard let outcome = state.outcomes[item] else { continue }
            takeBacks[item] = nil
            switch ReplyProgress.Event.takeBack(answered: outcome) {
            case .takenBack:
                if let turn = back.turn { transcripts.withdraw(turn, in: back.session, restoring: back.keepText) }
            // An Edit keeps its text as a new message.
            case .tooLate:
                if let turn = back.turn {
                    if back.keepText { transcripts.editTooLate(turn, in: back.session) }
                    transcripts.mark(turn, in: back.session, .read)
                }
            default:
                if let turn = back.turn { transcripts.mark(turn, in: back.session, .note) }
                transcripts.notice("Couldn't take it back. Try again.", in: back.session)
            }
        }
        for (item, steer) in steers {
            guard let outcome = state.outcomes[item] else { continue }
            steers[item] = nil
            let answer = InterruptAnswer(outcome)
            if let notice = answer.notice { transcripts.notice(notice, in: steer.session) }
            steer.then?(answer == .stopped)
        }
        // A note the Mac showed as mail and no longer does was read. One read before the phone ever saw
        // the mail counts after half a minute.
        for (session, watch) in noteMail {
            let event: NoteMail.Event = if let note = model?.transcripts.pendingNote(session), note.state == .note {
                state.sessions[session]?.mail?.kind == .note ? .mailShown : .mailAbsent(age: Date.now.timeIntervalSince(note.at))
            } else {
                .noteGone
            }
            let next = watch.next(event)
            if next.read { model?.transcripts.noteRead(in: session) }
            noteMail[session] = next.state == .unwatched ? nil : next.state
        }
    }
}

extension ReplyFlight {
    var isUnsent: Bool { if case .unsent = phase { true } else { false } }
}

extension ReplyFlights {
    /// Its tap opens the session's composer, where the words are.
    static func notifyUnsent(_ flight: ReplyFlight, reason: String, mac: String, title: String?) {
        let content = UNMutableNotificationContent()
        content.title = title ?? "Reply not sent"
        content.body = "Didn't send \u{201C}\(String(flight.body.text.prefix(120)))\u{201D}. \(reason)"
        content.threadIdentifier = flight.session
        let payload = PushPayload(t: PushKind.health.rawValue, mac: mac, sent: Date.now.timeIntervalSince1970, sid: flight.session, title: title)
        content.userInfo = ["p": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))) ?? [:], AppDelegate.composeKey: true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "unsent-" + flight.session, content: content, trigger: nil))
    }
}
