import Foundation

extension Island {
    /// A queued follow-up goes out when its turn's Stop hook arrives. A turn that ended while Side A was closed or
    /// updating, or whose waiting hook died with the app, has no such hook left, so a session this long idle with
    /// something queued is not going to take it that way.
    static let strandedAfter: TimeInterval = 30
    /// A turn paused on background work (its Stop hook waits for a note, and never tells the island) is not mid-step, so
    /// what is queued for it goes after this much.
    static let pausedAfter: TimeInterval = 6

    /// Each read of the live list: `liveSessions`, then what a session that stopped without taking its queue is owed.
    func observeLive(_ live: [LiveSession], now: Date = Date()) {
        liveSessions(Set(live.compactMap(\.sessionID)), now: now)
        releaseStranded(live, now: now)
    }

    /// Idle for `strandedAfter` with follow-ups still waiting and no Stop hook to hand them to: they go to the session's
    /// inbox hook as one note when it has one, and are given back to the phone otherwise, never left as "queued" for good.
    func releaseStranded(_ live: [LiveSession], now: Date) {
        for session in queued.keys {
            let key = "idle:" + session
            guard let running = live.first(where: { $0.sessionID == session }), running.status == "idle", running.hosted == nil,
                  !hasWaiter(session) else {
                queuedGoneSince[key] = nil
                continue
            }
            let since = queuedGoneSince[key] ?? now
            queuedGoneSince[key] = since
            guard now.timeIntervalSince(since) >= ((running.runningTasks ?? 0) == 0 ? Self.strandedAfter : Self.pausedAfter) else { continue }
            queuedGoneSince[key] = nil
            hand(session, to: running)
        }
        for key in queuedGoneSince.keys where key.hasPrefix("idle:") && queued[String(key.dropFirst(5))] == nil { queuedGoneSince[key] = nil }
    }

    private func hand(_ session: String, to running: LiveSession) {
        guard let items = queued[session], !items.isEmpty else { return }
        let inbox = store?.remote.inbox
        // A paused turn's Stop hook waits for mail, so a note wakes it; one that simply ended has an inbox hook or nothing.
        let paused = (running.runningTasks ?? 0) > 0
        guard paused || inbox?.watching(running) == true, let inbox else {
            RemoteLog.shared("queued: \(items.count) for session \(session.prefix(8)) stranded, the turn ended without its Stop hook; giving them back")
            return dropQueued(session, .cannotWait)
        }
        var kept: [(text: String, origin: QueuedFollowUp.Origin?)] = []
        queued[session] = nil
        saveQueued()
        for case .waiting(let text, let origin) in items {
            if let origin, origin.proven < queuedNeeds(session) {
                reportDropped(session, text, .outranked, from: origin)
            } else {
                kept.append((text, origin))
            }
        }
        guard !kept.isEmpty else { return }
        let joined = kept.map(\.text).joined(separator: "\n\n")
        guard paused ? leaveNote(joined, to: running) : inbox.leave(joined, to: running) else {
            RemoteLog.shared("queued: \(kept.count) for session \(session.prefix(8)) stranded and the inbox refused them; giving them back")
            for item in kept { reportDropped(session, item.text, .cannotWait, from: item.origin) }
            return
        }
        RemoteLog.shared("queued: \(kept.count) for session \(session.prefix(8)) stranded; left in its inbox")
        for item in kept { watcher?.queued(session: session, text: item.text, became: .delivered) }
    }

    private func leaveNote(_ text: String, to running: LiveSession) -> Bool {
        do {
            try store?.sessions.leaveMail("note", text: text, to: running)
            return store != nil
        } catch {
            return false
        }
    }
}
