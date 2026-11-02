import Foundation

/// Decrypted push payloads by request id, in the App Group, so the Live Activity and the app can put
/// words to an id that arrived without them. The Service Extension writes; anyone reads. A day old, gone.
public enum PushCache {
    private static var folder: URL? { SharedStorage.container?.appendingPathComponent("push", isDirectory: true) }

    public static func store(_ payload: Data, for requestID: String) {
        guard let folder, let file = file(requestID) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? payload.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        prune()
    }

    public static func load(_ requestID: String) -> Data? { file(requestID).flatMap { try? Data(contentsOf: $0) } }

    public static func remove(_ requestID: String) {
        if let file = file(requestID) { try? FileManager.default.removeItem(at: file) }
    }

    /// Request ids are random base64url, but a name from the wire never leaves the folder.
    private static func file(_ requestID: String) -> URL? {
        let safe = requestID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty else { return nil }
        return folder?.appendingPathComponent(safe + ".json")
    }

    private static func prune(olderThan age: TimeInterval = 86_400) {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date.now.timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: file) }
        }
    }
}
