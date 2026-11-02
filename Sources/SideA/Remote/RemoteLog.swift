import Foundation
import os
import SideACore

/// What Remote did, for debugging a phone that can't connect: Console (subsystem com.arnenoori.sidea, category remote),
/// a file to `tail -f` (~/Library/Logs/SideA/remote.log, 2 MB, two older files kept), and the last 200 lines for
/// Copy Diagnostics. Never tokens, pairing codes, comparison digits, keys, attempt ids, preview credentials or bodies.
final class RemoteLog: @unchecked Sendable {
    static let shared = RemoteLog()
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SideA")
    static let fileLimit = 2 << 20
    static let kept = 200

    private let logger = Logger(subsystem: "com.arnenoori.sidea", category: "remote")
    private let queue = DispatchQueue(label: "com.arnenoori.sidea.remote.log")
    private var file: FileHandle?
    private var url: URL?
    private var size = 0
    private var lines: [String] = []
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// The app only: tests and the demo log to Console and memory, never into the user's Logs folder.
    func open(_ url: URL = RemoteLog.folder.appendingPathComponent("remote.log")) {
        queue.async { [self] in
            guard self.url != url else { return }
            try? file?.close()
            self.url = url
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            chmod(url.path, 0o600)
            file = try? FileHandle(forWritingTo: url)
            size = Int((try? file?.seekToEnd()) ?? 0)
        }
    }

    /// One event, one line, whatever a phone's name or a request's path held.
    static func oneLine(_ message: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in message.unicodeScalars {
            switch scalar {
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            case "\t": out.append(contentsOf: "\\t".unicodeScalars)
            default: if DisplayText.hidden(scalar) { out.append(contentsOf: "⟦U+\(String(format: "%04X", scalar.value))⟧".unicodeScalars) } else { out.append(scalar) }
            }
        }
        return String(out)
    }

    func callAsFunction(_ raw: String) {
        let message = Self.oneLine(raw)
        logger.info("\(message, privacy: .public)")
        let now = Date()
        queue.async { [self] in
            let line = stamp.string(from: now) + " " + message
            lines.append(line)
            if lines.count > Self.kept { lines.removeFirst(lines.count - Self.kept) }
            guard let file else { return }
            let data = Data((line + "\n").utf8)
            try? file.write(contentsOf: data)
            size += data.count
            if size > Self.fileLimit { rotate() }
        }
    }

    var recent: [String] { queue.sync { lines } }

    /// remote.log becomes remote.1.log, remote.1.log becomes remote.2.log, and the oldest goes.
    private func rotate() {
        guard let url else { return }
        try? file?.close()
        let manager = FileManager.default
        let older = { (n: Int) in url.deletingPathExtension().appendingPathExtension("\(n).log") }
        try? manager.removeItem(at: older(2))
        try? manager.moveItem(at: older(1), to: older(2))
        try? manager.moveItem(at: url, to: older(1))
        manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        file = try? FileHandle(forWritingTo: url)
        size = 0
    }

    /// A request's path with anything secret taken out: the attempt id in pairing routes, a preview's credential, a
    /// preview page's own path, and every query.
    static func path(_ request: HTTPRequest) -> String {
        var parts = request.path
        guard parts.first == "v1" else { return "/(preview page)" }
        if parts.count >= 3, parts[1] == "pair" { parts[2] = "…" }
        if parts.count >= 3, parts[1] == "preview" { parts = Array(parts.prefix(2)) + ["…"] }
        return "/" + parts.joined(separator: "/")
    }

    /// Which network an address is on, as the Remote tab names them.
    static func network(_ address: String) -> String {
        if address.hasPrefix("127.") || address == "::1" { return "loopback" }
        if address.lowercased().hasPrefix("fd7a:115c:a1e0:") { return "tailnet" }
        let octets = address.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) { return "tailnet" }
        return "LAN"
    }
}

/// Which outside peer each spliced loopback connection carries, so the TLS listener's lines name the phone, not
/// 127.0.0.1. Filled by SocketFront on accept, taken by RemoteServer when the loopback side arrives.
final class SplicedPeers: @unchecked Sendable {
    static let shared = SplicedPeers()
    private let lock = NSLock()
    /// The line for the log, and the bare address for per-address limits.
    private var peers: [UInt16: (peer: String, source: String)] = [:]

    func set(_ port: UInt16, _ peer: String, source: String) {
        lock.withLock { peers[port] = (peer, source); if peers.count > 256 { peers.removeAll() } }
    }
    func take(_ port: UInt16) -> (peer: String, source: String)? { lock.withLock { peers.removeValue(forKey: port) } }
}
