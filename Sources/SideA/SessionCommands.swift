import Foundation
import SideACore
import SideAProtocol

/// What can be done to a running session, for the phone's routes and the Sessions window alike: a reply goes by the
/// protocol's delivery table into a hosted pane, a Stop hook, the island's queue, mail, a Claude inbox or Codex's app
/// server. A failure carries the status, code and words the phone gets; the window shows the words.
@MainActor struct SessionCommands {
    let store: AccountStore

    nonisolated static let maxReply = 20_000

    struct Failure: Error, Equatable {
        let status: Int
        let code: ErrorCode
        let message: String
        var details: [String: String]?
        var retryAfter: Int?

        static let noSession = Failure(status: 404, code: .sessionNotFound, message: "That session isn't running on the Mac any more.")
        static let queueChanged = Failure(status: 409, code: .queueChanged, message: "That reply has already gone or changed. Look again.")
        static let promotedGone = Failure(status: 409, code: .queueChanged,
                                          message: "It had already left the queue on the Mac, so it wasn't sent again.")
        static let promotedBack = Failure(status: 409, code: .queueChanged, message: "It went back in the queue on the Mac, and goes when the turn ends.")
        static let movedOn = Failure(status: 409, code: .sessionMovedOn, message: "The session moved on while this waited. Read what it did, then send it again.")
        static let notReady = Failure(status: 503, code: .notReady, message: "Side A is still starting Remote.", retryAfter: 2)

        static func invalid(_ message: String, _ reason: String) -> Failure {
            Failure(status: 422, code: .invalidReply, message: message, details: ["reason": reason])
        }

        static func cannotDeliver(_ refusal: RemoteDelivery.Refusal) -> Failure {
            let message = switch (refusal.code, refusal.hint) {
            case ("session_waiting", _): "This session is waiting for an answer. Answer its request first."
            case ("not_hosted", _): "Keys only go to sessions Side A hosts."
            case (_, "continueOnPhone"?): "This session isn't running. Continue it in Side A Remote to reply."
            case (_, "queueFull"?): "Five replies are already waiting for this session."
            case (_, "setup"?): "Turn on the agent's hooks in Side A's Remote settings to reach this session."
            default: "Side A can't get this to the session right now."
            }
            return Failure(status: 409, code: ErrorCode(rawValue: refusal.code), message: message, details: refusal.hint.map { ["hint": $0] })
        }

        static func hosted(_ error: HostedError) -> Failure {
            let message = error.errorDescription ?? "Side A couldn't type into that session."
            let answer = error.answer
            var details = answer.hint.map { ["hint": $0.rawValue] }
            if case .notResumed(let name, let command) = error { details?["hosted"] = name; details?["command"] = command }
            return Failure(status: answer.status, code: answer.code, message: message, details: details, retryAfter: answer.retryAfter)
        }

        static func codex(_ error: CodexTerminals.Failure) -> Failure {
            switch error {
            case .notAttached, .closed:
                Failure(status: 409, code: .cannotDeliver, message: "Side A lost its connection to Codex. Try again in a moment.", details: ["hint": "tryAgain"])
            case .rpc(let message): Failure(status: 409, code: .cannotDeliver, message: "Codex didn't take it: \(message)")
            case .unsupported: Failure(status: 409, code: .unsupported, message: "This version of Codex can't change settings from Side A.")
            case .invalid(let message): Failure(status: 422, code: .invalidSettings, message: message)
            case .busy: Failure(status: 409, code: .cannotDeliver, message: "Codex is working. Try when it's idle.", details: ["hint": "notIdle"])
            }
        }

        var hint: String? { details?["hint"] }

        var macMessage: String {
            switch hint {
            case "continueOnPhone"?: "This session isn't running where Side A can reach it. Resume it to reply."
            case "setup"?: "Turn on the Dynamic Island or Remote in Settings to reach this session."
            default: message
            }
        }
    }

    /// A reply. `images` are paths on the Mac: a hosted pane gets each pasted for the agent to attach, everywhere else
    /// they follow the text.
    struct Message: Sendable {
        var text: String
        var images: [String] = []
        var mode: ReplyMode = .auto
        var keys: [Key]?
        /// The finished turn this follows up on; a reply to one that has moved on is refused.
        var turnID: String?
        var submit: ReplySubmit?
        var replaces: String?
        /// The phone that sent it and what it proved, for a reply that waits. Nil from the Mac.
        var origin: Island.QueuedFollowUp.Origin?
        /// The phone's `Idempotency-Key`, which its receipt goes under.
        var idempotencyKey: String?
        var seen: String?
        var promotes: String?
    }

    @MainActor struct Target {
        let key: SessionKey
        let live: LiveSession?
        let row: Island.Ready?
        let codex: SessionStatus?
        var conversation: String? { live?.sessionID ?? row?.finish.sessionID }

        init?(_ id: String, store: AccountStore) {
            let live = store.sessions.live.first { WireBuilders.key($0) == id || $0.sessionID == id }
            let row = store.island.ready.first { $0.finish.sessionID != nil && ($0.finish.sessionID == id || $0.finish.sessionID == live?.sessionID) }
            guard live != nil || row != nil else { return nil }
            self.live = live; self.row = row
            codex = live.flatMap(store.remote.codex.status)
            key = live.map(WireBuilders.key) ?? id
        }

        func state(_ island: Island) -> RemoteDelivery.State {
            if island.pending.contains(where: { $0.request.sessionID.map { $0 == conversation } ?? ($0.request.pid == live?.pid) }) { return .waiting }
            if let row, island.canReply(row) { return .finishedWaiting }
            guard let live else { return .idle }
            switch codex ?? WireBuilders.status(live) {
            case .working: return .working
            case .waiting: return .waiting
            case .idle, .finished: return .idle
            default: return .unknown
            }
        }
    }


    /// Its status as the phone sees it: Codex's app server's when it reaches the session, and finished, not idle, while
    /// its finished turn is on the island. `finished` is the island's finished conversations, when a caller has them.
    func status(_ live: LiveSession, finished: Set<String>? = nil) -> SessionStatus {
        let status = store.remote.codex.status(live) ?? WireBuilders.status(live)
        guard status == .idle, let id = live.sessionID else { return status }
        return (finished ?? Set(store.island.ready.compactMap(\.finish.sessionID))).contains(id) ? .finished : status
    }

    /// What it takes now; the phone and the Sessions window offer exactly these.
    func abilities(_ live: LiveSession, status: SessionStatus) -> Set<SessionAbility> {
        let island = store.island
        let codex = store.remote.codex
        var abilities: Set<SessionAbility> = [.transcript]
        if live.hosted != nil {
            abilities.formUnion([.type, .terminal])
            // Mid-turn Claude queues what's typed; Codex steers on Enter and queues on Tab.
            if status == .working { abilities.formUnion([.interrupt, .followUp]) }
        } else if live.provider == .claude, island.installed[.claude] == true {
            if status == .working { abilities.formUnion([.note, .interrupt, .followUp]) }
            if status == .waiting { abilities.insert(.note) }
            // Idle, its inbox hook wakes it with a reply, as a note Claude Code shows the model.
            if status == .idle || status == .finished, store.remote.inbox.watching(live) { abilities.insert(.replyInbox) }
        } else if live.provider == .codex, codex.reach(live) == .attached {
            abilities.insert(.replyTerminal)
            if status == .working { abilities.formUnion([.interrupt, .followUp]) }
        } else if live.provider == .codex, island.installed[.codex] == true {
            // Off the app server: notes through its mail hooks (by thread id), which Codex runs once the user trusts them.
            let notes = island.codexMail != "review" && live.sessionID != nil
            if notes, status == .working || status == .waiting { abilities.insert(.note) }
        }
        if let id = live.sessionID, island.hasWaiter(id) { abilities.insert(.followUp) }
        if status == .idle || status == .finished, abilities.isDisjoint(with: [.type, .replyInbox, .replyTerminal, .followUp]), store.remote.typer.reach(live) != nil {
            abilities.insert(.replyTyped)
        }
        if store.hosted.available, HostedSessions.continueRefusal(live) == nil { abilities.insert(.continueOnPhone) }
        abilities.formUnion(codex.row(live)?.abilities ?? [])
        // The bridge reads a Claude turn's diff from its transcript, so every Claude session with a turn has one.
        if live.provider == .claude, live.turnID != nil { abilities.insert(.turnDiff) }
        if live.provider == .claude {
            abilities.formUnion(Self.claudeTyped(live, reach: store.remote.typer.reach(live), status: status, asking: asking(live)).abilities)
        }
        return abilities
    }

    /// Why an ability the phone shows is missing: Codex's app server says for settings, hosted Claude's settings say
    /// why they're off, review for Claude is a reply, and Codex notes wait on the user's trust.
    func reasons(_ live: LiveSession, status: SessionStatus) -> [String: String]? {
        var reasons = store.remote.codex.row(live)?.reasons ?? [:]
        if live.provider == .claude {
            reasons.merge(Self.claudeTyped(live, reach: store.remote.typer.reach(live), status: status, asking: asking(live)).reasons) { $1 }
            reasons[SessionAbility.review.rawValue] = "Ask Claude in a reply."
        }
        if live.provider == .codex, live.hosted == nil, store.island.installed[.codex] == true, store.island.codexMail == "review",
           store.remote.codex.reach(live) != .attached {
            reasons[SessionAbility.note.rawValue] = "Codex asks you to review Side A's two new hooks before notes reach it."
        }
        return reasons.isEmpty ? nil : reasons
    }

    /// The session's permission mode as the Mac reads it, the inner nil when it can't; the outer nil when no such session runs.
    func permissionMode(_ id: String) -> PermissionMode?? {
        guard let target = Target(id, store: store) else { return nil }
        let settings = target.live.flatMap { store.remote.codex.row($0)?.settings ?? WireBuilders.settings($0) }
        return .some(settings?.mode)
    }

    private func asking(_ live: LiveSession) -> Bool {
        store.island.pending.contains { $0.request.sessionID != nil && $0.request.sessionID == live.sessionID || $0.request.pid == live.pid }
    }

    func flag(_ live: LiveSession) -> SessionFlag? {
        if let text = store.remote.codex.unsent(live) { return SessionFlag(kind: .unsent, text: "Didn't reach Codex: \u{201C}\(String(text.prefix(80)))\u{201D}") }
        if let text = store.remote.inbox.unsent(live) { return SessionFlag(kind: .unsent, text: "Didn't reach Claude: \u{201C}\(String(text.prefix(80)))\u{201D}") }
        return live.flag.map { SessionFlag(kind: SessionFlag.Kind(rawValue: $0.kind), text: $0.text) }
    }

    /// The reply a dropped one carried, in full: the quote in the flag is cut at 80 characters.
    func unsent(_ live: LiveSession) -> String? { store.remote.codex.unsent(live) ?? store.remote.inbox.unsent(live) }


    /// What a reply comes to on the main actor: delivered already, or typing still to do.
    enum Plan: Sendable {
        case failed(Failure)
        case done(ReplyResult)
        case type(name: String, key: SessionKey, working: Bool)
        /// `guarded`: a request is pending, so the keys could answer it and need Face ID.
        case keys(name: String, key: SessionKey, guarded: Bool)
        case codex(LiveSession, key: SessionKey, text: String, queue: Bool)
        case terminal(LiveSession, key: SessionKey, text: String)
    }

    /// Sends a reply. Keys that could answer an open request are refused here; only the phone, with Face ID, sends them.
    func reply(_ id: String, _ message: Message) async throws(Failure) -> ReplyResult {
        let plan = prepare(id, message)
        if case .keys(_, _, true) = plan {
            throw Failure(status: 409, code: .requestPending, message: "Answer the open request first.")
        }
        return try await send(plan, message)
    }

    func prepare(_ id: String, _ message: Message) -> Plan {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.mode != .keys, text.isEmpty, message.images.isEmpty { return .failed(.invalid("Write something to send.", "empty")) }
        if message.mode == .keys, message.keys?.isEmpty ?? true { return .failed(.invalid("Send at least one key.", "empty")) }
        if message.text.count > Self.maxReply { return .failed(.invalid("That reply is too long.", "too_long")) }
        if message.images.count > 10 { return .failed(.invalid("Attach at most ten photos.", "too_many")) }
        guard let target = Target(id, store: store) else { return .failed(.noSession) }
        return plan(message, text: ([text] + message.images).filter { !$0.isEmpty }.joined(separator: "\n"), target: target)
    }

    /// Carries out a plan. The answer comes once the text is in the pane, not once the agent read it.
    func send(_ plan: Plan, _ message: Message) async throws(Failure) -> ReplyResult {
        // Taken now, so the sweep `plan` started can't put it back while this delivers it.
        let putBack = message.promotes.flatMap { Self.promoting.removeValue(forKey: $0)?.putBack }
        let promotion = putBack.flatMap { _ in Promotion.waiting.next(.sendBegins)?.state }
        switch plan {
        case .failed, .done: break
        default: if message.promotes != nil, putBack == nil, Promotion.putBack.next(.sendBegins)?.state == .refused { throw .promotedBack }
        }
        do throws(Failure) {
            return try await deliver(plan, message)
        } catch {
            if promotion?.next(.sendFailed)?.putBack == true { putBack?() }
            if let key = message.idempotencyKey {
                for (session, list) in Self.delivered { Self.delivered[session] = list.filter { $0.key != key } }
            }
            throw error
        }
    }

    private func deliver(_ plan: Plan, _ message: Message) async throws(Failure) -> ReplyResult {
        let hosted = store.hosted
        do {
            switch plan {
            case .failed(let failure): throw failure
            case .done(let result): return result
            case .codex(let live, let key, let text, let queue):
                if let delivery = store.remote.receipts.answer(message.idempotencyKey, text: text) { return ReplyResult(delivery: delivery, sessionID: key) }
                do throws(CodexTerminals.Failure) {
                    return ReplyResult(delivery: try await store.remote.codex.send(live, text: text, queue: queue, key: message.idempotencyKey), sessionID: key)
                } catch { throw Failure.codex(error) }
            case .type(let name, let key, let working):
                // Codex mid-turn: a follow-up, or a reply sent to queue, waits for the turn to end; anything else steers
                // it, as through its app server. Claude queues what's submitted mid-turn either way.
                let queue = message.mode == .followUp || message.submit == .queue
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let waits = queue && working && store.hosted.sessions.first { $0.name == name }?.agent == .codex
                let receipts = store.remote.receipts
                if let delivery = receipts.answer(message.idempotencyKey, text: text) { return ReplyResult(delivery: delivery, sessionID: key) }
                // After Interrupt and Send's stop: what it took off the prompt goes first, in the same prompt, so this
                // never waits behind a turn of their own.
                let carried = receipts.carried(hosted: name)
                let typing = (carried.map(\.text) + [text]).filter { !$0.isEmpty }.joined(separator: "\n")
                if let live = store.sessions.live.first(where: { $0.hosted == name }) {
                    receipts.expect(message.idempotencyKey, text: typing, asked: text, live: live, delivery: waits ? .queued : .typed)
                } else if let agent = hosted.sessions.first(where: { $0.name == name })?.agent {
                    receipts.expect(message.idempotencyKey, text: typing, asked: text, hosted: name, agent: agent == .codex ? .codex : .claude,
                                    delivery: waits ? .queued : .typed)
                }
                receipts.join(carried.map(\.key), with: message.idempotencyKey, text: typing)
                do {
                    try await hosted.reply(name, text: typing, images: message.images, submit: queue ? .queue : .steer, working: working,
                                           key: message.idempotencyKey)
                } catch {
                    receipts.forget(message.idempotencyKey)
                    receipts.release(carried.map(\.key))
                    throw error
                }
                return ReplyResult(delivery: waits ? .queued : .typed, sessionID: key)
            case .keys(let name, let key, _):
                try await hosted.keys(name, (message.keys ?? []).map(\.rawValue))
                return ReplyResult(delivery: .typed, sessionID: key)
            case .terminal(let live, let key, let text):
                let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
                let transcript = live.provider == .claude ? live.sessionID.flatMap { AgentActivity.transcript(projects: projects, cwd: live.cwd, id: $0) } : nil
                let receipts = store.remote.receipts
                if let delivery = receipts.answer(message.idempotencyKey, text: text) { return ReplyResult(delivery: delivery, sessionID: key) }
                receipts.expect(message.idempotencyKey, text: text, live: live)
                do throws(TerminalTyping.Failure) { try await store.remote.typer.type(text, into: live, transcript: transcript) } catch {
                    receipts.forget(message.idempotencyKey)
                    throw Failure(status: 409, code: .cannotDeliver, message: error.message)
                }
                return ReplyResult(delivery: .typed, sessionID: key)
            }
        } catch let failure as Failure {
            throw failure
        } catch let error as HostedError {
            throw .hosted(error)
        } catch {
            throw Self.internalFailure("Side A couldn't type into that session.")
        }
    }

    func decide(_ message: Message, text: String, target: Target, current: Bool) -> Plan {
        let island = store.island
        let agent = target.live?.provider ?? .claude
        let hosted = target.live?.hosted
        let state = target.state(island)
        if let live = target.live, message.mode != .keys, store.remote.codex.reach(live) == .attached {
            switch state {
            case .waiting: return .failed(.cannotDeliver(message.mode == .note ? .cannot : .waiting))
            case .unknown: return .failed(.cannotDeliver(.cannot))
            default: if message.mode == .note { return .failed(.cannotDeliver(.cannot)) }
            }
            // Mid-turn a follow-up, or a reply sent to queue, waits for the turn to end; anything else steers it.
            // Idle, both start a turn. The TUI shows it as the user's message either way.
            let queue = state == .working && (message.mode == .followUp || message.submit == .queue)
            return .codex(live, key: target.key, text: text, queue: queue)
        }
        let hooks = island.installed[agent == .codex ? .codex : .claude] == true
        let decision = RemoteDelivery.decide(state, hosted: hosted != nil, agent: agent, mode: message.mode,
                                             // Codex mail goes by thread id, so a session without one yet takes none, nor
                                             // one whose hooks Codex hasn't been told to trust.
                                             mailHooks: hooks && target.live != nil
                                                 && (agent == .claude || (target.conversation != nil && island.codexMail != "review")),
                                             stopHooks: hooks && target.conversation != nil)
        switch decision {
        case .note:
            guard let live = target.live else { return .failed(.noSession) }
            do throws(Failure) { try mail("note", text: text, to: live) } catch { return .failed(error) }
            return .done(ReplyResult(delivery: .note, sessionID: target.key))
        case .queued:
            guard let conversation = target.conversation else { return .failed(.cannotDeliver(.setup)) }
            if let replaces = message.replaces {
                guard island.replaceQueued(conversation, id: replaces, with: text, from: message.origin) else { return .failed(.queueChanged) }
                return .done(ReplyResult(delivery: .queued, sessionID: target.key))
            }
            guard island.queue(conversation, text, from: message.origin) else { return .failed(.cannotDeliver(.queueFull)) }
            return .done(ReplyResult(delivery: .queued, sessionID: target.key))
        case .followUp:
            guard let conversation = target.conversation else { return .failed(.cannotDeliver(.cannot)) }
            guard let turnID = message.turnID ?? (current ? target.row?.id.uuidString.lowercased() : nil) else {
                return .failed(.invalid("Send the turn this follows up on.", "missing_turn"))
            }
            switch island.remoteFollowUp(session: conversation, turnID: turnID, text: text) {
            case .sent: return .done(ReplyResult(delivery: .followUp, sessionID: target.key))
            case .turnChanged:
                return .failed(Failure(status: 409, code: .turnChanged, message: "The session moved on since you read it. Look again before replying."))
            case .noWaiter: return inbox(text, target: target) ?? .failed(.cannotDeliver(.cannot))
            }
        case .typed:
            guard let hosted else { return .failed(.cannotDeliver(.notHosted)) }
            return .type(name: hosted, key: target.key, working: state == .working)
        case .keys:
            guard let hosted else { return .failed(.cannotDeliver(.notHosted)) }
            let open = island.remoteKeysGuard(conversation: target.conversation, pid: target.live?.pid)
            if open.destructive {
                return .failed(Failure(status: 409, code: .requestPending, message: "Answer the open request first; keys can't stand in for its Face ID."))
            }
            return .keys(name: hosted, key: target.key, guarded: open.pending)
        case .refused(let refusal):
            // Its turn paused on background work: the Stop hook that paused it waits for a note, so this reaches it.
            if state == .idle, message.mode != .keys, hooks, let live = target.live, live.provider == .claude, live.hosted == nil,
               (live.runningTasks ?? 0) > 0 {
                do throws(Failure) { try mail("note", text: text, to: live) } catch { return .failed(error) }
                return .done(ReplyResult(delivery: .note, sessionID: target.key))
            }
            if state == .idle, message.mode != .keys, let inboxed = inbox(text, target: target) { return inboxed }
            if state == .idle, message.mode == .auto || message.mode == .followUp, let live = target.live, store.remote.typer.reach(live) != nil {
                return .terminal(live, key: target.key, text: text)
            }
            return .failed(.cannotDeliver(refusal))
        }
    }

    /// Leaves the reply in the session's inbox when one of its hooks waits there; nil when none does.
    private func inbox(_ text: String, target: Target) -> Plan? {
        guard let live = target.live, live.provider == .claude, live.hosted == nil, store.remote.inbox.watching(live) else { return nil }
        guard store.remote.inbox.leave(text, to: live) else {
            return .failed(Self.internalFailure("Side A couldn't leave the message for this session."))
        }
        return .done(ReplyResult(delivery: .inbox, sessionID: target.key))
    }

    /// Hosted, `now` is Esc while it works; Codex in a terminal, its app server's interrupt. Otherwise stop mail,
    /// Claude only: `now` while working, `nextStep` while working or waiting. A Stop only stops: the phone's replies the
    /// agent hadn't read come back to it unsent. `send` (Interrupt and Send) keeps them for the reply that follows.
    /// `resend`: no reply follows, and what the stop took back goes again by itself as the next prompt.
    func interrupt(_ id: String, when: InterruptRequest.When = .now, send: Bool = false, resend: Bool = false) async throws(Failure) -> InterruptResult {
        guard let target = Target(id, store: store), let live = target.live else { throw .noSession }
        let state = target.state(store.island)
        let carry = send || resend
        if let hosted = live.hosted, when == .now {
            guard state == .working else { throw .cannotDeliver(.cannot) }
            let receipts = store.remote.receipts, panes = store.hosted
            let taken = await receipts.stopping(hosted: hosted)
            do { try await panes.interrupt(hosted, working: true) } catch {
                await receipts.stopped(taken.map(\.key), nil, carry: carry)
                throw (error as? HostedError).map(Failure.hosted) ?? Self.internalFailure("Side A couldn't type into that session.")
            }
            // Before answering: Interrupt and Send's message must find the prompt empty.
            if !taken.isEmpty { await receipts.stopped(taken.map(\.key), await panes.takeBack(hosted, sent: taken.map(\.text)), carry: carry) }
            if resend { await self.resend(hosted) }
            return InterruptResult(method: .escape)
        }
        if when == .now, store.remote.codex.reach(live) == .attached {
            guard state == .working else { throw .cannotDeliver(.cannot) }
            do throws(CodexTerminals.Failure) { try await store.remote.codex.interrupt(live, send: carry, resend: resend) } catch { throw .codex(error) }
            return InterruptResult(method: .turnInterrupt)
        }
        guard state == .working || (when == .nextStep && state == .waiting) else { throw .cannotDeliver(.cannot) }
        try mail("stop", to: live)
        return InterruptResult(method: .stop)
    }

    /// The receipts follow the one prompt they go in; one the pane's check finds unsent gives them all back.
    private func resend(_ hosted: String) async {
        let receipts = store.remote.receipts
        let carried = receipts.carried(hosted: hosted)
        guard let last = carried.last else { return }
        let text = carried.map(\.text).joined(separator: "\n")
        receipts.join(carried.map(\.key), with: nil, text: text)
        do { try await store.hosted.reply(hosted, text: text, submit: .steer, key: last.key) } catch { receipts.release(carried.map(\.key)) }
    }

    func takeBack(_ id: String) throws(Failure) {
        guard let live = Target(id, store: store)?.live else { throw .noSession }
        guard store.sessions.cancelMail(live) else {
            throw Failure(status: 404, code: .notFound, message: "The session already read it, so there's nothing to take back.")
        }
    }

    private func mail(_ kind: String, text: String? = nil, to live: LiveSession) throws(Failure) {
        do throws(SessionStore.MailError) {
            try store.sessions.leaveMail(kind, text: text, to: live)
        } catch {
            switch error {
            case .hooksOff, .empty: throw .cannotDeliver(.setup)
            case .notClaude: throw .cannotDeliver(.cannot)
            case .failed: throw Self.internalFailure("Side A couldn't leave the note for this session.")
            }
        }
    }
}

extension HostedError {
    /// What the phone acts on besides the code: a hosted failure it can try again, or one that names what is in the way.
    enum Hint: String, Equatable, Sendable {
        case composerBusy, alreadyLive, tryAgain
    }

    /// How a hosted failure answers the phone. The words are `errorDescription`, here and in the Sessions window.
    struct Answer: Equatable, Sendable {
        let status: Int
        let code: ErrorCode
        var hint: Hint?
        var retryAfter: Int?
    }

    var answer: Answer {
        switch self {
        case .unavailable: Answer(status: 503, code: .tmuxMissing, retryAfter: 60)
        case .sessionWaiting: Answer(status: 409, code: .sessionWaiting)
        case .notHosted: Answer(status: 409, code: .notHosted)
        case .composerBusy: Answer(status: 409, code: .cannotDeliver, hint: .composerBusy)
        case .alreadyLive: Answer(status: 409, code: .cannotDeliver, hint: .alreadyLive)
        case .refused: Answer(status: 409, code: .cannotDeliver)
        case .failed: Answer(status: 500, code: .internalError)
        case .notResumed: Answer(status: 502, code: .notResumed, hint: .tryAgain)
        }
    }
}
