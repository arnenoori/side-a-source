import Foundation

public struct UsageWindow: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var percent: Double
    public var resetsAt: Double?
    public init(id: String, label: String, percent: Double, resetsAt: Double?) {
        self.id = id; self.label = label; self.percent = percent.isFinite ? min(max(percent, 0), 100) : 0; self.resetsAt = resetsAt
    }
    // Readings past the cap (101% once paid credits run) and older saved ones are kept within 0–100.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), label: try values.decode(String.self, forKey: .label),
                  percent: try values.decode(Double.self, forKey: .percent), resetsAt: try values.decodeIfPresent(Double.self, forKey: .resetsAt))
    }
    /// What the window holds at `now`: nothing once it has reset, however full it was.
    public func used(at now: Double) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return percent
    }
    /// "42%", rounded the same way everywhere.
    public func text(at now: Double) -> String { "\(Int(used(at: now).rounded()))%" }
}

/// Paid usage past the plan's limits ("usage credits"), this month.
public struct ExtraUsage: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var used: Double
    public var limit: Double?
    public var currency: String
    public init(enabled: Bool, used: Double, limit: Double?, currency: String = "USD") {
        self.enabled = enabled; self.used = used; self.limit = limit; self.currency = currency
    }
    public func money(_ value: Double) -> String { value.formatted(.currency(code: currency)) }
    /// "$3.20 of $10 this month".
    public var summary: String { "\(money(used))\(limit.map { " of \(money($0))" } ?? "") this month" }
}

public struct AccountUsage: Codable, Equatable, Hashable, Sendable {
    public var windows: [UsageWindow]
    public var stale: Bool
    /// Paid usage, Claude only; absent in readings from older versions.
    public var extra: ExtraUsage?
    /// Relative plan size (Pro 1, Max 5x 5, Max 20x 20). Missing means unknown, treated as 1.
    public var capacity: Double?
    public init(windows: [UsageWindow], stale: Bool = false, extra: ExtraUsage? = nil, capacity: Double? = nil) {
        self.windows = windows; self.stale = stale; self.extra = extra; self.capacity = capacity
    }
    public var fiveHour: UsageWindow? { windows.first { $0.id == "five_hour" } }
    public var weekly: UsageWindow? { windows.first { $0.id == "seven_day" } }
    /// Weekly caps that apply to one model only, such as "Weekly Fable".
    public var modelLimits: [UsageWindow] { windows.filter { $0.id.hasPrefix("model:") } }
}
