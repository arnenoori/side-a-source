import Foundation

/// The phone's words for times and amounts, one rule each, shared by the app, widgets and intents.
public enum Formatting {
    /// "now", "2m", "14m", "1h 5m", "3d": how long a row has been in its state.
    public static func elapsed(since start: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        switch seconds {
        case ..<45: return "now"
        case ..<3600: return "\(max(1, (seconds + 30) / 60))m"
        case ..<86_400:
            let minutes = (seconds % 3600) / 60
            return minutes == 0 ? "\(seconds / 3600)h" : "\(seconds / 3600)h \(minutes)m"
        default: return "\(seconds / 86_400)d"
        }
    }

    /// "0.4s", "12s", "1m 12s": how long a step ran. Nil under a second unless `exact`.
    public static func duration(_ seconds: TimeInterval, exact: Bool = false) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 1 { return exact ? String(format: "%.1fs", seconds) : nil }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let whole = Int(seconds.rounded())
        if whole < 3600 { return whole % 60 == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \((whole % 3600) / 60)m"
    }

    /// "Updated 4 min ago", or nil while a reading is younger than `fresh`.
    public static func age(of date: Date, now: Date = .now, fresh: TimeInterval = 60) -> String? {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= fresh else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Updated \(minutes) min ago" }
        if minutes < 24 * 60 { return "Updated \(minutes / 60) h ago" }
        return "Updated " + date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "82%", rounded the same way as the Mac.
    public static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// A reset time the way rows show it: "2:14" today, "Thu" within a week, "Oct 24" after.
    public static func reset(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
        }
        if date.timeIntervalSince(now) < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "1.4 GB", shown only from 1 GB as on the Mac.
    public static func memory(_ bytes: Int) -> String? {
        guard bytes >= 1_000_000_000 else { return nil }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// "3.1 KB" for file chips.
    public static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "162k" context.
    public static func tokens(_ count: Int) -> String {
        count >= 1000 ? "\(count / 1000)k" : "\(count)"
    }

    /// "Yesterday at 3:06 PM", "Today at 9:12 AM", "Oct 12 at 4:40 PM".
    public static func separator(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " at \(time)"
    }
}
