import Foundation

/// Images from `GET /v1/images/{sha1}[/thumb]` on disk, in the App Group so the extensions can show
/// them too. The id is the SHA-1 of the bytes, so an entry never goes stale; the oldest go once the
/// folder passes `limit`.
public final class ImageCache: Sendable {
    public static let shared = ImageCache()

    public let folder: URL
    let limit: Int

    public init(folder: URL? = nil, limit: Int = 200 * 1024 * 1024) {
        let base = SharedStorage.container?.appendingPathComponent("Library/Caches", isDirectory: true)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? base.appendingPathComponent("images", isDirectory: true)
        self.limit = limit
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }

    /// Lowercase hex only, so an id can't name a path outside the folder.
    public func file(_ id: String, thumbnail: Bool) -> URL? {
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        return folder.appendingPathComponent(id.lowercased() + (thumbnail ? ".thumb" : ".full"))
    }

    public func data(_ id: String, thumbnail: Bool) -> Data? {
        guard let file = file(id, thumbnail: thumbnail), let data = try? Data(contentsOf: file) else { return nil }
        // Touched, so trimming goes by last use.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    public func store(_ data: Data, _ id: String, thumbnail: Bool) {
        guard let file = file(id, thumbnail: thumbnail) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Drops the least recently used files until the folder fits `limit`.
    public func trim() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return }
        var entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > limit else { return }
        entries.sort { $0.1 < $1.1 }
        for (url, _, size) in entries where total > limit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}
