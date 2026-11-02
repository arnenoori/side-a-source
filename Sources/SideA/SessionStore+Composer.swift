import Foundation
import SideACore
import SideAProtocol

/// What the composer sent last, and what became of it.
struct ComposerOutcome: Equatable {
    enum Result: Equatable {
        case sent(ReplyResult.Delivery)
        /// Not sent; the words say why.
        case failed(String)
    }
    let result: Result
    let text: String
    var images: [String] = []
    let how: ComposerSend
}

/// ↩, ⌥↩, or the send menu's note.
enum ComposerSend: Equatable { case now, afterTurn, note }

/// A conversation as the composer sees it: its live process and finished turn, and what the phone could do with it.
@MainActor struct ComposerTarget {
    let id: String
    let live: LiveSession?
    let ready: Island.Ready?
    let status: SessionStatus?
    let abilities: Set<SessionAbility>
    /// The finished turn's Stop hook is waiting, so a reply starts its next turn.
    let waiter: Bool
    let waitingRequest: Bool

    init(_ id: String, store: AccountStore) {
        self.id = id
        let commands = SessionCommands(store: store)
        live = store.sessions.liveByID[id] ?? store.sessions.live.first { $0.sessionID == id }
        ready = store.island.ready.first { $0.finish.sessionID == id }
        status = live.map { commands.status($0) }
        abilities = live.map { commands.abilities($0, status: commands.status($0)) } ?? []
        waiter = ready.map(store.island.canReply) ?? false
        waitingRequest = store.island.pending.contains { $0.request.sessionID == id }
    }

    var working: Bool { status == .working }
    var hosted: Bool { live?.hosted != nil }
    var claude: Bool { (live?.provider ?? .claude) == .claude }
    /// Reached through Codex's app server: a reply mid-turn steers it, or waits for it.
    var terminal: Bool { abilities.contains(.replyTerminal) }

    /// Anything typed here can go somewhere: the phone's table has a row for it, or a finished turn takes the
    /// clipboard fallback.
    var canReply: Bool {
        ready != nil || !abilities.isDisjoint(with: [.type, .note, .replyInbox, .replyTerminal, .followUp])
    }

    /// Claude while it works outside a pane reads what's typed as a note.
    var becomesNote: Bool { claude && !hosted && working && abilities.contains(.note) }

    /// Through the inbox or a Stop hook, Claude reads a reply as a note, never as the user's own words.
    var arrivesAsNote: Bool {
        guard claude, !hosted else { return false }
        return abilities.contains(.replyInbox) || (status == .finished || ready != nil) && abilities.contains(.followUp)
    }

    /// ⌥↩ means something: the turn can be waited for.
    var queues: Bool { working && (hosted && claude || terminal || abilities.contains(.followUp)) }

    /// Esc: Stop Now in a pane or through Codex's server, else stop mail before the next step.
    var interrupt: InterruptRequest.When? {
        guard working, abilities.contains(.interrupt) else { return nil }
        return hosted || terminal ? .now : (claude && abilities.contains(.note) ? .nextStep : nil)
    }

    var placeholder: String {
        if waiter { return "Next task for this session…" }
        if becomesNote { return "Add a note…" }
        if arrivesAsNote { return "Reply · arrives as a note" }
        return working ? "Message…" : "Reply…"
    }

    /// The line under the field while nothing else is there.
    var hint: String {
        if waiter { return "It finished. What you send starts its next turn right away." }
        if ready != nil, live == nil || abilities.isDisjoint(with: [.type, .replyInbox, .replyTerminal]) {
            return "It finished. Your reply is copied and its terminal comes forward."
        }
        if terminal { return working ? "↩ steers this turn  ·  ⌥↩ sends it after this turn" : "Shows in its terminal as your message." }
        if hosted, !claude, working { return "Reply when this turn ends  ·  esc stops it" }
        if hosted { return working ? "↩ types it now  ·  ⌥↩ waits for this turn  ·  esc stops it" : "Types into its terminal." }
        if becomesNote { return "It reads a note after its current step  ·  ⌥↩ sends it after this turn  ·  esc stops before its next step" }
        if abilities.contains(.replyInbox) { return "It picks this up within a second, as a note." }
        if live?.provider == .codex, working { return "Reply when this turn ends." }
        return ""
    }
}

extension SessionStore {
    /// Sends what the composer holds by the phone's own delivery table. The draft clears at once and comes back if
    /// the reply couldn't go.
    func compose(_ id: String, how: ComposerSend) {
        let text = (drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let images = (attachments[id] ?? []).map(\.path)
        guard !text.isEmpty || !images.isEmpty else { return }
        drafts[id] = ""
        attachments[id] = nil
        reply(text, images: images, to: id, how: how)
    }

    /// Photos pasted, dropped or chosen: stored in the uploads folder the phone's go to, swept the same way.
    func attach(_ images: [Data], to id: String) {
        let root = store.root
        Task {
            let stored = await Task.detached { () -> [Upload] in
                RemoteUploads.sweep(root: root)
                return images.compactMap { try? RemoteUploads.store($0, root: root) }
            }.value
            if stored.count < images.count { self.error = "Side A takes HEIC, JPEG, PNG, GIF or WebP photos." }
            self.attachments[id, default: []] = Array((self.attachments[id, default: []] + stored).prefix(10))
        }
    }

    func detach(_ upload: Upload, from id: String) {
        attachments[id]?.removeAll { $0.id == upload.id }
    }

    func reply(_ text: String, images: [String] = [], to id: String, how: ComposerSend) {
        let target = ComposerTarget(id, store: store)
        // No live process and no waiting Stop hook: the island's own fallback copies it and brings the terminal forward.
        if let ready = target.ready, !target.waiter, target.live == nil || !target.canReply {
            store.island.reply(ready, text)
            outcomes[id] = nil
            return
        }
        var message = SessionCommands.Message(text: text, images: images, turnID: target.ready?.id.uuidString.lowercased())
        switch how {
        case .now: break
        case .note: message.mode = .note
        case .afterTurn:
            if target.hosted || target.terminal { message.submit = .queue } else { message.mode = .followUp }
        }
        let key = target.live.map(WireBuilders.key) ?? id
        let commands = SessionCommands(store: store)
        outcomes[id] = nil
        Task {
            do throws(SessionCommands.Failure) {
                let result = try await commands.reply(key, message)
                Sounds.play(.tick)
                self.outcomes[id] = ComposerOutcome(result: .sent(result.delivery), text: text, images: images, how: how)
            } catch {
                self.outcomes[id] = ComposerOutcome(result: .failed(error.macMessage), text: text, images: images, how: how)
            }
        }
    }

    /// Not sent · Retry: the same words, the same way.
    func retry(_ id: String) {
        guard let outcome = outcomes[id], case .failed = outcome.result else { return }
        reply(outcome.text, images: outcome.images.filter { FileManager.default.fileExists(atPath: $0) }, to: id, how: outcome.how)
    }

    /// The reply Codex or Claude dropped, sent again in full.
    func retryDropped(_ id: String) {
        guard let live = ComposerTarget(id, store: store).live, let text = SessionCommands(store: store).unsent(live) else { return }
        reply(text, to: id, how: .now)
    }

    func loadCommands() async {
        commands = await RemoteOptions.commands(RemoteOptions.homes(store), cache: store.remote.cache)
    }

    /// ⎋ from the composer.
    func interrupt(_ id: String) {
        let target = ComposerTarget(id, store: store)
        guard let live = target.live, let when = target.interrupt else { return }
        stop(live, now: when == .now)
    }
}
