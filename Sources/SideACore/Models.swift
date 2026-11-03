import Foundation

public struct Account: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var email: String
    public var ready: Bool
    public var allowAuto: Bool
    public var provider: AgentProvider
    /// Which accounts Autopilot and the pool spend before the others. Nil means normal.
    public var priority: AccountPriority?

    public init(id: String = UUID().uuidString.lowercased(), name: String, email: String = "",
                ready: Bool = false, allowAuto: Bool = false, provider: AgentProvider = .claude, priority: AccountPriority? = nil) {
        self.id = id; self.name = name; self.email = email
        self.ready = ready; self.allowAuto = allowAuto; self.provider = provider; self.priority = priority
    }
    private enum CodingKeys: String, CodingKey { case id, name, email, ready, allowAuto, provider, priority }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        email = try values.decode(String.self, forKey: .email)
        ready = try values.decode(Bool.self, forKey: .ready)
        allowAuto = try values.decode(Bool.self, forKey: .allowAuto)
        // Existing v1 libraries contain Claude profiles. Never reassign their identity.
        provider = try values.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .claude
        priority = try? values.decodeIfPresent(AccountPriority.self, forKey: .priority)
    }
}

/// First accounts are spent while any has room; Last ones only once every other is out, like
/// an account that bills extra usage or one kept free for another Mac.
public enum AccountPriority: String, Codable, CaseIterable, Sendable {
    case first, normal, last
    public var rank: Int { switch self { case .first: 0; case .normal: 1; case .last: 2 } }
    public var title: String { switch self { case .first: "First"; case .normal: "Normal"; case .last: "Last" } }
}

public struct Configuration: Codable, Equatable, Sendable {
    public var version = 2
    public var accounts: [Account] = []
    public var selectedID: String?
    /// Autopilot: switch the Mac-wide account and start idle 5-hour windows.
    public var smartMode = true
    public var menuBarOnly = true
    /// Shares token totals with the user's other Macs through iCloud Drive. Nil means off.
    public var sync: Bool?
    /// While Claude Code runs Fable, Autopilot ranks accounts by Fable headroom. Nil means on.
    public var followFable: Bool?
    /// Live limits from Claude Code's statusline; nil means not yet decided (on by default).
    public var liveLimits: Bool?
    /// The 5-hour or weekly percentage at which Autopilot moves off an account. Nil means 95.
    public var swapAt: Double?
    public var moveAt: Double { swapAt ?? 95 }
    /// A question with a recommended choice, or a plan, is answered after a minute unanswered. Nil means off.
    public var answerRecommended: Bool?
    /// Claude Code in Terminal goes through Side A's local proxy, which picks an account per conversation. Nil means off.
    public var pool: Bool?
    /// Pool mode also serves the user's other Macs over Tailscale. Nil means off.
    public var poolShare: Bool?
    /// Logins the user removed, as "provider:email", so a Mac login Side A finds again isn't added back on its own.
    public var removedLogins: [String]?
    public init() {}

    public var selected: Account? { accounts.first { $0.id == selectedID } }
    private static func loginKey(_ email: String, _ provider: AgentProvider) -> String { "\(provider.rawValue):\(email.lowercased())" }
    public func wasRemoved(_ email: String, _ provider: AgentProvider) -> Bool {
        removedLogins?.contains(Self.loginKey(email, provider)) == true
    }
    /// Removing an account remembers its login; an account without an email has none to remember.
    public mutating func noteRemoved(_ account: Account) {
        guard !account.email.isEmpty, !wasRemoved(account.email, account.provider) else { return }
        removedLogins = (removedLogins ?? []) + [Self.loginKey(account.email, account.provider)]
    }
    /// Signing an account in, or adding it by hand, takes back its removal.
    public mutating func forgetRemoval(_ email: String, _ provider: AgentProvider) {
        guard wasRemoved(email, provider) else { return }
        removedLogins?.removeAll { $0 == Self.loginKey(email, provider) }
        if removedLogins?.isEmpty == true { removedLogins = nil }
    }
    public mutating func step(_ offset: Int) {
        guard !accounts.isEmpty else { selectedID = nil; return }
        let current = accounts.firstIndex { $0.id == selectedID } ?? 0
        selectedID = accounts[((current + offset) % accounts.count + accounts.count) % accounts.count].id
    }
    public func validated() throws -> Configuration {
        guard version == 1 || version == 2 else { throw StorageError.unsupportedVersion }
        guard Set(accounts.map(\.id)).count == accounts.count,
              accounts.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              selectedID == nil || accounts.contains(where: { $0.id == selectedID }) else {
            throw StorageError.invalidConfiguration
        }
        var migrated = self
        // Prevent older releases from decoding Codex profiles as Claude and
        // overwriting their provider discriminator when saving the library.
        migrated.version = 2
        return migrated
    }
}

// UsageWindow, ExtraUsage and AccountUsage live in SideAProtocol; these rules are Autopilot policy.
public extension AccountUsage {
    /// The reading after a session reported hitting the limit `id` at `at`. The reply says when it
    /// resets only in words, so a known future reset is kept, else the longest it could take.
    func hitting(_ id: String, at: Double) -> AccountUsage {
        var copy = self
        let index = copy.windows.firstIndex { $0.id == id }
        let known = index.flatMap { copy.windows[$0].resetsAt }.flatMap { $0 > at ? $0 : nil }
        let label = ["five_hour": "5-hour", "seven_day": "Weekly"][id] ?? "Weekly " + id.dropFirst(6).capitalized
        let window = UsageWindow(id: id, label: index.map { copy.windows[$0].label } ?? label, percent: 100,
                                 resetsAt: known ?? at + (id == "five_hour" ? 5 * 3600 : 7 * 86_400))
        if let index { copy.windows[index] = window } else { copy.windows.append(window) }
        copy.stale = false
        return copy
    }

    /// The account as Fable sees it. Fable may use half of the weekly limit, so its room is the
    /// smaller of what is left of the Fable cap and twice what is left of the weekly limit.
    /// Nil for a plan without a Fable cap, where Fable is billed as extra usage.
    var forFable: AccountUsage? {
        // ponytail: assumes the Fable percent is of the Fable cap (100 = limited), like every other window.
        let fable = windows.first { $0.id == "model:fable" }
        // A Max plan whose usage lists no Fable cap yet has its whole Fable share left.
        guard fable != nil || (capacity ?? 1) >= 5 else { return nil }
        let room = min(100 - (fable?.percent ?? 0), 2 * (100 - (weekly?.percent ?? 0)))
        var copy = self
        copy.windows = windows.filter { $0.id != "seven_day" }
            + [UsageWindow(id: "seven_day", label: "Weekly Fable", percent: max(100 - room, 0), resetsAt: fable?.resetsAt ?? weekly?.resetsAt)]
        copy.capacity = (capacity ?? 1) / 2
        return copy
    }
}

public struct TokenRow: Codable, Hashable, Sendable {
    public var date: String?
    public var project: String?
    public var model: String?
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    public var total: Int { input + output + cacheWrite + cacheRead }
    public init(date: String? = nil, project: String? = nil, model: String? = nil, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
        self.date = date; self.project = project; self.model = model
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
}

public struct ActivitySpan: Codable, Equatable, Sendable {
    public var date: String
    /// Responses per local hour, 0 to 23.
    public var hours: [Int]
    public init(date: String, hours: [Int]) { self.date = date; self.hours = hours }
}

/// Local Claude Code token use, read from transcripts the way ccusage does.
public struct UsageReport: Codable, Equatable, Sendable {
    public var days: [TokenRow]
    public var projects: [TokenRow]
    public var models: [TokenRow]
    public var activity: [ActivitySpan]
    /// Each day split by model; absent in reports cached by older versions.
    public var dayModels: [TokenRow]?
    /// Macs sharing totals through sync, this one included; empty or absent without sync.
    public var machines: [Machine]?
    /// Accounts set up on another Mac but not on this one.
    public var elsewhere: [SyncedAccount]?
    public init(days: [TokenRow], projects: [TokenRow], models: [TokenRow], activity: [ActivitySpan], dayModels: [TokenRow]? = nil,
                machines: [Machine]? = nil, elsewhere: [SyncedAccount]? = nil) {
        self.days = days; self.projects = projects; self.models = models; self.activity = activity; self.dayModels = dayModels
        self.machines = machines; self.elsewhere = elsewhere
    }
}

public struct Machine: Codable, Hashable, Sendable {
    public var name: String
    /// Tokens in the last seven days.
    public var tokens: Int
    public var updated: Double
    public var current: Bool
    public init(name: String, tokens: Int, updated: Double, current: Bool) {
        self.name = name; self.tokens = tokens; self.updated = updated; self.current = current
    }
}

/// An account set up on another Mac, from iCloud sync.
public struct SyncedAccount: Codable, Hashable, Sendable {
    public var name: String
    public var email: String
    public var provider: AgentProvider
    public var machine: String
}

/// The user's usual working hours, learned from when transcripts show activity.
public struct WorkSchedule: Equatable, Sendable {
    /// Typical start and end of the working day, in minutes after local midnight.
    public var start: Int
    public var end: Int
    public static let lead = 120

    /// The day starts right after the longest quiet run of hours over the last 14 active days,
    /// so work that crosses midnight still counts as one day. Nil until a week of history
    /// exists, or when there is no quiet stretch of at least four hours (agents running all day).
    public init?(_ activity: [ActivitySpan]) {
        let recent = activity.suffix(14)
        guard recent.count >= 7 else { return nil }
        let totals = (0..<24).map { hour in recent.reduce(0) { $0 + ($1.hours.indices.contains(hour) ? $1.hours[hour] : 0) } }
        let quiet = totals.map { Double($0) <= Double(totals.max() ?? 0) * 0.2 }
        var best = (start: 0, length: 0)
        for first in 0..<24 where quiet[first] && !quiet[(first + 23) % 24] {
            var length = 0
            while length < 24, quiet[(first + length) % 24] { length += 1 }
            if length > best.length { best = (first, length) }
        }
        guard best.length >= 4, best.length < 24 else { return nil }
        start = (best.start + best.length) % 24 * 60
        end = best.start * 60
    }
    public init(start: Int, end: Int) { self.start = start; self.end = end }

    /// Priming starts two hours before the usual start, so the first window resets mid-session,
    /// and continues through the working day. Overnight windows would only lapse unused.
    public func allowsPriming(atMinute minute: Int) -> Bool {
        let from = (start - Self.lead + 1440) % 1440
        let span = (end - from + 1440) % 1440
        return (minute - from + 1440) % 1440 <= span
    }
}

/// When in the week the user works, from hourly activity over the last four weeks, so a
/// weekly forecast follows their rhythm (quiet weekends, busy afternoons) rather than a straight line.
public struct WeekRhythm: Sendable {
    /// Average responses per [weekday 0...6, Sunday first][hour].
    var weights: [[Double]]
    let calendar: Calendar
    var total: Double { weights.joined().reduce(0, +) }

    public init?(_ activity: [ActivitySpan], calendar: Calendar = .current) {
        let recent = activity.suffix(28)
        guard recent.count >= 7 else { return nil }
        var weights = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        let parse = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()
        var days = Array(repeating: 0.0, count: 7)
        for span in recent {
            guard let date = try? parse.parse(span.date) else { continue }
            let weekday = calendar.component(.weekday, from: date) - 1
            days[weekday] += 1
            for (hour, count) in span.hours.prefix(24).enumerated() { weights[weekday][hour] += Double(count) }
        }
        // Days without a span count as idle; every hour keeps a small floor so a rare hour is unlikely, not impossible.
        let weeks = max(days.max() ?? 1, 1)
        let sum = weights.joined().reduce(0, +) / weeks
        guard sum > 0 else { return nil }
        self.weights = weights.map { $0.map { $0 / weeks + sum / 168 * 0.05 } }
        self.calendar = calendar
    }

    /// Expected share of a week's activity between two moments, at most one week apart.
    public func share(from start: Double, to end: Double) -> Double {
        var moment = start, sum = 0.0
        while moment < end {
            let date = Date(timeIntervalSince1970: moment)
            let parts = calendar.dateComponents([.weekday, .hour, .minute, .second], from: date)
            let next = min(end, moment + 3600 - Double((parts.minute ?? 0) * 60 + (parts.second ?? 0)))
            sum += weights[(parts.weekday ?? 1) - 1][parts.hour ?? 0] * (next - moment) / 3600
            moment = next
        }
        return sum / total
    }

    /// When cumulative activity from `start` reaches `fraction` of a week, searching up to `limit`.
    public func moment(reaching fraction: Double, from start: Double, limit: Double) -> Double? {
        var moment = start, sum = 0.0
        while moment < limit {
            let piece = share(from: moment, to: moment + 3600)
            if sum + piece >= fraction { return moment + 3600 * (fraction - sum) / piece }
            sum += piece; moment += 3600
        }
        return nil
    }
}

/// A weekly window projected to its reset at the user's rhythm.
public struct WeekForecast: Equatable, Sendable {
    /// Expected percent used by the reset, uncapped.
    public var projected: Double
    /// Where usage would be now if the week followed the rhythm exactly, 0 to 1.
    public var expectedNow: Double
    /// When the limit is reached at this pace, if before the reset.
    public var runsOut: Double?

    public init?(_ window: UsageWindow, rhythm: WeekRhythm?, now: Double) {
        guard let reset = window.resetsAt, reset > now else { return nil }
        let start = reset - 7 * 86_400, used = min(max(window.percent, 0), 100)
        let elapsed = rhythm?.share(from: start, to: now) ?? min(max((now - start) / (7 * 86_400), 0), 1)
        expectedNow = elapsed
        // Too early in the week to say anything about pace.
        guard elapsed > 0.05, used > 0 else { projected = used; runsOut = nil; return }
        projected = used / elapsed
        guard projected >= 100 else { runsOut = nil; return }
        let needed = (100 - used) / projected
        runsOut = rhythm?.moment(reaching: needed, from: now, limit: reset) ?? (start + (now - start) * 100 / used)
    }
}

/// Decides which account should hold the Mac-wide login, and which idle windows to start.
/// Weekly quota is what expires unused, so the account that must burn quota fastest
/// before its weekly reset goes first; among near-ties, the 5-hour window that resets
/// soonest is used before it refills.
public enum Planner {
    /// Accounts Autopilot could use if they were signed in.
    public static func signedOut(_ accounts: [Account], except id: String, health: [String: LoginHealth]) -> [Account] {
        accounts.filter { $0.id != id && $0.allowAuto && (!$0.ready || health[$0.id]?.takesWork == false) }
    }

    /// Where Autopilot leaves an account; the app sets it from Settings.
    nonisolated(unsafe) public static var full = 97.0
    /// Where an account shows as limited.
    public static let limited = 97.0
    /// Autopilot moves only to an account below this; it follows a lower Move at setting.
    public static var switchTarget: Double { min(90, full - 5) }
    static let week = 7 * 24 * 3600.0

    static func live(_ window: UsageWindow?, _ now: Double) -> UsageWindow? {
        guard let window, let reset = window.resetsAt, reset > now else { return nil }
        return window
    }

    public static func hasHeadroom(_ usage: AccountUsage, now: Double) -> Bool {
        (live(usage.fiveHour, now)?.percent ?? 0) < full && (live(usage.weekly, now)?.percent ?? 0) < full
    }

    /// Weekly quota (in Pro-plan percent) that must be used per hour to avoid losing it at reset.
    public static func urgency(_ usage: AccountUsage, now: Double) -> Double {
        let weekly = live(usage.weekly, now)
        let remaining = 100 - (weekly?.percent ?? 0)
        let hours = max(((weekly?.resetsAt ?? now + week) - now) / 3600, 1)
        return remaining / hours * (usage.capacity ?? 1)
    }

    /// Earliest moment any account regains headroom, for when every account is limited.
    public static func nextAvailable(_ candidates: [Account], usage: [String: AccountUsage], now: Double) -> (Account, Double)? {
        candidates.filter { $0.ready }.compactMap { account -> (Account, Double)? in
            guard let value = usage[account.id] else { return nil }
            // Same bars as switching: a 5-hour window counts as blocked from the switch target.
            let blocking = [live(value.fiveHour, now).flatMap { $0.percent >= switchTarget ? $0 : nil },
                            live(value.weekly, now).flatMap { $0.percent >= full ? $0 : nil }].compactMap { $0 }
            guard let reset = blocking.compactMap(\.resetsAt).max() else { return nil }
            return (account, reset)
        }.min { $0.1 < $1.1 }
    }

    /// Minutes until a window reaches the limit at the observed pace, from (time, percent) samples.
    /// Counts down from the last sample; samples older than ten minutes say nothing about the pace now.
    public static func minutesToLimit(_ samples: [(Double, Double)], now: Double? = nil) -> Double? {
        guard let first = samples.first, let last = samples.last, last.0 - first.0 >= 300,
              last.1 > first.1, last.1 < full else { return nil }
        let since = ((now ?? last.0) - last.0) / 60
        guard since < 10 else { return nil }
        let perMinute = (last.1 - first.1) / ((last.0 - first.0) / 60)
        return max((full - last.1) / perMinute - since, 0)
    }

    public static func best(_ candidates: [Account], usage: [String: AccountUsage], health: [String: LoginHealth] = [:], active: String?, now: Double) -> String? {
        let usable = candidates.filter { account in
            guard account.ready, account.allowAuto, health[account.id]?.takesWork != false,
                  let value = usage[account.id], !value.stale else { return false }
            return hasHeadroom(value, now: now)
        }
        // Only move to an account with real room on every limit, so it is not left again minutes
        // later; the active one may run up to the limit. With none, any 5-hour room will do.
        let roomy = { (account: Account, weekly: Bool) in
            let value = usage[account.id]!
            return account.id == active || ((live(value.fiveHour, now)?.percent ?? 0) < switchTarget
                && (!weekly || (live(value.weekly, now)?.percent ?? 0) < switchTarget))
        }
        var eligible = usable.filter { roomy($0, true) }
        if eligible.isEmpty { eligible = usable.filter { roomy($0, false) } }
        // Priority before urgency: a Last account waits even when its week is the one about to lapse.
        let rank = { (account: Account) in (account.priority ?? .normal).rank }
        if let tier = eligible.map(rank).min() { eligible = eligible.filter { rank($0) == tier } }
        guard let top = eligible.map({ urgency(usage[$0.id]!, now: now) }).max() else { return nil }
        let pick = eligible.filter { urgency(usage[$0.id]!, now: now) >= top * 0.75 }
            .min { (live(usage[$0.id]!.fiveHour, now)?.resetsAt ?? .infinity) < (live(usage[$1.id]!.fiveHour, now)?.resetsAt ?? .infinity) }
        // Hysteresis: keep a usable active account unless the pick is clearly more urgent.
        if let active, let current = eligible.first(where: { $0.id == active }), let pick, pick.id != active,
           urgency(usage[pick.id]!, now: now) < urgency(usage[current.id]!, now: now) * 1.5 {
            return active
        }
        return pick?.id
    }

    /// A move only for priority, off an account with room, waits this long after the login's last move, so
    /// limits coming and going (Fable above all) can't bounce its sessions between tiers and cost their cache each time.
    public static let priorityDwell = 3600.0

    public static func priorityMoveWaits(from: Account, to: Account, usage: AccountUsage?, movedAt: Double?, now: Double) -> Bool {
        guard let usage, let movedAt, hasHeadroom(usage, now: now),
              (to.priority ?? .normal).rank < (from.priority ?? .normal).rank else { return false }
        return now - movedAt < priorityDwell
    }

    /// Sessions keep their prompt cache only while they stay on one account, so a trade the account doesn't need yet
    /// waits until its sessions have been quiet this long; one that is out of room moves at once.
    public static let pause = 300.0

    public static func waitsForPause(_ usage: AccountUsage?, quiet: Double?, now: Double) -> Bool {
        guard let usage, let quiet else { return false }
        return quiet < pause && hasHeadroom(usage, now: now)
    }

    /// Whether a running login's sessions need Fable: true if any runs it, false only when every model is known.
    public static func needsFable(_ models: [String?]?) -> Bool? {
        guard let models, !models.isEmpty else { return nil }
        if models.contains(where: { $0?.localizedCaseInsensitiveContains("fable") == true }) { return true }
        return models.contains(nil) ? nil : false
    }

    /// When `slot`'s Fable sessions have spent their account's Fable share and no free account has any: another
    /// running login with Fable room whose sessions all use other models, provided `slot`'s account still has room
    /// for them. Trading the two keeps the Fable sessions going and hands the others a login they can still use.
    public static func fableShare(for slot: String, slots: [String: String], models: [String: [String?]], accounts: [Account],
                                  usage: [String: AccountUsage], health: [String: LoginHealth] = [:], excluded: Set<String>, now: Double) -> (slot: String, account: String)? {
        guard needsFable(models[slot]) == true, let id = slots[slot], let mine = accounts.first(where: { $0.id == id }),
              best([mine], usage: usage, health: health, active: nil, now: now) == id else { return nil }
        let fable = usage.compactMapValues(\.forFable)
        let partners = slots.filter { other, account in
            other != slot && account != id && !excluded.contains(account) && needsFable(models[other]) == false
                && slots.values.filter { $0 == account }.count == 1
        }
        let candidates = accounts.filter { account in partners.values.contains(account.id) }
        guard let pick = best(candidates, usage: fable, health: health, active: nil, now: now),
              let partner = partners.first(where: { $0.value == pick })?.key else { return nil }
        return (partner, pick)
    }

    /// A live reading whose weekly window resets at a different time than the account's own
    /// (still running) week came from another account's login. (From brandeddaniel's fork.)
    public static func belongsElsewhere(_ windows: [UsageWindow], known: AccountUsage?, now: Double) -> Bool {
        guard let mine = known?.weekly?.resetsAt, mine > now,
              let theirs = windows.first(where: { $0.id == "seven_day" })?.resetsAt else { return false }
        return abs(mine - theirs) > 3600
    }

    /// A 5-hour window only starts on the first message; starting it early makes it reset early.
    public static func shouldPrime(_ account: Account, usage: AccountUsage?, now: Double) -> Bool {
        guard account.ready, account.allowAuto, let usage, !usage.stale else { return false }
        // A Last account isn't meant to be spent yet, so its window waits until it is.
        guard account.priority != .last else { return false }
        // A plan with no 5-hour window has nothing to start. Claude's plans may omit an idle one, so those are tried;
        // the caller waits a day after a verified Ultra account, which has none, shows no window from it.
        guard account.provider == .claude || usage.fiveHour != nil else { return false }
        return live(usage.fiveHour, now) == nil && (live(usage.weekly, now)?.percent ?? 0) < full
    }
}

public enum StorageError: LocalizedError {
    case unsupportedVersion, invalidConfiguration
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This library was saved by a newer version of Side A. Update the app to open it."
        case .invalidConfiguration: "The account library could not be read safely. Your saved file has been left untouched."
        }
    }
}

/// What's wrong with an account's login; one with nothing wrong has no entry. Limits and rests (`usage`, `poolBlocked`,
/// `backoffUntil`) are separate facts: a login in good health can still be full.
public enum LoginHealth: Sendable, Equatable {
    /// Unused since it expired; the last reading holds and renewing it is free.
    case idle
    /// The bridge can't confirm whose login sits in the slot.
    case verify
    /// The read failed for a passing reason.
    case offline
    /// Refused until the user signs in again. `replacedBy` names whose login took its place. A session's own reading
    /// says nothing about this: a running session can outlive the login nobody else can use.
    case signIn(replacedBy: String? = nil)

    /// Whether new work may be handed to this login.
    public var takesWork: Bool { if case .signIn = self { false } else { true } }

    /// The word kept in the usage cache.
    public var saved: String {
        switch self {
        case .idle: "idle"
        case .verify: "verify"
        case .offline: "offline"
        case .signIn: "signIn"
        }
    }

    public init?(saved: String) {
        switch saved {
        case "idle": self = .idle
        case "verify": self = .verify
        case "offline": self = .offline
        case "signIn": self = .signIn()
        default: return nil
        }
    }
}

public enum PrivateFile {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try write(data: try JSONEncoder().encode(value), to: url)
    }
    public static func write(data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Never readable by others, not even for a moment, and replaced whole.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
    /// Text that is never readable by others, not even for a moment (a prompt, a session's last screen).
    public static func writeText(_ text: String, to url: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? files.removeItem(at: url)
        guard files.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

public enum Shell {
    public static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
