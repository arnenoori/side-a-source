import Foundation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

/// Replies typed while the Mac was out of reach: kept here unsigned, and signed and queued only once it's back.
extension ReplyFlights {
    /// A pairing that ended or a Mac to update won't come back by waiting: what's sent then queues as before.
    static func holds(_ connection: Connection) -> Bool {
        switch connection {
        case .connecting, .offline: true
        default: false
        }
    }

    static let catchUpLimit: Double = 20
    var catchingUpNotice: String { "Not sent yet: Side A Remote is still catching up with \(mac.endpoint.kind.the(mac.endpoint.name)). It sends once it has." }

    /// `since` in place of where the session stands now: a reply held again keeps the moment it was sent.
    func hold(_ body: RemoteReply, turn: String, session: SessionKey, needs: ConfirmLevel?, key: String? = nil, wire: String? = nil,
                      since: String?? = nil) {
        let flight = ReplyFlight(session: session, turn: turn, body: body, at: Date.now.timeIntervalSince1970, phase: .waiting, needs: needs,
                                 since: since ?? mark(session), key: wire)
        setFlight(flight, item: key ?? UUID().uuidString.lowercased())
    }

    /// Before the first snapshot the engine knows no session, and where one stands is what the screen showed: the row
    /// drawn from the cache, and the finished turn saved with it.
    func mark(_ session: SessionKey) -> String? {
        if state.epoch != nil { return ReplyMark.marks(state.sessions[session], state.finished[session]).first }
        if cachedFinished == nil { cachedFinished = StateCache.load(mac.endpoint.macID)?.finished ?? [:] }
        return ReplyMark.marks(model?.sessions.session(session), cachedFinished?[session]).first
    }

    func deliverWaiting() {
        guard flights.values.contains(where: { $0.phase == .waiting }) else { return }
        guard case .live(let since) = state.connection, state.epoch != nil else { return }
        // Until the replay or snapshot lands the sessions are as they were before the drop, and moved-on can't be judged.
        let (next, effects) = heldDelivery.next(.asked(caughtUp: state.caughtUp))
        heldDelivery = next
        if effects.contains(.restartTimer) {
            let left = since + Self.catchUpLimit - Date.now.timeIntervalSince1970
            catchingUp?.cancel()
            catchingUp = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(left, 0)))
                if !Task.isCancelled { self?.sayStillCatchingUp() }
            }
        }
        if effects.contains(.cancelTimer) {
            catchingUp?.cancel()
            catchingUp = nil
        }
        guard effects.contains(.deliver) else { return }
        let waiting = flights.filter { $0.value.phase == .waiting }.sorted { $0.value.at < $1.value.at }
        Task { [engine] in
            defer { heldDelivery = heldDelivery.next(.done).state }
            // One that must wait longer keeps the later ones of its session behind it, so they arrive in order.
            var blocked: Set<SessionKey> = []
            for (item, flight) in waiting where state.connection.isLive && flights[item]?.phase == .waiting {
                guard !blocked.contains(flight.session) else { continue }
                if model?.transcripts.notices[flight.session] == catchingUpNotice { model?.transcripts.notice(nil, in: flight.session) }
                if received(flight) {
                    setFlight(nil, item: item)
                    continue
                }
                if let reason = unsendable(flight) {
                    settleUnsent(item, reason: reason)
                    continue
                }
                // One that was posted goes as it went: the Mac's record checks the body under its key.
                let body = flight.key == nil ? refreshed(flight) : flight.body
                if signingLevel(body, session: flight.session, asked: flight.needs) == .biometric, !inFront {
                    blocked.insert(flight.session)
                    continue
                }
                flights[item]?.move(.send)
                setFlight(flights[item], item: item)
                let confirm: String?
                switch await signature(body, session: flight.session, level: flight.needs) {
                case .declined where !inFront:
                    flights[item]?.move(.deferred)
                    setFlight(flights[item], item: item)
                    blocked.insert(flight.session)
                    continue
                case .declined:
                    settleUnsent(item, reason: "Not confirmed.")
                    continue
                case .notRequired: confirm = nil
                case .signed(let header): confirm = header
                }
                guard let turn = flights[item]?.turn else { continue }
                // Face ID can take a while, and the session may move on meanwhile.
                if let reason = unsendable(flight) {
                    settleUnsent(item, reason: reason)
                    continue
                }
                // Gone once already without an answer: a new item, so the first one's outcome isn't read as this one's, under
                // the first one's key, which the Mac's record answers from the first attempt if that one landed.
                let key = state.outcomes[item] == nil ? item : Self.retryKey(item)
                if key != item { setFlight(nil, item: item) }
                setFlight(ReplyFlight(session: flight.session, turn: turn, body: body, at: flight.at, phase: .queued(resigned: false), needs: flight.needs,
                                      since: flight.since, queuedAt: Date.now.timeIntervalSince1970, key: flight.key),
                          item: key)
                await flightWrites?.value
                await engine.reply(flight.session, body, confirm: confirm, id: key, key: flight.key)
            }
            track(state)
        }
    }

    private func sayStillCatchingUp() {
        guard state.connection.isLive, !state.caughtUp, let transcripts = model?.transcripts else { return }
        for session in Set(flights.values.filter { $0.phase == .waiting }.map(\.session)) where transcripts.notices[session] == nil {
            transcripts.notice(catchingUpNotice, in: session)
        }
    }

    /// A held reply that was posted once and that the Mac's receipts already name went in: the receipt, applied before
    /// this, moves its bubble, and nothing goes again.
    private func received(_ flight: ReplyFlight) -> Bool {
        guard let key = flight.key, let receipts = state.sessions[flight.session]?.receipts else { return false }
        return receipts.contains { $0.answers(key) }
    }

    private func unsendable(_ flight: ReplyFlight) -> String? {
        if Date.now.timeIntervalSince1970 - flight.at > ReplyFlight.waitingLifetime {
            return "It waited too long for \(mac.endpoint.kind.the(mac.endpoint.name)). Send it again if it still fits."
        }
        let session = state.sessions[flight.session], finished = state.finished[flight.session]
        if session == nil, finished == nil { return "The session ended before this could go." }
        // Nothing on this phone showed the session when it was sent, so no turn can be told from one the person never saw.
        if flight.since == nil { return "This phone didn't know yet where the session stood when you sent this. Read it, then send it again." }
        if flight.movedOn(Set(ReplyMark.marks(session, finished))) {
            // Posted once, perhaps typed, perhaps the very thing that moved the session on: under its first key the Mac
            // replays that attempt if it landed, and otherwise refuses it by its `seen` as this would.
            if flight.key != nil, flight.body.seen != nil, state.macCan(.repliesSeen) { return nil }
            // Retry sends it under its first key, which the Mac answers from the first attempt if that one landed.
            if flight.key != nil {
                return "The session moved on while this waited, and \(mac.endpoint.kind.the(mac.endpoint.name)) may already have it. Read what it did before you retry."
            }
            return "The session moved on while this waited. Read what it did, then send it again."
        }
        return nil
    }

    /// `auto` is decided afresh, as for Retry: a request may be waiting on the session now. The turn it follows up stays,
    /// so the Mac refuses it if that turn has moved on.
    private func refreshed(_ flight: ReplyFlight) -> RemoteReply {
        let old = flight.body
        let mode = old.mode == .auto ? model?.replyMode(flight.session) ?? .auto : old.mode
        var body = RemoteReply(text: old.text, mode: mode, keys: old.keys, attachments: old.attachments, turnID: old.turnID, submit: old.submit)
        body.replaces = old.replaces
        body.seen = old.seen
        body.promotes = old.promotes
        return body
    }
}
