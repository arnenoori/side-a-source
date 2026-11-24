import Foundation

public enum CrashReports {
    public struct Crash: Equatable, Sendable {
        public let at: Date
        public let version: String?
        /// "EXC_BREAKPOINT in RemoteController.refresh()": the exception and the first frame in Side A's own code.
        public let summary: String
    }

    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// Reports for `process` written after `since`, oldest first.
    public static func crashes(of process: String = "SideA", since: Date, in folder: URL = folder) -> [Crash] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(process + "-") && $0.pathExtension == "ips" }
            .compactMap { file -> Crash? in
                guard let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, at > since,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return read(text, at: at)
            }
            .sorted { $0.at < $1.at }
    }

    /// An .ips file is a one-line JSON header, then the report as JSON.
    static func read(_ text: String, at: Date) -> Crash? {
        guard let split = text.firstIndex(of: "\n"),
              let header = try? JSONSerialization.jsonObject(with: Data(text[..<split].utf8)) as? [String: Any],
              let report = try? JSONSerialization.jsonObject(with: Data(text[split...].utf8)) as? [String: Any] else { return nil }
        let exception = (report["exception"] as? [String: Any])?["type"] as? String ?? "crash"
        let images = report["usedImages"] as? [[String: Any]] ?? []
        let threads = report["threads"] as? [[String: Any]] ?? []
        let faulting = report["faultingThread"] as? Int ?? 0
        let frames = threads.indices.contains(faulting) ? threads[faulting]["frames"] as? [[String: Any]] ?? [] : []
        let own = frames.first { frame in
            guard let index = frame["imageIndex"] as? Int, images.indices.contains(index) else { return false }
            return (images[index]["name"] as? String)?.hasPrefix("SideA") == true
        }
        let symbol = own?["symbol"] as? String
        return Crash(at: at, version: header["app_version"] as? String, summary: symbol.map { "\(exception) in \($0)" } ?? exception)
    }
}
