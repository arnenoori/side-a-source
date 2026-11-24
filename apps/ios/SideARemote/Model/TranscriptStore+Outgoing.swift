import Foundation
import SideAProtocol
import SideARemoteKit

/// Replies this phone sent, from the bubble to the field they may go back to.
extension TranscriptStore {
    /// A turn this phone sent that the Mac's transcript doesn't show yet. A note never shows there
    /// (the session reads it through a hook), so it stays as the phone's own record.
    struct Outgoing: Hashable, Identifiable {
        let id: String
        var text: String
        let at: Date
        /// Changed only by `move`, along `ReplyBubble.next`.
        fileprivate(set) var bubble: ReplyBubble
        /// The reply's outbox item, which the Mac's receipts name.
        var item: String?
        /// When it reached `state`.
        var since: Date?
        /// The photos it carried, by upload id, for a Stop that gives it back after its flight has gone.
        var photos: [String] = []

        typealias State = ReplyProgress.Stage

        init(id: String, text: String, at: Date, state: State) {
            self.id = id; self.text = text; self.at = at; bubble = ReplyBubble(state)
        }

        var state: State { bubble.stage }
        var unchecked: Bool { bubble.unchecked }
        var isPendingNote: Bool { state == .note || state == .takingBack }
    }

    /// A reply the Mac didn't take: its text goes back into the field with "Not sent · Retry" under it.
    struct Unsent: Hashable {
        let text: String
        let reason: String
        /// The reply's flight, by its outbox item, for a Retry with what it carried; nil sends the text fresh.
        let item: String?
    }

    func notice(_ text: String?, in session: SessionKey) { if notices[session] != text { notices[session] = text } }

    /// Shows the turn at once; the link (or the demo) moves its state along.
    @discardableResult func send(_ text: String, to session: SessionKey, at: Date = .now) -> Outgoing {
        unsent[session] = nil
        let turn = Outgoing(id: UUID().uuidString.lowercased(), text: text, at: at, state: .sending)
        outgoing[session, default: []].append(turn)
        return turn
    }

    /// The one way a bubble on screen changes. One that returns or leaves is taken out and handed back as it was, for the
    /// caller to do with its words what that means.
    @discardableResult
    func move(_ id: String, in session: SessionKey, _ event: ReplyBubble.Event) -> (turn: Outgoing, next: ReplyBubble.Next)? {
        guard let index = outgoing[session]?.firstIndex(where: { $0.id == id }), let turn = outgoing[session]?[index],
              let next = turn.bubble.next(event) else { return nil }
        switch next {
        case .stays(let bubble) where bubble.watch == .shownAway:
            outgoing[session]?.remove(at: index)
            var away = turn
            away.bubble = bubble
            keepShownAway(away, in: session)
        case .stays(let bubble): outgoing[session]?[index].bubble = bubble
        case .returns, .leaves: outgoing[session]?.remove(at: index)
        }
        return (turn, next)
    }

    /// Only along `ReplyProgress`'s table, so a late answer never undoes what a receipt already said.
    func mark(_ id: String, in session: SessionKey, _ state: Outgoing.State) { advance(id, in: session, .reached(state)) }

    func advance(_ id: String, in session: SessionKey, _ event: ReplyBubble.Event) {
        guard case .stays(let bubble)? = move(id, in: session, event)?.next else { return }
        if let index = outgoing[session]?.firstIndex(where: { $0.id == id }) { outgoing[session]?[index].since = .now }
        if ReplyBubble.showable.contains(bubble.stage) { settleOutgoing(session) }
    }

    func bind(_ id: String, item: String, in session: SessionKey) {
        guard let index = outgoing[session]?.firstIndex(where: { $0.id == id }), outgoing[session]?[index].item != item else { return }
        outgoing[session]?[index].item = item
    }

    func keepPhotos(_ photos: [String], on id: String, in session: SessionKey) {
        guard !photos.isEmpty, let index = outgoing[session]?.firstIndex(where: { $0.id == id }) else { return }
        outgoing[session]?[index].photos = photos
    }

    /// The Mac's word on replies this phone typed into the session: held, read, or given back with its reason.
    /// Several given back at once (a Stop returns every reply it took back) go into the field together, oldest first.
    /// True when a Stop gave them back, so the prompt is empty again.
    @discardableResult
    func apply(_ receipts: [ReplyReceipt], in session: SessionKey) -> Bool {
        var lost: [(text: String, reason: String, turn: String?)] = []
        for receipt in receipts {
            guard let event = receipt.event else { continue }
            let reason = receipt.reason ?? "It didn't reach the session."
            if let turn = outgoing[session]?.first(where: { receipt.answers($0.item) }) {
                if turn.bubble.next(.progress(event)) == .returns {
                    lost.append((turn.text, reason, turn.id))
                } else {
                    advance(turn.id, in: session, .progress(event))
                }
            } else if let index = shownAway[session]?.firstIndex(where: { receipt.answers($0.item) }),
                      let turn = shownAway[session]?[index], turn.bubble.next(.progress(event)) == .returns {
                shownAway[session]?.remove(at: index)
                lost.append((turn.text, reason, nil))
            }
        }
        guard let last = lost.last else { return false }
        let photos = lost.compactMap { lost in
            lost.turn.flatMap { turn in outgoing[session]?.first { $0.id == turn && !$0.photos.isEmpty }.map { (turn, $0.photos) } }
        }
        if !photos.isEmpty { photosBack?(photos, session) }
        for turn in Set(lost.dropLast().compactMap { $0.turn }) { move(turn, in: session, .gaveBack) }
        if let id = last.turn {
            fail(id, in: session, reason: last.reason, item: nil, joining: lost.dropLast().map { $0.text })
        } else {
            giveBack(lost.map { $0.text }, in: session, reason: last.reason)
        }
        return ReplyReceipt.isStopReason(last.reason)
    }

    /// Start returned: the prompt shows at once, as a reply does, already accepted.
    func started(_ name: String, prompt: String, at: Date) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        firstPrompts[name] = Outgoing(id: UUID().uuidString.lowercased(), text: text, at: at, state: .sent)
    }

    func wait(_ text: String, for name: String, at: Date) {
        waitingReplies[name] = Outgoing(id: UUID().uuidString.lowercased(), text: text, at: at, state: .sending)
    }

    func takeWaitingReply(_ name: String) -> String? { waitingReplies.removeValue(forKey: name)?.text }

    /// The hosted session has a row: its prompt waits in that transcript until the Mac's copy arrives. Again under a
    /// new key when the row's key changes, as a Codex `pid-…` one does once its thread starts.
    func carryFirstPrompt(_ name: String, to session: SessionKey) {
        guard let turn = firstPrompts[name] else { return }
        if let old = carried[name], old != session { move(turn.id, in: old, .withdrawn) }
        carried[name] = session
        if outgoing[session]?.contains(where: { $0.id == turn.id }) != true { outgoing[session, default: []].append(turn) }
        settleOutgoing(session)
    }

    /// The process ended: nothing it was asked will show, and its text goes back to `session`'s field when given.
    func dropFirstPrompt(_ name: String, giveBackTo session: SessionKey? = nil) {
        let lost = [firstPrompts.removeValue(forKey: name), waitingReplies.removeValue(forKey: name)].compactMap { $0 }
        if let old = carried.removeValue(forKey: name) { for turn in lost { move(turn.id, in: old, .withdrawn) } }
        if let session { giveBack(lost.map(\.text), in: session, reason: "It ended before it took this.") }
    }

    /// A turn shown while something else happens first (Continue, Resume), gone without giving its text back.
    func discard(_ id: String, in session: SessionKey) { move(id, in: session, .withdrawn) }

    /// A queued turn the user took back from the queue: gone, its words not returned to the field.
    func dropQueued(_ text: String, in session: SessionKey) {
        guard let turn = outgoing[session]?.first(where: { $0.state == .queued && $0.text == text }) else { return }
        move(turn.id, in: session, .withdrawn)
    }

    func rewordQueued(_ text: String, to new: String, in session: SessionKey) {
        guard let index = outgoing[session]?.firstIndex(where: { $0.state == .queued && $0.text == text }) else { return }
        outgoing[session]?[index].text = new
    }

    /// The Mac didn't take it: the turn goes, its text waits in the field. False when the turn is already gone.
    /// The Mac gave up on what it was holding for this session.
    func failQueued(in session: SessionKey, reason: String) {
        let lost = outgoing[session]?.filter { $0.state == .queued } ?? []
        for turn in lost { move(turn.id, in: session, .progress(.dropped)) }
        giveBack(lost.map(\.text), in: session, reason: reason)
    }

    /// What the Mac still remembers giving up on, against what this phone has already settled; answers the new settled set.
    /// The phone that sent a reply gets it back even with no turn left to show for it, as after a relaunch. Another phone's
    /// comes with no words and is only noted. One from an old queue file gives back this phone's own turns from before it.
    func settle(_ dropped: [DroppedReply], device: String, settled: Set<String>) -> Set<String> {
        let fresh = dropped.filter { !settled.contains($0.id) }.sorted { $0.at < $1.at }
        for (session, records) in Dictionary(grouping: fresh, by: \.sessionID) {
            var lost: [String] = []
            for record in records {
                if record.reason == .oldQueue {
                    let held = outgoing[session]?.filter { $0.state == .queued && $0.at.timeIntervalSince1970 <= record.at } ?? []
                    for turn in held { move(turn.id, in: session, .progress(.dropped)) }
                    lost += held.map(\.text)
                } else if record.device == device, let text = record.text {
                    let turn = outgoing[session]?.first { $0.state == .queued && $0.text == text && $0.at.timeIntervalSince1970 <= record.at }
                    if let turn { move(turn.id, in: session, .progress(.dropped)) }
                    lost.append(text)
                }
            }
            giveBack(lost, in: session, reason: records[0].reason.unsentReason)
        }
        return settled.intersection(dropped.map(\.id)).union(fresh.map(\.id))
    }

    func giveBack(_ texts: [String], in session: SessionKey, reason: String) {
        guard !texts.isEmpty else { return }
        let text = texts.joined(separator: "\n\n")
        unsent[session] = Unsent(text: text, reason: reason, item: nil)
        restore(text, in: session)
    }

    /// `earlier`: replies that failed before this one and are folded into it, since a session shows one unsent reply. Their
    /// words lead, and replace the field when the field still holds just them.
    @discardableResult func fail(_ id: String, in session: SessionKey, reason: String, item: String?, joining earlier: [String] = []) -> Bool {
        guard let turn = move(id, in: session, .gaveBack)?.turn else { return false }
        let text = (earlier + [turn.text]).joined(separator: "\n\n")
        unsent[session] = Unsent(text: text, reason: reason, item: item)
        let typed = drafts[session, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if earlier.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == typed }) { drafts[session] = "" }
        restore(text, in: session)
        return true
    }

    /// A turn the outbox still holds from before this launch: back as it was.
    func adopt(_ id: String, text: String, at: Date, to session: SessionKey) {
        guard outgoing[session]?.contains(where: { $0.id == id }) != true else { return }
        outgoing[session, default: []].append(Outgoing(id: id, text: text, at: at, state: .sending))
    }

    /// Text back into the field, unless something new is being typed there.
    func restore(_ text: String, in session: SessionKey) {
        if drafts[session, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { drafts[session] = text }
    }

    func clearUnsent(_ session: SessionKey) { unsent[session] = nil }

    /// Take Back landed: the note leaves the transcript and returns the text it carried.
    @discardableResult func withdraw(_ id: String, in session: SessionKey, restoring: Bool = true) -> String? {
        guard let turn = move(id, in: session, .withdrawn)?.turn else { return nil }
        if restoring { restore(turn.text, in: session) }
        return turn.text
    }

    /// An Edit that came too late: the session already read the note, so its text waits in the field as a new message.
    func editTooLate(_ id: String, in session: SessionKey) {
        guard let turn = outgoing[session]?.first(where: { $0.id == id }) else { return }
        restore(turn.text, in: session)
        notice("Already sent. Your text is in the field as a new message.", in: session)
    }

    /// The note this phone left that the session hasn't read yet.
    func pendingNote(_ session: SessionKey) -> Outgoing? { outgoing[session]?.last(where: \.isPendingNote) }

    /// A second note while one waits replaces it on the Mac (one mail slot per session), so the two
    /// travel as one: the waiting turn takes the new text and goes back to sending.
    func merge(_ text: String, into id: String, in session: SessionKey) -> String? {
        guard move(id, in: session, .progress(.amended)) != nil, let index = outgoing[session]?.firstIndex(where: { $0.id == id }) else { return nil }
        outgoing[session]?[index].text += "\n\n" + text
        return outgoing[session]?[index].text
    }

    /// Sent and held turns whose receipts went when Side A restarted on the Mac: no receipt will say they were read, so
    /// they stop saying they wait for one. The transcript's text still settles them.
    func receiptsLost() {
        for (session, turns) in outgoing { for turn in turns { move(turn.id, in: session, .receiptsLost) } }
    }

    /// Interrupt and Send's stop takes the session's other sent and held replies off the agent's prompt; until `turn` has
    /// gone, only Side A's memory holds them.
    func carry(in session: SessionKey, with turn: String) {
        for other in outgoing[session] ?? [] {
            move(other.id, in: session, other.id != turn && other.item != nil ? .carry(with: turn) : .uncarry)
        }
    }

    /// Other replies waiting to be read are still with the agent, so they only can't be checked.
    func restarted(mac: String, receipts: Set<String>) {
        for (session, turns) in outgoing {
            let carriedWith = turns.lazy.compactMap { turn -> String? in
                if case .carried(let with, _) = turn.bubble.watch { with } else { nil }
            }.first
            guard let with = carriedWith else { continue }
            let withSending = turns.first { $0.id == with }?.state == .sending
            if withSending { settleOutgoing(session) }
            var lost: [Outgoing] = []
            for turn in outgoing[session] ?? [] {
                let received = turn.item.map { receipts.contains(ReplyReceipt.family($0)) } ?? false
                if move(turn.id, in: session, .restarted(withSending: withSending, received: received))?.next == .returns { lost.append(turn) }
            }
            guard !lost.isEmpty else { continue }
            let photos = lost.filter { !$0.photos.isEmpty }.map { (turn: $0.id, ids: $0.photos) }
            if !photos.isEmpty { photosBack?(photos, session) }
            giveBack(lost.sorted { $0.at < $1.at }.map(\.text), in: session,
                     reason: "Side A restarted on \(mac) before this was read. It may not have been delivered.")
        }
        receiptsLost()
    }

    /// The session's mail emptied without a Take Back from here: it read the note.
    func noteRead(in session: SessionKey) {
        for turn in outgoing[session] ?? [] where turn.state == .note { move(turn.id, in: session, .progress(.read)) }
    }

    /// A user turn in the Mac's transcript up to this much older than the phone's send can still be it: the two clocks
    /// differ.
    static let aboutThen: TimeInterval = 30

    private static let keptShownAway = 20
    func keepShownAway(_ turn: Outgoing, in session: SessionKey) {
        shownAway[session, default: []].append(turn)
        while let first = shownAway[session]?.first, shownAway[session, default: []].count > Self.keptShownAway,
              first.bubble.next(.forgotten) == .leaves {
            shownAway[session]?.removeFirst()
        }
    }

    /// A sent turn goes once the Mac's transcript has a user turn with its text from about then on, the oldest first.
    func settleOutgoing(_ session: SessionKey) {
        guard let turns = outgoing[session], turns.contains(where: { ReplyBubble.showable.contains($0.state) }) else { return }
        var users = (messages[session] ?? []).filter { $0.role == .user && settledBy[session]?.contains($0.uuid) != true }
        var shown: [Outgoing] = []
        for turn in turns.sorted(by: { $0.at < $1.at }) where ReplyBubble.showable.contains(turn.state) {
            guard let index = users.firstIndex(where: { user in
                user.text?.trimmingCharacters(in: .whitespacesAndNewlines) == turn.text
                    && (user.at ?? .infinity) >= turn.at.timeIntervalSince1970 - Self.aboutThen
            }) else { continue }
            settledBy[session, default: []].insert(users.remove(at: index).uuid)
            shown.append(turn)
        }
        // Interrupt and Send types the replies its stop took back and the new one as one prompt, so one user turn holds
        // them all. Only a turn the Mac already says was read goes on that: a look-alike line can't settle a waiting one,
        // nor can a user turn that already settled another reply on its own.
        var holders = Set<String>()
        let joined = turns.filter { turn in
            guard turn.state == .read, !shown.contains(where: { $0.id == turn.id }), let user = users.first(where: { user in
                (user.at ?? .infinity) >= turn.at.timeIntervalSince1970 - Self.aboutThen && Self.holds(user.text ?? "", turn.text)
            }) else { return false }
            holders.insert(user.uuid)
            return true
        }
        settledBy[session, default: []].formUnion(holders)
        shown += joined
        // A first prompt the agent rewrote (a slash command is logged as its expansion) goes once any user turn follows it.
        let rewritten = carried.filter { $0.value == session }.compactMap { firstPrompts[$0.key] }.filter { turn in
            users.contains { ($0.at ?? 0) >= turn.at.timeIntervalSince1970 - Self.aboutThen }
        }
        for turn in shown { move(turn.id, in: session, .shown(bound: turn.item != nil)) }
        for turn in rewritten { move(turn.id, in: session, .shown(bound: false)) }
        let gone = Set((shown + rewritten).map(\.id))
        for (name, turn) in firstPrompts where gone.contains(turn.id) {
            firstPrompts[name] = nil
            carried[name] = nil
        }
    }

    /// Whether `text`'s lines are a run of whole lines in `prompt`, indents aside.
    static func holds(_ prompt: String, _ text: String) -> Bool {
        func lines(_ text: String) -> [String] {
            text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let all = lines(prompt), run = lines(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, run.count <= all.count else { return false }
        return (0...(all.count - run.count)).contains { Array(all[$0..<($0 + run.count)]) == run }
    }
}
