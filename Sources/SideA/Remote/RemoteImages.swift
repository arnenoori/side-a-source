import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image's bytes, read where the bridge's `sessions image` says they are and checked against their id; the bridge
/// itself never sends bytes. Thumbnails are made once into runtime/thumbs.
enum RemoteImages {
    /// What `sessions image` answers: a file, base64 at an offset in a transcript, or a transcript line to parse.
    struct Location: Decodable, Sendable {
        let id: String?
        let mime: String?
        let kind: String?
        let path: String?
        let file: String?
        let dataOffset: Int?
        let dataLength: Int?
        let lineOffset: Int?
        let lineLength: Int?
        let block: Int?
        let error: String?
    }

    /// The bridge's own file limit.
    static let maxBytes = 50 << 20
    /// Sharp on a 3x screen at the size the phone shows it.
    static let thumbPixels = 640

    static func isID(_ text: String) -> Bool { text.count == 40 && text.allSatisfy { "0123456789abcdef".contains($0) } }

    /// The bytes, only when their SHA-1 is the id: a transcript that changed under the locator never serves something else.
    static func read(_ location: Location, id: String) -> Data? {
        let data: Data?
        switch location.kind {
        case "file": data = location.file.flatMap { slice($0, offset: 0, length: nil) }
        case "inline":
            guard let path = location.path, let offset = location.dataOffset, let length = location.dataLength else { return nil }
            data = slice(path, offset: offset, length: length).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
        case "line":
            guard let path = location.path, let offset = location.lineOffset, let length = location.lineLength, let block = location.block,
                  let line = slice(path, offset: offset, length: length),
                  let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            let blocks = claudeBlocks(entry)
            let source = block < blocks.count ? blocks[block]["source"] as? [String: Any] : nil
            data = (source?["data"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
        default: data = nil
        }
        guard let data, sha1(data) == id else { return nil }
        return data
    }

    /// Each image block of a Claude line in file order, as the bridge's `claude_blocks` numbers them.
    static func claudeBlocks(_ entry: [String: Any]) -> [[String: Any]] {
        func images(_ list: Any?) -> [[String: Any]] {
            ((list as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.filter { $0["type"] as? String == "image" }
        }
        if entry["type"] as? String == "attachment" { return images((entry["attachment"] as? [String: Any])?["prompt"]) }
        guard entry["type"] as? String == "user", let content = (entry["message"] as? [String: Any])?["content"] as? [Any] else { return [] }
        var blocks: [[String: Any]] = []
        for case let part as [String: Any] in content {
            switch part["type"] as? String {
            case "image": blocks.append(part)
            case "tool_result": blocks += images(part["content"])
            default: break
            }
        }
        return blocks
    }

    static func sha1(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func slice(_ path: String, offset: Int, length: Int?) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), offset >= 0, UInt64(offset) <= size else { return nil }
        let count = length ?? Int(size) - offset
        // Base64 is a third larger than the bytes it holds.
        guard count >= 0, count <= maxBytes * 4 / 3 + 4 else { return nil }
        try? handle.seek(toOffset: UInt64(offset))
        guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    /// A JPEG at most 640 pixels on its long side, written once next to the others.
    static func thumbnail(_ data: Data, id: String, folder: URL) -> Data? {
        let url = folder.appendingPathComponent(id + ".jpg")
        if let cached = try? Data(contentsOf: url) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: thumbPixels] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // When the write fails, serving still works and the next request makes it again.
        FileManager.default.createFile(atPath: url.path, contents: out as Data, attributes: [.posixPermissions: 0o600])
        return out as Data
    }
}
