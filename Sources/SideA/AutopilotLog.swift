import Foundation

/// Written only when a reason changes, since Autopilot re-decides every tick.
struct AutopilotLog {
    let url: URL
    private var last: [String: String] = [:]
    static let limit = 1_000_000
    /// Each line's time, in UTC with no zone written.
    static let stamp = Date.ISO8601FormatStyle().year().month().day().time(includingFractionalSeconds: false).timeSeparator(.colon).dateSeparator(.dash)

    init(url: URL) { self.url = url }

    /// True when the line was written, not a repeat.
    @discardableResult mutating func note(_ key: String, _ line: String?) -> Bool {
        guard last[key] != line else { return false }
        last[key] = line
        if let line { write(line) }
        return line != nil
    }

    func write(_ line: String) {
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.limit {
            let old = url.appendingPathExtension("1")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        let stamp = Date().formatted(Self.stamp)
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            manager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}
