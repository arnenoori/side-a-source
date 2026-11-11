import Foundation
import SideAProtocol

/// How Send delivers a message to a session mid-turn, offered on its long-press.
enum Delivery: Hashable, CaseIterable {
    /// Into the running turn: Codex through its shared server.
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
            // Hosted Claude reads typed input at its next step; hosted Codex refuses a reply until its turn ends.
            if session.agent == .claude {
                deliveries.append(.nextStep)
                if abilities.contains(.followUp) { deliveries.append(.afterTurn) }
            }
        } else {
            // Outside Side A's terminals: a note the hooks read at the next step, or Claude's Stop waiter at the turn's end.
            if abilities.contains(.note) { deliveries.append(.nextStep) }
            if session.agent == .claude, abilities.contains(.followUp) { deliveries.append(.afterTurn) }
        }
        // Esc in a hosted terminal, or Codex's turn interrupt. Unhosted Claude has only stop mail, which waits for the next step.
        if abilities.contains(.interrupt), session.hosted != nil || abilities.contains(.replyTerminal) { deliveries.append(.interrupt) }
        return deliveries
    }

    /// A delivery picked from Send's long-press.
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
        let turn = transcripts.send(text, to: id)
        guard let link else {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                _ = tools.attachments.take(id, for: turn.id)
                transcripts.mark(turn.id, in: id, .sent)
            }
            return
        }
        link.flights.interrupt(id, when: .now) { [weak self, weak link] stopped in
            guard let self else { return }
            guard stopped else {
                transcripts.withdraw(turn.id, in: id)
                return
            }
            Task { @MainActor in
                await self.turnEnded(id)
                link?.flights.reply(text, turn: turn.id, to: id, mode: self.replyMode(id))
            }
        }
    }

    /// Codex takes a message as a new prompt only once the Mac sees its turn over; Claude's terminal takes it at once.
    private func turnEnded(_ id: SessionKey, within: Duration = .seconds(8)) async {
        guard sessions.session(id)?.agent == .codex else { return }
        let deadline = ContinuousClock.now + within
        while sessions.session(id)?.status == .working, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// `auto`, or while a request waits on the session, what it can still take.
    func replyMode(_ session: SessionKey) -> ReplyMode { waiting(session) ? predictedMode(session) : .auto }

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
        return tools.can(.replyTerminal) && session.agent == .codex && session.hosted == nil && !session.abilities.contains(.replyTerminal)
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

    func interrupt(_ session: SessionKey, when: InterruptRequest.When = .now) {
        transcripts.notice(nil, in: session)
        if let link { link.flights.interrupt(session, when: when); return }
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
        let leavesMail = mode == .note || mode == .auto && predictedMode(session) == .note
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            if leavesMail {
                transcripts.mark(turn, in: session, .note)
                sessions.setMail(MailState(kind: .note, at: Date.now.timeIntervalSince1970), for: session)
            } else if submit == .queue || mode == .followUp {
                transcripts.mark(turn, in: session, .queued)
            } else {
                transcripts.mark(turn, in: session, .sent)
            }
        }
    }
}
