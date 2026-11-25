import Foundation

/// Process memory as the Mac and the phone both say it. Binary units, the way Activity Monitor counts them (1 GB is
/// 1024 MB), so a process reads the same on both. The wire carries bytes; the Mac measures in mebibytes.
public enum MemorySize {
    public static let mebibyte = 1 << 20
    public static let gibibyte = 1 << 30

    /// "512 MB" below a gigabyte, "1.4 GB" from it.
    public static func text(bytes: Int) -> String {
        bytes >= gibibyte ? String(format: "%.1f GB", Double(bytes) / Double(gibibyte)) : "\(bytes / mebibyte) MB"
    }

    /// Only from a gigabyte, for a row that stays quiet about small processes.
    public static func gigabytesText(_ bytes: Int) -> String? { bytes >= gibibyte ? text(bytes: bytes) : nil }

    /// Bytes for a size measured in mebibytes.
    public static func bytes(mebibytes: Int) -> Int { mebibytes << 20 }
}
