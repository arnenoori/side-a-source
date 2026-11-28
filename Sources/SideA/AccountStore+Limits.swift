import Foundation
import SideACore
import SideAProtocol

extension AccountStore {
    /// Running Codex conversations whose last turn ended on the plan's limit, by when. `known` leaves out those whose
    /// account Side A can't name: with no reading to wait on, they are the user's to send on.
    func codexStops(known: Bool = false) -> [String: Double] {
        var found: [String: Double] = [:]
        for live in sessions.live where live.provider == .codex {
            guard let id = live.sessionID, let error = live.lastError, let at = error.at, CodexLimit.stopped(error.text) else { continue }
            if known, sessions.accountID(of: live, agent: .codex) == nil { continue }
            found[id] = at
        }
        return found
    }

    /// Those still under their limit.
    func codexLimits(now: Double) -> [String: SessionLimit] {
        var found: [String: SessionLimit] = [:]
        let stops = codexStops()
        for live in sessions.live where live.provider == .codex {
            guard let id = live.sessionID, let at = stops[id], let account = sessions.accountID(of: live, agent: .codex) else { continue }
            found[id] = CodexLimit.limit(account: account, usage: usage[account], read: readAt[account]?.timeIntervalSince1970, stoppedAt: at, now: now)
        }
        return found
    }

    /// Whether a session stopped on a limit is sent on when the limit lifts: the setting, unless the user held this one.
    func continues(_ session: String) -> Bool { config.continueStopped != false && !stoppedSessions.holds(session) }

    func setContinues(_ session: String, _ on: Bool) {
        stopped { $0.hold(session, !on) }
        remote.events?.liveChanged()
    }
}
