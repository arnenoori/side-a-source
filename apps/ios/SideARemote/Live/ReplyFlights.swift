import Foundation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

/// Replies, steers and Take Backs from the tap until they settle, for one `LiveLink`, which feeds it each state.
final class ReplyFlights {
    nonisolated deinit {}

    weak var link: LiveLink?
    weak var model: AppModel?
    private let engine: SyncEngine
    private let mac: PairedMac

    /// Replies from the tap until they settle, by outbox item, and in the outbox's file beside the item.
    private var flights: [String: ReplyFlight] = [:]
    private let outbox: Outbox
    /// Flight writes, in order.
    private var flightWrites: Task<Void, Never>?
    private var takeBacks: [String: (session: SessionKey, turn: String?, keepText: Bool)] = [:]
    private var steers: [String: (session: SessionKey, then: ((Bool) -> Void)?)] = [:]
    /// Sessions whose waiting note this phone has seen as mail, so mail going away reads as taken.
    private var mailSeen: [SessionKey: Date] = [:]

    private enum ReplySignature {
        case signed(String)
        /// Nothing asked for one: it goes as it is, and an older Mac takes it.
        case notRequired
        /// Asked for, and not made: Face ID was cancelled, the app is locked, or there's no key. Nothing goes.
        case declined
    }

    init(engine: SyncEngine, outbox: Outbox, mac: PairedMac) {
        self.engine = engine; self.outbox = outbox; self.mac = mac
    }

    private var state: RemoteState { link?.state ?? RemoteState() }

    private func track(_ state: RemoteState) { link?.track(state) }

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
        if model?.tools.needsKeys == true { return .notRequired }
        let signs = state.hello?.capabilities.contains(.confirmActions) == true
        let required = level ?? (signs ? ConfirmPolicy.reply(body, sessionMode: state.sessions[session]?.settings?.mode) : nil)
        guard let subject = try? ConfirmMessage.subject(action: .reply, target: session, body: body) else {
            return required == nil ? .notRequired : .declined
        }
        let signed = await mac.sign((required ?? .unlock) == .unlock ? .unlock : .confirm, purpose: .action, subject: subject, reason: "Send this reply")
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
        if model?.tools.needsKeys == true { return settleUnsent(item, reason: "Pair this iPhone again to do this from it.") }
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
    func restoreFlights() async {
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

    /// `then` hears whether the Mac took it, once it has answered: Interrupt and Send queues its reply only after that.
    func interrupt(_ session: SessionKey, when: InterruptRequest.When, then: ((Bool) -> Void)? = nil) {
        Task { [engine] in
            let item = await engine.interrupt(session, when: when)
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
        for (item, steer) in steers {
            guard let outcome = state.outcomes[item] else { continue }
            steers[item] = nil
            switch outcome {
            case .delivered, .answeredElsewhere: steer.then?(true)
            case .failed(let error):
                transcripts.notice("Couldn't stop it. \(error.message)", in: steer.session)
                steer.then?(false)
            case .unknown, .notDelivered:
                transcripts.notice("Couldn't reach the Mac to stop it.", in: steer.session)
                steer.then?(false)
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
}

extension ReplyFlight {
    var isUnsent: Bool { if case .unsent = phase { true } else { false } }
}
