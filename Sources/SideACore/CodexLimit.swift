import Foundation
import SideAProtocol

/// A Codex session its plan's limit stopped. Codex says so in the turn's error and nowhere else, and gives the reset
/// only in words, so the account's own reading says when the session can go on.
public enum CodexLimit {
    /// Whether a turn's error is the plan's limit ("You've hit your usage limit. … try again at 3:40 PM.").
    public static func stopped(_ text: String) -> Bool {
        let text = text.lowercased()
        return text.contains("usage limit") || text.contains("usage_limit")
    }

    /// The limit a session that stopped at `stoppedAt` is still under, or nil once its account has room. `read` is
    /// when `usage` was taken: a reading from before the stop can't show it, so it isn't taken as room.
    public static func limit(account: String, usage: AccountUsage?, read: Double?, stoppedAt: Double, now: Double) -> SessionLimit? {
        let live = [usage?.fiveHour, usage?.weekly].compactMap { Planner.live($0, now) }
        let fullest = live.max { $0.percent < $1.percent }
        // A reading with no windows says nothing either way.
        if let usage, !usage.stale, let read, read >= stoppedAt, usage.fiveHour != nil || usage.weekly != nil {
            guard let fullest, fullest.percent >= Planner.limited else { return nil }
            return SessionLimit(window: fullest.id, accountID: account, until: fullest.resetsAt)
        }
        if let fullest, fullest.percent >= Planner.limited {
            return SessionLimit(window: fullest.id, accountID: account, until: fullest.resetsAt)
        }
        // Nothing read since: the 5-hour window is the one a turn runs into, and it is over by then at the latest.
        let worst = stoppedAt + UsageWindow.seconds(of: "five_hour")
        return worst > now ? SessionLimit(window: "five_hour", accountID: account, until: worst, worstCase: true) : nil
    }
}
