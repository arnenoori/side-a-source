import Foundation
import SideAProtocol

/// Finding a session by what is known about it, the same on the Mac and the phone.
public enum SessionSearch {
    /// Every word typed is in one of the fields: "side fix" finds a session titled "Fix the login" in side-a.
    public static func matches(_ query: String, fields: [String?]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let fields = fields.compactMap { $0 }
        return words.allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
    }
}

extension SessionSnooze.Choice {
    public static let offered: [Self] = [.hour, .threeHours, .morning, .needsMe]

    public var title: String {
        switch self {
        case .hour: "1 Hour"
        case .threeHours: "3 Hours"
        case .morning: "Tomorrow Morning"
        case .needsMe: "Until It Needs Me"
        default: rawValue
        }
    }

    /// When a timed choice ends; nil for "until it needs me".
    public func until(from now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .hour: now.addingTimeInterval(3600)
        case .threeHours: now.addingTimeInterval(3 * 3600)
        case .morning: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)).flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
        default: nil
        }
    }
}

extension SessionSnooze {
    public var untilText: String {
        guard let until else { return "Until it needs you" }
        let date = Date(timeIntervalSince1970: until)
        return "Until " + date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }
}

/// A finished conversation stops being current without being filed: after a week with nothing new, or once its pull
/// request is merged or closed. Worked out each time and never stored, so there is nothing to migrate or sync.
public enum Settled {
    public static let after: TimeInterval = 7 * 86_400

    public static func isSettled(lastMessage: Double?, pullRequestDone: Bool = false, pinned: Bool, running: Bool, now: Double) -> Bool {
        if pinned || running { return false }
        if pullRequestDone { return true }
        guard let lastMessage else { return false }
        return now - lastMessage > after
    }
}
