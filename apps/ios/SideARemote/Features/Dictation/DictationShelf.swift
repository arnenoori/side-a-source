import Foundation
import Observation

@Observable
final class DictationShelf {
    nonisolated deinit {}

    static let shared = DictationShelf()
    static let folder = DictationRecorder.folder.appendingPathComponent("Kept", isDirectory: true)
    static let lasts: TimeInterval = 86_400

    private(set) var keys: Set<String> = []

    private init() {
        Self.sweep()
        keys = Set(((try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? []).compactMap(Self.key(named:)))
    }

    func recording(for key: String) -> URL? {
        guard keys.contains(key) else { return nil }
        let url = Self.url(key)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        keys.remove(key)
        return nil
    }

    func keep(_ file: URL, for key: String) -> URL? {
        let url = Self.url(key), manager = FileManager.default
        do {
            try manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            try manager.moveItem(at: file, to: url)
        } catch {
            return nil
        }
        keys.insert(key)
        return url
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: Self.url(key))
        keys.remove(key)
    }

    private static func url(_ key: String) -> URL {
        let name = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return folder.appendingPathComponent(name).appendingPathExtension("m4a")
    }

    private static func key(named name: String) -> String? {
        guard name.hasSuffix(".m4a") else { return nil }
        var base = String(name.dropLast(4)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        return Data(base64Encoded: base).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func sweep() {
        let manager = FileManager.default
        for folder in [DictationRecorder.folder, folder] {
            for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey])) ?? [] {
                guard let values = try? file.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
                if Date.now.timeIntervalSince(values.creationDate ?? .now) > lasts { try? manager.removeItem(at: file) }
            }
        }
    }
}
