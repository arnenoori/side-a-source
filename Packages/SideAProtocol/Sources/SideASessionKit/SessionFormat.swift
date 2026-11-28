import Foundation

/// How the session views write a length of time.
public enum SessionFormat {
    /// "0.4s", "12s", "1m 12s": how long a step ran. Nil under a second unless `exact`.
    public static func duration(_ seconds: TimeInterval, exact: Bool = false) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 1 { return exact ? String(format: "%.1fs", seconds) : nil }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let whole = Int(seconds.rounded())
        if whole < 3600 { return whole.isMultiple(of: 60) ? "\(whole / 60)m" : "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \((whole % 3600) / 60)m"
    }
}
