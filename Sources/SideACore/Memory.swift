import Darwin
import Foundation

/// Uses the kernel's pressure level, not swap use: macOS grows swap a gigabyte at a time, so a nearly full
/// swap file is normal. The warning also needs sessions big enough to be the cause.
public struct MemoryPressure: Equatable, Sendable {
    public let sessionsMB: Int
    /// 1 normal, 2 warning, 4 critical.
    public let level: Int
    public init(sessionsMB: Int, level: Int) {
        self.sessionsMB = sessionsMB; self.level = level
    }

    public static let sessionsFloorMB = 4096
    public static let notifyEvery: TimeInterval = 3600

    public static func levelTight(_ level: Int) -> Bool { level >= 2 }
    public var tight: Bool { Self.levelTight(level) && sessionsMB >= Self.sessionsFloorMB }
    public var line: String { "Sessions hold \(Self.gigabytes(sessionsMB)) · memory is tight" }
    public var notification: String {
        "Claude sessions and what they started hold \(Self.gigabytes(sessionsMB)), and macOS reports \(level >= 4 ? "critical" : "high") memory pressure. Quit idle ones in Sessions."
    }

    public static func gigabytes(_ mb: Int) -> String {
        let tenths = (Double(mb) / 1024 * 10).rounded()
        return tenths < 100 ? "\(Int(tenths) / 10).\(Int(tenths) % 10) GB" : "\(Int((tenths / 10).rounded())) GB"
    }

    public static func currentLevel() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return Int(level)
    }

    public static func shouldNotify(now: Date, last: Date?) -> Bool {
        last.map { now.timeIntervalSince($0) >= notifyEvery } ?? true
    }
}
