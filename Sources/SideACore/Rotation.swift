import Foundation

public extension Planner {
    /// Out on a 5-hour or weekly limit: Autopilot won't use it, and it is really at the limit, not just past a low Move at.
    /// A cap on one model alone never counts; see `isFableOut`.
    static func isLimited(_ usage: AccountUsage, now: Double, full: Double = Planner.full) -> Bool {
        (tightest(usage, now: now)?.percent ?? 0) >= max(full, limited)
    }

    /// Has room for other models but none for Fable. False on a plan without a Fable cap, which bills Fable as extra usage.
    static func isFableOut(_ usage: AccountUsage, now: Double, full: Double = Planner.full) -> Bool {
        guard !isLimited(usage, now: now, full: full), let fable = usage.forFable else { return false }
        return isLimited(fable, now: now, full: full)
    }

    /// When an account that `isLimited` or `isFableOut` gets its room back: the last of its full windows to reset.
    static func backAt(_ usage: AccountUsage, now: Double, full: Double = Planner.full) -> Double? {
        let plain = isLimited(usage, now: now, full: full) ? usage : usage.forFable
        guard let plain, isLimited(plain, now: now, full: full) else { return nil }
        return [live(plain.fiveHour, now), live(plain.weekly, now)].compactMap { $0 }.filter { $0.percent >= max(full, limited) }.compactMap(\.resetsAt).max()
    }

    /// The fuller of an account's running 5-hour and weekly windows.
    static func tightest(_ usage: AccountUsage, now: Double) -> UsageWindow? {
        [live(usage.fiveHour, now), live(usage.weekly, now)].compactMap { $0 }.max { $0.percent < $1.percent }
    }

    /// The account a login's sessions would go to once it fills up: never itself, never one in `busy`.
    static func next(after login: Account, among accounts: [Account], usage: [String: AccountUsage], health: [String: LoginHealth] = [:], busy: Set<String>, now: Double) -> String? {
        best(accounts.filter { $0.id != login.id && !busy.contains($0.id) }, usage: usage, health: health, active: nil, now: now)
    }
}

/// Why Autopilot moved a login, in the few words a row can hold.
public enum MoveReason {
    /// `usage` is the reading Autopilot planned with, so in Fable mode the window it names is Fable's.
    public static func text(from: Account, to: Account, usage: AccountUsage?, now: Double, full: Double = Planner.full) -> String {
        if let usage, let window = Planner.tightest(usage, now: now), window.percent >= full {
            return "\(window.label) \(window.text(at: now))"
        }
        if to.priority == .first, from.priority != .first { return "\(to.name) goes first" }
        if from.priority == .last, to.priority != .last { return "\(from.name) goes last" }
        return "\(to.name)'s week runs out sooner"
    }
}

/// One thing Autopilot did, kept whole, since a log line can't hold which sessions went. Names of accounts and
/// folders only: no session's title or words. The log itself stays for people reading it, and lines from before
/// these records stay without a reason.
public struct RotationRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case moved, newCommands, stuck, priorityWait }
    public struct Session: Codable, Equatable, Sendable {
        public let id: String
        public let project: String
        public init(id: String, project: String) { self.id = id; self.project = project }
    }
    public let at: Double
    public let kind: Kind
    public let from: String
    public let to: String?
    public let reason: String
    public let sessions: [Session]

    public init(at: Double, kind: Kind, from: String, to: String? = nil, reason: String, sessions: [Session] = []) {
        self.at = at; self.kind = kind; self.from = from; self.to = to; self.reason = reason; self.sessions = sessions
    }
}

/// When a provider's combined weekly room runs out at the user's pace.
///
/// Each account's pace is what it used over the share of its week gone by, at the user's weekly rhythm; a share under a
/// quarter of a week counts as a quarter, so a burst on a week just started doesn't read as the pace of a whole week.
/// The hours ahead then spend that pace, soonest-reset account first as Autopilot does, while resets refill their
/// accounts. Nil when that never empties them within a week, by which time every account has reset, and nil rather
/// than a guess when anything it needs is missing.
public enum CombinedRunOut {
    static let minimumShare = 0.25

    public static func estimate(_ members: [Account], usage: [String: AccountUsage], rhythm: WeekRhythm?, now: Double) -> Double? {
        guard let rhythm, !members.isEmpty else { return nil }
        struct Pot { var left: Double; let size: Double; var reset: Double? }
        var pots: [Pot] = []
        var pace = 0.0, longest = 0.0
        for account in members {
            guard let value = usage[account.id], !value.stale else { return nil }
            let size = max(value.capacity ?? 1, 0.01)
            guard let weekly = Planner.live(value.weekly, now), let reset = weekly.resetsAt else {
                pots.append(Pot(left: size * 100, size: size, reset: nil))
                continue
            }
            let used = min(max(weekly.percent, 0), 100), start = reset - 7 * 86_400
            longest = max(longest, now - start)
            pace += size * used / max(rhythm.share(from: start, to: now), minimumShare)
            pots.append(Pot(left: size * (100 - used), size: size, reset: reset))
        }
        guard longest >= 86_400, pace > 0 else { return nil }
        var moment = now
        let horizon = now + 7 * 86_400
        while moment < horizon {
            for index in pots.indices where (pots[index].reset ?? .infinity) <= moment {
                pots[index].left = pots[index].size * 100
                pots[index].reset = (pots[index].reset ?? 0) + 7 * 86_400
            }
            var burn = pace * rhythm.share(from: moment, to: moment + 3600)
            let hour = burn
            for index in pots.indices.sorted(by: { (pots[$0].reset ?? .infinity) < (pots[$1].reset ?? .infinity) }) where burn > 0 {
                let spent = min(pots[index].left, burn)
                pots[index].left -= spent
                burn -= spent
            }
            if burn > 0 { return moment + 3600 * (hour - burn) / hour }
            moment += 3600
        }
        return nil
    }
}
