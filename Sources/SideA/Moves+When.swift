import Foundation
import SideACore
import SideAProtocol

/// Moving a session that is working (docs/moving-sessions-prd.md, 4.6). After This Turn waits for the turn to end and
/// is written down, so it outlives a quit; Now interrupts the turn as the Stop button does and moves once the session
/// is idle. Either goes through `prepare` and `run` then, with every check asked again, under the id it was given.
extension Moves {
    struct Waiting: Codable, Sendable, Identifiable {
        let id: String
        let conversation: String
        let agent: AgentProvider
        let title: String?
        let project: String?
        let computer: String
        let computerName: String
        let when: MoveRequest.When
        let at: Double
        /// A yes given for one turn's end does not stand for a turn that never ends.
        let until: Double
    }

    /// A session that did not leave, with the reason.
    struct Stayed: Identifiable {
        let session: LiveSession
        let reason: String
        var id: Int { session.pid }
        var title: String { session.title ?? session.name ?? "A session" }
    }

    enum Cancel { case cancelled, started, none }

    static let waitsFor = 2 * 3600.0

    private var waitingURL: URL { folder.appendingPathComponent("waiting.json") }

    /// Why `session` cannot move `when` asked, or nil. Idle is the plain move's rule.
    static func refusal(_ session: LiveSession, when: MoveRequest.When) -> String? {
        switch when {
        case .idle: return refusal(session)
        case .afterTurn, .now:
            if let refusal = unmovable(session) { return refusal }
            switch session.status {
            case "idle", "busy", "shell": return nil
            case "waiting": return when == .now ? "It's waiting for an answer. Answer it first, or move it after this turn." : nil
            default: return "Side A can't tell yet whether it's working. Try again in a moment."
            }
        default: return "Side A on this Mac can't move a session that way. Update it first."
        }
    }

    func waitingMove(for conversation: String?) -> Waiting? {
        conversation.flatMap { id in waiting.values.first { $0.conversation == id } }
    }

    // MARK: Asking

    /// Asks for `session` to move to `peer`: `afterTurn` when its turn ends, `now` after interrupting it, `idle` at once.
    /// Both computers are asked first and a refusal is thrown with nothing stopped. Returns without waiting for the move;
    /// `records()` follows it under the returned id.
    func request(_ session: LiveSession, to peer: any MovePeer, when: MoveRequest.When) async throws -> MoveRecord {
        guard when != .idle else { return try await start(session, to: peer) }
        // Its agent has exited: there is no turn to wait for or stop.
        if try await endedArrival(of: session) != nil { return try await start(session, to: peer) }
        if let refusal = Self.refusal(session, when: when) { throw MoveFailure.refused(refusal) }
        guard let conversation = session.sessionID else { throw MoveFailure.refused("That session can't move.") }
        guard waitingMove(for: conversation) == nil else { throw MoveFailure.refused("It's already waiting to move.") }
        let plan = try await prepare(session, to: peer, when: when)
        await withdraw(plan, from: peer)
        // Asked again: a second request may have come in while both computers were asked.
        guard waitingMove(for: conversation) == nil else { throw MoveFailure.refused("It's already waiting to move.") }
        let request = Waiting(id: Self.moveID(), conversation: conversation, agent: session.provider, title: plan.offer.title, project: plan.offer.project,
                              computer: peer.id, computerName: peer.name, when: when, at: now(), until: now() + Self.waitsFor)
        waiting[request.id] = request
        if when == .now {
            firing.insert(request.id)
            running[request.id] = Task { [weak self] in
                await self?.stopAndMove(request, session, to: peer)
                self?.running[request.id] = nil
            }
        } else {
            saveWaiting()
            watchWaiting()
        }
        return record(of: request)
    }

    /// Cancels a move that is still waiting for its turn to end.
    @discardableResult
    func cancel(_ id: String) -> Cancel {
        guard let request = waiting[id] else { return journal[id] == nil ? .none : .started }
        guard !firing.contains(id) else { return .started }
        finish(request, failed: "The move was cancelled.", listed: false, told: false)
        return .cancelled
    }

    /// Waits for a requested move to end: nil when the session moved, otherwise why it didn't.
    func outcome(of id: String) async -> String? {
        if waiting[id] != nil { return await withCheckedContinuation { awaiting[id, default: []].append($0) } }
        if journal[id]?.step == .away { return nil }
        return failures[id]?.message ?? "It didn't move."
    }

    // MARK: Going

    /// Passes over the waiting moves while there are any. Started when one is asked for and when Remote comes up.
    func watchWaiting() {
        guard watcher == nil else {
            Task { await checkWaiting() }
            return
        }
        guard waiting.values.contains(where: { $0.when == .afterTurn }) else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let every = self?.watchEvery, self?.waiting.values.contains(where: { $0.when == .afterTurn }) == true else { break }
                await self?.checkWaiting()
                do { try await Task.sleep(for: every) } catch { break }
            }
            self?.watcher = nil
        }
    }

    /// One pass: a session whose turn has ended goes; a request whose session ended, whose computer was unlinked, or
    /// that waited too long is dropped and the person told.
    func checkWaiting() async {
        guard waiting.values.contains(where: { $0.when == .afterTurn && !firing.contains($0.id) }), var sessions = await live() else { return }
        for request in waiting.values.sorted(by: { $0.at < $1.at }) where request.when == .afterTurn {
            // Each is looked at again: the move before it was awaited, and this one may have been cancelled meanwhile.
            guard waiting[request.id] != nil, !firing.contains(request.id), !claimed.contains(request.conversation) else { continue }
            // Moved some other way meanwhile (the phone's plain Move, say): nothing is left to wait for.
            guard journal.ownership(of: request.conversation).mayRun else {
                finish(request, failed: "It had already moved.", listed: false, told: false)
                continue
            }
            guard let peer = peer(request.computer) else {
                finish(request, failed: "\(request.computerName) isn't linked any more, so it stayed here.")
                continue
            }
            guard let session = sessions.first(where: { $0.sessionID == request.conversation && $0.hosted != nil }) else {
                finish(request, failed: "It ended before its turn did.", told: false)
                continue
            }
            guard now() < request.until else {
                finish(request, failed: "Its turn was still going after two hours, so it stayed here.")
                continue
            }
            guard session.status == "idle" else { continue }
            firing.insert(request.id)
            await go(request, session, to: peer)
            // Minutes may have passed: the next one is judged on a list read after this move.
            sessions = await live() ?? sessions
        }
    }

    /// Now: the turn is stopped the way the Sessions window stops it, and the session moves once it is idle. If it
    /// doesn't settle in `stopsWithin`, nothing moves and it carries on here.
    private func stopAndMove(_ request: Waiting, _ session: LiveSession, to peer: any MovePeer) async {
        var session = session
        if session.status != "idle" {
            do {
                if let interrupt { try await interrupt(session) } else { try await hosted.interrupt(session.hosted ?? "", working: true) }
            } catch {
                return finish(request, failed: "Side A couldn't stop its turn, so it's still running here.", told: false)
            }
            guard let stopped = await whenIdle(request.conversation) else {
                return finish(request, failed: "It didn't stop working, so it's still running here.", told: false)
            }
            session = stopped
        }
        await go(request, session, to: peer, told: false)
    }

    private func whenIdle(_ conversation: String) async -> LiveSession? {
        let end = ContinuousClock.now + stopsWithin
        while ContinuousClock.now < end {
            if let found = await live()?.first(where: { $0.sessionID == conversation && $0.hosted != nil }), found.status == "idle" { return found }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return nil }
        }
        return nil
    }

    private func go(_ request: Waiting, _ session: LiveSession, to peer: any MovePeer, told: Bool = true) async {
        firing.insert(request.id)
        // Off the disk before anything is asked: after a quit from here on, the journal says what happened, never this.
        saveWaiting()
        do {
            _ = try await run(try await prepare(session, to: peer, id: request.id), to: peer)
            finish(request, failed: nil)
        } catch {
            // An unknown outcome is the journal's to show, with Check Again; it is not a failure.
            let unknown = if case MoveFailure.unknown = error { true } else { false }
            finish(request, failed: (error as? MoveFailure)?.errorDescription ?? Self.sentence(error, peer: peer.name), told: told && !unknown)
        }
        await finished()
    }

    /// The request is over: it moved (`failed` nil), or was refused, cancelled or dropped. Whoever waits on it hears.
    private func finish(_ request: Waiting, failed reason: String?, listed: Bool = true, told: Bool = true) {
        waiting[request.id] = nil
        firing.remove(request.id)
        saveWaiting()
        if let reason, listed, failures[request.id] == nil, journal[request.id]?.step != .unknown {
            failures[request.id] = Failed(entry: entry(for: request), message: reason, at: now())
        }
        if let reason, listed, told { tell("\(request.title ?? "A session") stayed here: \(reason)") }
        for waiter in awaiting.removeValue(forKey: request.id) ?? [] { waiter.resume(returning: reason) }
    }

    // MARK: Lists

    private func entry(for request: Waiting) -> MoveJournal.Entry {
        var entry = MoveJournal.Entry(id: request.id, role: .source, session: request.conversation, agent: request.agent.rawValue,
                                      peer: request.computer, peerName: request.computerName, step: .returned, at: request.at)
        entry.title = request.title
        entry.project = request.project
        return entry
    }

    func record(of request: Waiting) -> MoveRecord {
        MoveRecord(id: request.id, conversationID: request.conversation, agent: request.agent, title: request.title, project: request.project,
                   state: request.when == .afterTurn && !firing.contains(request.id) ? .waiting : .moving,
                   computer: request.computer, computerName: request.computerName, at: request.at)
    }

    /// The waiting ones `records()` lists; once a move has a journal entry or a failure, that speaks for it.
    func waitingRecords() -> [MoveRecord] {
        waiting.values.filter { journal[$0.id] == nil && failures[$0.id] == nil }.map(record(of:))
    }

    func loadWaiting() {
        guard let data = FileManager.default.contents(atPath: waitingURL.path) else { return }
        do {
            waiting = try JSONDecoder().decode([String: Waiting].self, from: data).filter { $0.value.when == .afterTurn }
        } catch { RemoteLog.shared("couldn't read the moves waiting for a turn: \(error.localizedDescription)") }
    }

    /// Only After This Turn is written down, and only until it starts: a Now cut short by a quit leaves the session here.
    private func saveWaiting() {
        let kept = waiting.filter { $0.value.when == .afterTurn && !firing.contains($0.key) }
        do { try PrivateFile.write(kept, to: waitingURL) } catch { RemoteLog.shared("couldn't save the moves waiting for a turn: \(error.localizedDescription)") }
    }

    // MARK: Move and Sleep

    /// Every one of `sessions` leaves for `peer`: idle ones now, one after another, and working ones as `working` says.
    /// Returns once each has gone or failed, with what stayed.
    func leave(_ sessions: [LiveSession], to peer: any MovePeer, working: MoveRequest.When) async -> [Stayed] {
        var stayed: [Stayed] = [], later: [(LiveSession, String)] = [], idle: [LiveSession] = []
        for session in sessions {
            if let reason = Self.unmovable(session) {
                stayed.append(Stayed(session: session, reason: reason))
            } else if session.status == "idle" {
                idle.append(session)
            } else if let already = waitingMove(for: session.sessionID) {
                later.append((session, already.id))
            } else {
                do { later.append((session, try await request(session, to: peer, when: working).id)) } catch {
                    stayed.append(Stayed(session: session, reason: error.localizedDescription))
                }
            }
        }
        for session in idle {
            do { try await send(session, to: peer) } catch { stayed.append(Stayed(session: session, reason: error.localizedDescription)) }
        }
        for (session, id) in later {
            if let reason = await outcome(of: id) { stayed.append(Stayed(session: session, reason: reason)) }
        }
        return stayed
    }

    /// Move and Sleep: `leave`, then the Mac sleeps. When something stayed and is still working here, it doesn't:
    /// `leftWorking` lists what stayed for the person to decide.
    @discardableResult
    func leaveAndSleep(_ sessions: [LiveSession], to peer: any MovePeer, working: MoveRequest.When) async -> [Stayed] {
        sleepsAfter = peer.name
        leftWorking = nil
        let stayed = await leave(sessions, to: peer, working: working)
        // Don't Sleep was chosen while they left.
        guard sleepsAfter != nil else { return stayed }
        sleepsAfter = nil
        guard !stayed.isEmpty else {
            await sleep()
            return stayed
        }
        guard let now = await live() else {
            leftWorking = stayed
            return stayed
        }
        let busy = stayed.contains { left in
            now.contains { ($0.sessionID != nil ? $0.sessionID == left.session.sessionID : $0.pid == left.session.pid) && $0.status != "idle" }
        }
        if busy {
            leftWorking = stayed
        } else {
            tell(Self.line(stayed))
            await sleep()
        }
        return stayed
    }

    func sleepAnyway() async {
        leftWorking = nil
        await sleep()
    }

    func stayAwake() {
        sleepsAfter = nil
        leftWorking = nil
    }

    static func line(_ stayed: [Stayed]) -> String {
        guard let first = stayed.first else { return "" }
        return stayed.count == 1 ? "\(first.title) stayed here: \(first.reason)" : "\(stayed.count) sessions stayed here. \(first.reason)"
    }
}
