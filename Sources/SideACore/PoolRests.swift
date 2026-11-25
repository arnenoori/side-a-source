import Foundation

/// A weekly 429 rests an account for days, but the limit can be reset by hand at any time, so a rest must be
/// endable by a newer reading or a probe.
public struct PoolRests: Sendable {
    public private(set) var until: [String: Double] = [:]
    public private(set) var since: [String: Double] = [:]
    public private(set) var probedAt: [String: Double] = [:]
    /// Rests for a limit; a reset can end only these, not a back-off after a refusal or a login that failed to read.
    public private(set) var limits: Set<String> = []
    public private(set) var lastProbe = 0.0
    public static let probeAfter = 1800.0
    public static let probeEvery = 900.0

    public init() {}

    public subscript(id: String) -> Double? {
        get { until[id] }
        set { rest(id, until: newValue, at: Date().timeIntervalSince1970) }
    }

    public mutating func rest(_ id: String, until end: Double?, at now: Double, limit: Bool = false) {
        until[id] = end
        since[id] = end == nil ? nil : now
        if limit, end != nil { limits.insert(id) } else { limits.remove(id) }
    }

    public mutating func end(_ id: String, readAt: Double, now: Double) -> Bool {
        guard limits.contains(id), let end = until[id], end > now, let began = since[id], began < readAt else { return false }
        rest(id, until: nil, at: now)
        return true
    }

    /// `freeAt`: when each candidate is expected to serve again. A probe that finds the limit in place costs one 429,
    /// so a single request never probes more than one account.
    public mutating func probe(_ freeAt: [String: Double], now: Double) -> String? {
        guard now - lastProbe >= 60 else { return nil }
        let due = freeAt.compactMap { id, end -> (String, Double)? in
            guard end - now >= Self.probeAfter, now - (probedAt[id] ?? 0) >= Self.probeEvery,
                  now - (since[id] ?? 0) >= 60 else { return nil }
            return (id, end)
        }
        guard let pick = due.min(by: { $0.1 < $1.1 })?.0 else { return nil }
        probedAt[pick] = now
        lastProbe = now
        return pick
    }
}

extension Planner {
    public static func resetEarly(before: AccountUsage?, after: AccountUsage, now: Double) -> [String] {
        guard let before else { return [] }
        return [(\AccountUsage.fiveHour, "five_hour"), (\AccountUsage.weekly, "seven_day")].compactMap { path, id in
            guard let old = live(before[keyPath: path], now), old.percent >= 90, let reset = old.resetsAt, reset - now > 600,
                  let new = after[keyPath: path], new.percent <= old.percent - 25 else { return nil }
            return id
        }
    }
}
