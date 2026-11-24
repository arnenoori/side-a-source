import Foundation
import Observation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

/// A reply typed while the Mac is out of reach waits on the phone and goes once it is back: Send, the line under the
/// field and the bubble all say so in these words.
enum SendsWhenConnected {
    static let line = "Sends when connected"
    static let action = "Send When Connected"
    static let symbol = "tray.and.arrow.up"
}

/// How Send delivers a message to a session mid-turn: the control beside Send, and its long-press.
enum Delivery: Hashable, CaseIterable {
    /// Into the running turn: Codex, through its shared server or typed into a Side A terminal.
    case steer
    /// Read before the agent's next step: Claude's typed input, or a note its hooks read.
    case nextStep
    /// Once the turn ends.
    case afterTurn
    /// The turn stopped, then the message as the next prompt.
    case interrupt

    var title: String {
        switch self {
        case .steer: "Steer Now"
        case .nextStep: "Send at Next Step"
        case .afterTurn: "Send After This Turn"
        case .interrupt: "Interrupt and Send"
        }
    }

    var symbol: String {
        switch self {
        case .steer: "arrow.up"
        case .nextStep: "clock"
        case .afterTurn: "text.append"
        case .interrupt: "stop.circle"
        }
    }

    /// One word, for the control beside Send.
    var shortTitle: String {
        switch self {
        case .steer: "Steer"
        case .nextStep: "Next"
        case .afterTurn: "Queue"
        case .interrupt: "Interrupt"
        }
    }
}

extension Delivery {
    /// Under each way to send in Send's menus, in the bubble's words for when the agent reads it.
    var hint: String {
        switch self {
        case .steer, .nextStep: "Read after the current step"
        case .afterTurn: "Read after this turn"
        case .interrupt: "Stops the current step, then sends"
        }
    }

    /// The empty field mid-turn: what Send will do, short enough not to be cut off.
    var placeholder: String {
        switch self {
        case .steer, .nextStep: "Send after this step"
        case .afterTurn: "Send after this turn"
        case .interrupt: "Interrupt, then send"
        }
    }
}

/// The delivery picked for each session's running turn; Send uses it until the turn ends.
@MainActor @Observable
final class DeliveryChoices {
    nonisolated deinit {}

    private struct Pick { let delivery: Delivery; let turn: String? }
    private var picks: [SessionKey: Pick] = [:]

    func pick(_ delivery: Delivery, for session: SessionKey, turn: String?) {
        picks[session] = Pick(delivery: delivery, turn: turn)
    }

    /// The pick for this turn, if it is still one of the `offered` ways to send.
    func picked(for session: SessionKey, turn: String?, offered: [Delivery]) -> Delivery? {
        guard let pick = picks[session], pick.turn == turn, offered.contains(pick.delivery) else { return nil }
        return pick.delivery
    }

    func clear(_ session: SessionKey) { picks[session] = nil }
}

/// Replies, notes, interrupts and Take Back (sections 4.4 and 4.14). Live they leave through the
/// link's outbox; the demo plays the Mac's side locally so every state can be seen.
extension AppModel {
    /// The composer's send: `mode: auto`, so the Mac's delivery table decides what it becomes. A
    /// second note while one waits travels with it, since the Mac keeps one note per session.
    /// `mode` overrides that, for a delivery picked from Send's long-press.
    func reply(_ text: String, to session: SessionKey, mode: ReplyMode? = nil, submit: ReplySubmit? = nil) {
        if (mode ?? predictedMode(session)) == .note, let waiting = transcripts.pendingNote(session), waiting.state == .note,
           let combined = transcripts.merge(text, into: waiting.id, in: session) {
            deliver(combined, turn: waiting.id, to: session, mode: .note)
            return
        }
        let turn = transcripts.send(text, to: session)
        // `auto` to a session with an open request is 409 `session_waiting`; only a note gets through (`replyMode`).
        deliver(text, turn: turn.id, to: session, mode: mode ?? replyMode(session), submit: submit)
    }

    /// The ways Send's long-press offers to deliver a message mid-turn, as the Mac's delivery table and the session's
    /// abilities allow; empty when it isn't working.
    func deliveries(_ id: SessionKey) -> [Delivery] {
        guard let session = sessions.session(id), session.status == .working || session.status == .starting, !waiting(id) else { return [] }
        let abilities = session.abilities
        var deliveries: [Delivery] = []
        if abilities.contains(.replyTerminal) {
            // Codex's shared server: a reply steers the turn, or waits in Codex's own queue.
            deliveries.append(.steer)
            if abilities.contains(.followUp) { deliveries.append(.afterTurn) }
        } else if session.hosted != nil {
            // Hosted Claude reads typed input at its next step. Hosted Codex steers on Enter and queues on Tab; a Mac
            // before 0.5.52 refuses it a reply mid-turn and lists no `followUp`.
            if session.agent == .claude {
                deliveries.append(.nextStep)
                if abilities.contains(.followUp) { deliveries.append(.afterTurn) }
            } else if abilities.contains(.followUp) {
                deliveries += [.steer, .afterTurn]
            }
        } else {
            // Outside Side A's terminals: a note the hooks read at the next step, or Claude's Stop waiter at the turn's end.
            if abilities.contains(.note) { deliveries.append(.nextStep) }
            if session.agent == .claude, abilities.contains(.followUp) { deliveries.append(.afterTurn) }
        }
        if stopGivesBack(session) { deliveries.append(.interrupt) }
        return deliveries
    }

    /// Esc in a hosted terminal, or Codex's turn interrupt, which give back what the agent hadn't read. Unhosted Claude has
    /// only stop mail, which waits for the next step and gives nothing back.
    func stopGivesBack(_ session: RemoteSession) -> Bool {
        session.abilities.contains(.interrupt) && (session.hosted != nil || session.abilities.contains(.replyTerminal))
    }

    /// A control to pick the delivery shows only when there is more than one way to send.
    static func offersChoice(_ offered: [Delivery]) -> Bool { offered.count > 1 }

    /// What Send does now: the pick for this turn, else the first the Mac offers (what a plain tap becomes). Nil when
    /// there is no choice to make.
    func delivery(_ id: SessionKey) -> Delivery? {
        let offered = deliveries(id)
        guard Self.offersChoice(offered) else { return nil }
        return pickedDelivery(id) ?? offered.first
    }

    /// What a plain Send does with a message mid-turn, as the field's placeholder says it: the delivery Send uses, or with
    /// no choice to make, what the Mac's table does with the one way offered. Interrupt and Send is never that: a plain
    /// Send doesn't stop the turn, so only a pick sends it.
    func sendsAs(_ id: SessionKey) -> Delivery? {
        delivery(id) ?? deliveries(id).first.flatMap { $0 == .interrupt ? nil : $0 }
    }

    /// The delivery picked for this turn; nil sends as the Mac's delivery table decides.
    func pickedDelivery(_ id: SessionKey) -> Delivery? {
        deliveryChoices.picked(for: id, turn: sessions.session(id)?.turnID, offered: deliveries(id))
    }

    func chooseDelivery(_ delivery: Delivery, for id: SessionKey) {
        deliveryChoices.pick(delivery, for: id, turn: sessions.session(id)?.turnID)
    }

    /// A steer from the stop button, the toolbar or a row; `note` opens the field for a message.
    func steer(_ steer: Steer, _ id: SessionKey, note: () -> Void) {
        switch steer {
        case .interruptNow: interrupt(id)
        case .stopBeforeNextStep: interrupt(id, when: .nextStep)
        case .note: note()
        }
    }

    /// A delivery picked from the delivery control or Send's long-press.
    func send(_ text: String, to id: SessionKey, as delivery: Delivery) {
        switch delivery {
        case .steer: reply(text, to: id, submit: .steer)
        case .nextStep:
            // Codex outside a terminal takes only a note; Claude's `auto` already comes to a note, or to typed input.
            if sessions.session(id)?.agent == .claude { reply(text, to: id) } else { note(text, to: id) }
        case .afterTurn:
            if reachesTerminal(id) { reply(text, to: id, submit: .queue) } else { reply(text, to: id, mode: .followUp) }
        case .interrupt: interruptAndSend(text, to: id)
        }
    }

    /// Stops the turn, then sends the message as the next prompt. The reply leaves only once the Mac has taken the
    /// interrupt, so it never arrives first; a failed interrupt sends nothing and puts the text back in the field.
    func interruptAndSend(_ text: String, to id: SessionKey) {
        transcripts.notice(nil, in: id)
        stopResends.cancel(id)
        let turn = transcripts.send(text, to: id)
        guard let link else {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                _ = tools.attachments.take(id, for: turn.id)
                transcripts.mark(turn.id, in: id, .sent)
            }
            return
        }
        // The tray as Send was pressed: by the time the stop is answered it may hold photos for another message.
        let photos = tools.attachments.take(id, for: turn.id)
        link.flights.interrupt(id, when: .now, send: true) { [weak self, weak link] stopped in
            guard let self else { return }
            guard stopped else {
                transcripts.withdraw(turn.id, in: id)
                tools.attachments.giveBack(photos, of: turn.id, to: id)
                return
            }
            transcripts.carry(in: id, with: turn.id)
            Task { @MainActor in
                await self.turnEnded(id)
                link?.flights.reply(text, turn: turn.id, to: id, mode: self.replyMode(id), photos: .taken(photos))
            }
        }
    }

    /// Interrupt and Send on a message the agent is taking long to read. The stop gives it back unread, and it goes
    /// again as the next prompt; a stop that gives nothing back (the agent read it meanwhile) sends nothing.
    /// What comes back is sent only for this stop: a later plain Stop's give-back is the person's to send or not.
    /// A Mac with `interrupt.resend` sends it again itself, as Interrupt and Send carries what its stop took back: no
    /// round trip through this phone, which on Codex would have to guess when the stopped turn ended.
    func interruptAndResend(_ id: SessionKey) {
        if let link, tools.can(.interruptResend) {
            transcripts.notice(nil, in: id)
            stopResends.cancel(id)
            link.flights.interrupt(id, when: .now, resend: true)
            return
        }
        let pressed = Date.now
        interrupt(id) { [weak self] stopped in
            guard let self else { return }
            Task { @MainActor in
                if stopped { try? await Task.sleep(for: StopResends.afterAnswer) }
                self.stopResends.answered(id, pressedAt: pressed)
            }
        }
        stopResends.press(id, at: pressed)
    }

    /// A Stop gave the session's replies back unread, their text now in `unsent`.
    func stopGaveBack(_ id: SessionKey) {
        guard stopResends.gaveBack(id) else { return }
        Task { @MainActor in
            await turnEnded(id)
            retryUnsent(id)
        }
    }

    /// Codex takes a message as a new prompt only once the Mac sees its turn over; Claude's terminal takes it at once.
    private func turnEnded(_ id: SessionKey, within: Duration = .seconds(InterruptTiming.phoneWaits)) async {
        guard sessions.session(id)?.agent == .codex else { return }
        let deadline = ContinuousClock.now + within
        while sessions.session(id)?.status == .working, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// `auto`, or while a request waits on the session, what it can still take.
    func replyMode(_ session: SessionKey) -> ReplyMode { waiting(session) ? predictedMode(session) : .auto }

    /// Replies that waited for Continue go once their session is listed hosted, whatever page is open; the view
    /// does the same as it watches.
    func deliverWaitingReplies() {
        for name in transcripts.waitingReplies.keys {
            guard let session = sessions.sessions.first(where: { $0.hosted == name }), let text = transcripts.takeWaitingReply(name) else { continue }
            reply(text, to: session.id)
        }
    }

    /// Idle in a terminal Side A doesn't host, with nothing there to take a reply: the Mac refuses one (`continueOnPhone`),
    /// so the composer's send moves it into Side A's tmux first, then types it there.
    func needsContinue(_ id: SessionKey) -> Bool {
        guard let session = sessions.session(id), session.hosted == nil, session.status == .idle, !session.headless else { return false }
        if !session.abilities.isDisjoint(with: [.replyTerminal, .replyInbox, .replyTyped]) { return false }
        return session.abilities.contains(.continueOnPhone) && tools.can(.continueOnPhone)
    }

    /// A Codex session in a terminal Side A reaches through Codex's shared server: a reply shows there as
    /// the user's message, steering a turn or starting one.
    func reachesTerminal(_ id: SessionKey) -> Bool {
        sessions.session(id)?.abilities.contains(.replyTerminal) == true
    }

    /// A Claude session in a terminal Side A doesn't host, finished or idle: a reply reaches it through its Stop hook or
    /// its inbox, which Claude reads as a note rather than the user's own words.
    func arrivesAsNote(_ id: SessionKey) -> Bool {
        guard let session = sessions.session(id), session.agent == .claude, session.hosted == nil else { return false }
        return session.abilities.contains(.replyInbox) || session.status == .finished && session.abilities.contains(.followUp)
    }

    /// A Codex session outside Side A's panes and outside Codex's shared server: what's sent waits for it to finish.
    func outsideSharedServer(_ id: SessionKey) -> Bool {
        guard let session = sessions.session(id) else { return false }
        return tools.can(.replyTerminal) && session.agent == .codex && session.hosted == nil && session.abilities.isDisjoint(with: [.replyTerminal, .replyTyped])
    }

    /// The reply Codex or Claude dropped, in full when this phone still has it; the flag quotes only its first
    /// 80 characters, «Didn't reach Codex: “…”». `complete` is false when only that cut quote is known.
    func droppedReply(_ id: SessionKey) -> (text: String, complete: Bool, turn: String?)? {
        guard let flag = sessions.session(id)?.flag, flag.kind == .unsent,
              let open = flag.text.firstIndex(where: { $0 == "\u{201C}" || $0 == "\"" }),
              let close = flag.text.lastIndex(where: { $0 == "\u{201D}" || $0 == "\"" }), open < close else { return nil }
        var quoted = String(flag.text[flag.text.index(after: open)..<close])
        let cut = quoted.hasSuffix("…") || quoted.count >= Self.unsentQuote
        if quoted.hasSuffix("…") { quoted.removeLast() }
        // A dropped steer never shows in the transcript, so this phone's own turn still holds it.
        if let turn = transcripts.outgoing[id]?.last(where: { $0.text.hasPrefix(quoted) }) { return (turn.text, true, turn.id) }
        return (quoted, !cut, nil)
    }

    /// How much of a dropped reply the Mac quotes.
    static let unsentQuote = 80

    /// Retry for a dropped reply: the full text goes again, and the turn that didn't arrive leaves; a cut quote
    /// goes back into the field to finish first.
    func retryDropped(_ id: SessionKey) {
        guard let dropped = droppedReply(id) else { return }
        if let turn = dropped.turn { transcripts.withdraw(turn, in: id, restoring: false) }
        if dropped.complete {
            reply(dropped.text, to: id)
        } else {
            transcripts.drafts[id] = dropped.text
        }
    }

    /// The note sheet's send: always a note, whatever the session is doing.
    func note(_ text: String, to session: SessionKey) {
        if let waiting = transcripts.pendingNote(session), waiting.state == .note,
           let combined = transcripts.merge(text, into: waiting.id, in: session) {
            deliver(combined, turn: waiting.id, to: session, mode: .note)
            return
        }
        let turn = transcripts.send(text, to: session)
        deliver(text, turn: turn.id, to: session, mode: .note)
    }

    /// "Not sent · Retry": the same item again under a new key, or when the Mac refused it, again with what it carried.
    func retryUnsent(_ session: SessionKey) {
        guard let unsent = transcripts.unsent[session] else { return }
        transcripts.clearUnsent(session)
        if transcripts.drafts[session] == unsent.text { transcripts.drafts[session] = "" }
        if let link, let item = unsent.item {
            let turn = transcripts.send(unsent.text, to: session)
            link.flights.retry(item: item, text: unsent.text, turn: turn.id, session: session)
        } else {
            reply(unsent.text, to: session)
        }
    }

    /// `then` hears whether the Mac took it.
    func interrupt(_ session: SessionKey, when: InterruptRequest.When = .now, then: ((Bool) -> Void)? = nil) {
        transcripts.notice(nil, in: session)
        stopResends.cancel(session)
        if let link { link.flights.interrupt(session, when: when, then: then); return }
        guard let current = sessions.session(session) else { return }
        // The demo's Mac: Esc stops a hosted session at once; anything else leaves stop mail.
        if when == .now && current.hosted != nil { return }
        sessions.setMail(MailState(kind: .stop, at: Date.now.timeIntervalSince1970), for: session)
    }

    /// Withdraws the waiting note or stop. A note this phone left comes back into the field (Edit), or goes (Delete).
    func takeBack(_ session: SessionKey, keepText: Bool = true) {
        transcripts.notice(nil, in: session)
        let note = transcripts.pendingNote(session)
        if let note { transcripts.mark(note.id, in: session, .takingBack) }
        if let link { link.flights.takeBack(session, turn: note?.id, keepText: keepText); return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            sessions.setMail(nil, for: session)
            if let note { transcripts.withdraw(note.id, in: session, restoring: keepText) }
        }
    }

    /// What a typed reply becomes, from the same delivery table the placeholder reads: a note for
    /// Claude while it waits on a request (hosted or not) or works outside a terminal.
    func predictedMode(_ id: SessionKey) -> ReplyMode {
        guard let session = sessions.session(id), session.agent == .claude else { return .auto }
        if waiting(id) { return .note }
        let working = session.status == .working || session.status == .starting
        return working && session.hosted == nil ? .note : .auto
    }

    private func waiting(_ id: SessionKey) -> Bool {
        guard let session = sessions.session(id) else { return false }
        return SessionPhase(session) == .needsYou
    }

    private func deliver(_ text: String, turn: String, to session: SessionKey, mode: ReplyMode, submit: ReplySubmit? = nil) {
        if let link { link.flights.reply(text, turn: turn, to: session, mode: mode, submit: submit); return }
        // The demo's Mac answers as the real one would, and the answer moves the turn the way a live one does.
        let delivery: ReplyResult.Delivery
        if mode == .note || mode == .auto && predictedMode(session) == .note {
            delivery = .note
        } else if submit == .queue || mode == .followUp {
            delivery = sessions.session(session)?.status == .finished && mode == .followUp ? .followUp : .queued
        } else {
            delivery = .typed
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            if let stage = delivery.stage { transcripts.mark(turn, in: session, stage) }
            if delivery == .note { sessions.setMail(MailState(kind: .note, at: Date.now.timeIntervalSince1970), for: session) }
        }
    }
}

/// The messages waiting for a session's turn to end, changed from the phone.
extension AppModel {
    /// Takes one out. The row and the transcript's own copy of it go at once. True only once the Mac has taken out that
    /// very one; false when it had already gone or changed there (its turn ended and the session took it, or ids moved
    /// under two replies with the same words), and the sheet then shows the Mac's queue as it is.
    /// `optimistic: false` keeps the row until the Mac answers, for a caller that has more to say once it does.
    @discardableResult func removeQueued(_ reply: QueuedReply, in session: SessionKey, optimistic: Bool = true) async throws -> Bool {
        let before = sessions.session(session)?.queued ?? []
        if optimistic { sessions.setQueued(before.filter { $0.id != reply.id }, for: session) }
        do { try await tools.removeQueued(reply, in: session) } catch let failure as RemoteFailure
            where failure.error.code == .queueChanged || failure.error.code == .notFound || failure.status == 404 {
            await showMacQueue(session)
            return false
        } catch {
            sessions.setQueued(before, for: session)
            throw error
        }
        if !optimistic { sessions.setQueued(before.filter { $0.id != reply.id }, for: session) }
        transcripts.dropQueued(reply.text, in: session)
        return true
    }

    /// One step on the Mac, so a turn ending between taking it out and sending it can't lose it or send it twice.
    func sendNow(_ reply: QueuedReply, in session: SessionKey, as delivery: Delivery) -> Bool {
        guard let link, tools.can(.repliesPromote), delivery != .interrupt else { return false }
        transcripts.notice(nil, in: session)
        let turn = transcripts.send(reply.text, to: session)
        let mode: ReplyMode = delivery == .nextStep && sessions.session(session)?.agent != .claude ? .note : replyMode(session)
        link.flights.reply(reply.text, turn: turn.id, to: session, mode: mode, submit: delivery == .steer ? .steer : nil, photos: .none,
                           promotes: reply.id)
        return true
    }

    /// Under the field, since the sheet closes once the queue empties. Refused, the Mac kept it queued.
    func sendNowRefused(_ turn: String, in session: SessionKey, _ error: APIError) {
        transcripts.withdraw(turn, in: session, restoring: false)
        transcripts.notice(error.code == .queueChanged ? error.message : "Not sent now: \(error.message) It's still queued.", in: session)
        Task { await showMacQueue(session) }
    }

    private func showMacQueue(_ session: SessionKey) async {
        guard let link else { return }
        do { try await link.engine.refresh() } catch {
            RemoteLog.error(.sync, "refreshing the Mac's queue failed: \(KitLog.describe(error))")
        }
        let state = await link.engine.state
        guard state.epoch != nil else { return }
        sessions.setQueued(state.sessions[session]?.queued ?? [], for: session)
    }

    /// Changes one's words, keeping its turn in the queue.
    func reword(_ reply: QueuedReply, to text: String, in session: SessionKey) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != reply.text else { return }
        try await tools.reword(reply, to: text, in: session)
        let queued = sessions.session(session)?.queued ?? []
        // The Mac's row follows with the reply's new id; until then its old one keeps the row where it is.
        sessions.setQueued(queued.map { $0.id == reply.id ? QueuedReply(id: reply.id, text: text) : $0 }, for: session)
        transcripts.rewordQueued(reply.text, to: text, in: session)
    }
}
