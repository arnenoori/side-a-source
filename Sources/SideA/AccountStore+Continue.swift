import Foundation
import SideACore
import SideAProtocol

extension AccountStore {
    func setContinueStopped(_ enabled: Bool) {
        guard (config.continueStopped != false) != enabled else { return }
        config.continueStopped = enabled ? nil : false; persist()
    }

    var stoppedURL: URL { root.appendingPathComponent("runtime/stopped.json") }

    func stopped<T>(_ change: (inout StoppedSessions) -> T) -> T {
        var next = stoppedSessions
        let result = change(&next)
        guard next != stoppedSessions else { return result }
        stoppedSessions = next
        do { try PrivateFile.write(next, to: stoppedURL) } catch {
            autopilotLog.note("stopped", "Couldn't save which sessions a limit stopped: \(error.localizedDescription)")
        }
        return result
    }

    /// Sessions whose last reply is a limit error on an account that has room again, by when they stopped.
    func liftedSessions(now: Double) -> [String: Double] {
        let limited = sessionLimits(now: now)
        var lifted: [String: Double] = [:]
        for (id, hit) in limitHits {
            guard let value = usage[id], !value.stale, !hit.limit.hasPrefix("model:") || value.windows.contains(where: { $0.id == hit.limit }) else { continue }
            for session in hit.sessions where limited[session] == nil { lifted[session] = hit.at }
        }
        for (session, at) in codexStops(known: true) where limited[session] == nil { lifted[session] = at }
        for (session, stall) in stalls {
            switch stall.error {
            case "server_error": if Online.shared.value, now - stall.at >= StoppedSessions.retry, now - stall.at < StoppedSessions.interrupted { lifted[session] = stall.at }
            // A 429 that names no limit is the pool's, this Mac's or the one it joined, with every account out.
            default: if poolAnswers(now: now) { lifted[session] = stall.at }
            }
        }
        return lifted
    }

    /// Whether a Claude request through the pool would find an account now. Without a pool, such a 429 came from
    /// somewhere Side A can't see into, so it is simply tried again.
    private func poolAnswers(now: Double) -> Bool {
        if config.pool == true { return poolHasRoom(.claude, now: now) }
        return remotePool.map { $0.answered == true } ?? true
    }

    func continueStopped(now: Double) async {
        guard config.continueStopped != false else { return }
        // Before the sessions are listed, nothing is known to have gone.
        if !sessions.live.isEmpty {
            let commands = SessionCommands(store: self)
            stopped { $0.keepHolds(among: Set(sessions.live.filter { commands.status($0) != .working }.compactMap(\.sessionID))) }
        }
        let left = HelperRefusals(root: root).take()
        if !left.isEmpty { stopped { for (session, refusal) in left { $0.refuse(session, refusal.provider, at: refusal.at) } } }
        let lifted = liftedSessions(now: now)
        guard !stoppedSessions.isEmpty || !lifted.isEmpty || stoppedSessions.counting else { return }
        await continueDue(now: now, lifted: lifted)
    }

    private func continueDue(now: Double, lifted: [String: Double]) async {
        let commands = SessionCommands(store: self)
        var idle: Set<String> = [], working: Set<String> = []
        for live in sessions.live {
            guard let id = live.sessionID else { continue }
            switch commands.status(live) {
            case .idle, .finished: idle.insert(id)
            case .working: working.insert(id)
            default: break
            }
        }
        let due = stopped { $0.due(now: now, idle: idle, working: working, lifted: lifted) { poolHasRoom($0, now: now) } }
        for id in due {
            guard let live = sessions.live.first(where: { $0.sessionID == id }) else { continue }
            let project = sessions.project(of: live.cwd)
            do throws(SessionCommands.Failure) {
                _ = try await commands.reply(WireBuilders.key(live), SessionCommands.Message(text: StoppedSessions.prompt))
                stopped { $0.delivered(id) }
                autopilotLog.write(Autopilot.continuedPrefix + project)
            } catch {
                autopilotLog.write(Autopilot.notContinuedPrefix + "\(project): \(error.message)")
            }
        }
    }
}
