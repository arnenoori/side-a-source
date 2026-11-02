import CryptoKit
import Foundation
import ImageIO
import SideACore
import UniformTypeIdentifiers

/// Photos from the phone, for replies and new hosted sessions: decoded, at most 2048 px on the long side, re-encoded
/// without EXIF or GPS, and kept 7 days under runtime/uploads (0600). Replies name them by id; only the Mac knows paths.
enum RemoteUploads {
    static let longSide = 2048
    static let keepFor: TimeInterval = 7 * 86_400
    /// What one phone may hold on the Mac until its photos expire: hundreds of full-size photos, not the disk.
    static let perDevice = 500 << 20

    enum Failure: Error, Equatable { case unsupported, unreadable, full }

    static func folder(_ root: URL) -> URL { root.appendingPathComponent("runtime/uploads") }

    private static let devicePrefix = "device-"

    /// A phone's own folder, named by a hash so a device id is never a path.
    static func folder(_ root: URL, device: String) -> URL {
        let hash = SHA256.hash(data: Data(device.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return folder(root).appendingPathComponent(devicePrefix + hash)
    }

    /// The day folders, the Mac's own and each phone's.
    private static func dayFolders(_ root: URL) -> [URL] {
        let top = folder(root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: top.path)) ?? []
        return names.filter { !$0.hasPrefix(devicePrefix) }.map { top.appendingPathComponent($0) }
            + names.filter { $0.hasPrefix(devicePrefix) }.flatMap { dayFolders(in: top.appendingPathComponent($0)) }
    }

    private static func dayFolders(in base: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).map { base.appendingPathComponent($0) }
    }

    private static func usage(of base: URL) -> Int {
        dayFolders(in: base).reduce(0) { total, day in
            ((try? FileManager.default.contentsOfDirectory(at: day, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .reduce(total) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
    }

    /// The type from the bytes themselves; the phone's Content-Type is never trusted.
    static func sniff(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(16))
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool { head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return "image/gif" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "image/webp" }
        if starts(Array("ftyp".utf8), at: 4), ["heic", "heix", "mif1", "msf1", "heis", "hevc"].contains(where: { starts(Array($0.utf8), at: 8) }) {
            return "image/heic"
        }
        return nil
    }

    /// Stores one photo. The same photo twice is the same upload. `device` is the phone it came from, held to `cap`; the Mac's own have none.
    static func store(_ data: Data, root: URL, device: String? = nil, cap: Int = perDevice, now: Date = Date()) throws(Failure) -> Upload {
        guard sniff(data) != nil else { throw .unsupported }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: longSide] as CFDictionary) else {
            throw .unreadable
        }
        // Screenshots with transparency stay PNG; everything else is a JPEG.
        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type = alpha ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { throw .unreadable }
        // Only the pixels go in: no EXIF, GPS or other metadata from the original.
        CGImageDestinationAddImage(destination, image, alpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .unreadable }
        let bytes = out as Data
        let id = Insecure.SHA1.hash(data: bytes).prefix(6).map { String(format: "%02x", $0) }.joined()
        let base = device.map { folder(root, device: $0) } ?? folder(root)
        let day = base.appendingPathComponent(Self.day.string(from: now))
        let url = day.appendingPathComponent(id + (alpha ? ".png" : ".jpg"))
        do {
            try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) {
                if device != nil, usage(of: base) + bytes.count > cap { throw Failure.full }
                guard FileManager.default.createFile(atPath: url.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw Failure.unreadable }
            }
        } catch {
            throw error as? Failure ?? .unreadable
        }
        return Upload(id: id, path: url.path, mime: type.preferredMIMEType ?? "image/jpeg", bytes: bytes.count)
    }

    /// The paths for these ids, in order; nil when any is unknown or gone.
    static func paths(_ ids: [String], root: URL) -> [String]? {
        // Built from the root, so a path reads exactly as the upload's answer gave it.
        let days = dayFolders(root)
        var paths: [String] = []
        for id in ids {
            guard id.count == 12, id.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            let found = days.lazy.flatMap { day in [".jpg", ".png"].map { day.appendingPathComponent(id + $0) } }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let found else { return nil }
            paths.append(found.path)
        }
        return paths
    }

    /// Uploads past their week, and day folders left empty, except today's: a photo stored now, from the phone or the
    /// Sessions window, may have made that folder and not yet written its file.
    static func sweep(root: URL, now: Date = Date()) {
        let manager = FileManager.default
        let today = Self.day.string(from: now)
        for day in dayFolders(root) {
            for file in (try? manager.contentsOfDirectory(at: day, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
                if now.timeIntervalSince(created) > keepFor { try? manager.removeItem(at: file) }
            }
            if day.lastPathComponent != today, (try? manager.contentsOfDirectory(atPath: day.path))?.isEmpty == true { try? manager.removeItem(at: day) }
        }
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}
