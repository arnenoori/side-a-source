import Foundation
import os

/// The app's and its extensions' diagnostics: to the unified log under one subsystem, and to a rolling
/// text log in the App Group (`Library/Logs/remote.log`, then `.1` and `.2`, 1 MB each) that Share Logs
/// sends and `devicectl device copy from --domain-type appGroupDataContainer` pulls; devicectl only
/// reaches Library, Documents and tmp. Never a token, a pairing
/// code or a message body.
public enum RemoteLog {
    public enum Category: String, Sendable {
        case pairing, transport, sync, push, terminal, app
    }

    public static let subsystem = "com.arnenoori.sidea.remote"
    static let limit = 1 << 20
    static let kept = 2

    private static let queue = DispatchQueue(label: "com.arnenoori.sidea.remote.log")
    private static let loggers = OSAllocatedUnfairLock(initialState: [Category: Logger]())
    /// "app", "NotificationService", …: which process wrote the line.
    private static let process = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    /// ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static var folder: URL? { SharedStorage.container?.appendingPathComponent("Library/Logs", isDirectory: true) }
    static var current: URL? { folder?.appendingPathComponent("remote.log") }

    public static func log(_ category: Category, _ message: String, level: OSLogType = .default) {
        let logger = loggers.withLock { loggers in
            if let logger = loggers[category] { return logger }
            let logger = Logger(subsystem: subsystem, category: category.rawValue)
            loggers[category] = logger
            return logger
        }
        logger.log(level: level, "\(message, privacy: .public)")
        let line = "\(stamp.string(from: .now)) \(process) [\(category.rawValue)] \(message)\n"
        queue.async { append(line) }
    }

    public static func error(_ category: Category, _ message: String) { log(category, message, level: .error) }

    /// Every kept file, oldest first, as one text file for Share Logs.
    public static func export() -> URL? {
        queue.sync {
            guard let folder else { return nil }
            let files = (0...kept).reversed().map { $0 == 0 ? folder.appendingPathComponent("remote.log") : folder.appendingPathComponent("remote.log.\($0)") }
            var text = Data("Side A Remote logs, \(stamp.string(from: .now))\n\n".utf8)
            for file in files { if let data = try? Data(contentsOf: file) { text.append(data) } }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("SideA-Remote-Logs.txt")
            do { try text.write(to: out) } catch { return nil }
            return out
        }
    }

    /// Appends with O_APPEND, so the app and an extension writing at once each land whole lines.
    private static func append(_ line: String) {
        guard let folder, let current else { return }
        let manager = FileManager.default
        if !manager.fileExists(atPath: folder.path) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if let size = (try? manager.attributesOfItem(atPath: current.path))?[.size] as? Int, size > limit {
            rotate(folder)
        }
        let fd = open(current.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// remote.log.1 → .2, remote.log → .1; the oldest goes.
    private static func rotate(_ folder: URL) {
        let manager = FileManager.default
        func file(_ index: Int) -> URL {
            index == 0 ? folder.appendingPathComponent("remote.log") : folder.appendingPathComponent("remote.log.\(index)")
        }
        try? manager.removeItem(at: file(kept))
        for index in stride(from: kept - 1, through: 0, by: -1) {
            try? manager.moveItem(at: file(index), to: file(index + 1))
        }
    }
}
