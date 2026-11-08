import Foundation
import SideAProtocol

/// Replies, notes, interrupts and Take Back (sections 4.4 and 4.14). Live they leave through the
/// link's outbox; the demo plays the Mac's side locally so every state can be seen.
extension AppModel {
    /// The composer's send: `mode: auto`, so the Mac's delivery table decides what it becomes. A
    /// second note while one waits travels with it, since the Mac keeps one note per session.
    func reply(_ text: String, to session: SessionKey, submit: ReplySubmit? = nil) {
        let mode = predictedMode(session)
        if mode == .note, let waiting = transcripts.pendingNote(session), waiting.state == .note,
           let combined = transcripts.merge(text, into: waiting.id, in: session) {
            deliver(combined, turn: waiting.id, to: session, mode: .note)
            return
        }
        let turn = transcripts.send(text, to: session)
        // `auto` to a session with an open request is 409 `session_waiting`; only a note gets through (`replyMode`).
        deliver(text, turn: turn.id, to: session, mode: replyMode(session), submit: submit)
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
        let leavesMail = mode == .note || predictedMode(session) == .note
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            if leavesMail {
                transcripts.mark(turn, in: session, .note)
                sessions.setMail(MailState(kind: .note, at: Date.now.timeIntervalSince1970), for: session)
            } else if submit == .queue {
                transcripts.mark(turn, in: session, .queued)
            } else {
                transcripts.mark(turn, in: session, .sent)
            }
        }
    }
}
