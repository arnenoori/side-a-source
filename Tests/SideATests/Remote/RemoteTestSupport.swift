import Foundation
import Network
import Security
@testable import SideA
import SideACore
import zlib

/// A keychain file that lives for one test or one harness run, so nothing touches the login keychain. It never locks
/// (a locked one makes macOS ask for its password at the next TLS handshake), is never on the search list, and files
/// left by a run that was killed are swept by the next one.
final class TestKeychain {
    static let password = "test"
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("scratch/sidea-keychains")

    let keychain: SecKeychain
    let path: String
    /// A named keychain outlives the run, for a harness that restarts on the same pairings.
    let kept: Bool

    init(named name: String? = nil) throws {
        // A keychain call that would ask fails instead: tests never raise a SecurityAgent dialog.
        SecKeychainSetUserInteractionAllowed(false)
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        Self.sweep()
        path = Self.folder.appendingPathComponent(name.map { "sidea-state-\($0).keychain" } ?? "sidea-remote-\(UUID().uuidString).keychain").path
        kept = name != nil
        // SecKeychainSetSettings answers userCanceled outside an app, so the `security` tool makes the file and turns off
        // both locks: lock-on-sleep and the five-minute timeout SecKeychainCreate would leave on.
        if !FileManager.default.fileExists(atPath: path) {
            guard Self.security(["create-keychain", "-p", Self.password, path]), Self.security(["set-keychain-settings", path]) else {
                try? FileManager.default.removeItem(atPath: path)
                throw RemoteKeychain.Failure(status: errSecIO, what: "test keychain")
            }
        }
        var keychain: SecKeychain?
        let status = SecKeychainOpen(path, &keychain)
        guard status == errSecSuccess, let keychain else { throw RemoteKeychain.Failure(status: status, what: "test keychain") }
        self.keychain = keychain
        Self.keepOffSearchList(path)
        unlock()
    }

    var store: RemoteKeychain { unlock(); return RemoteKeychain(service: "test.sidea.remote", keychain: keychain) }

    /// It never locks by itself; this is for a Mac that locked every keychain anyway.
    func unlock() { SecKeychainUnlock(keychain, UInt32(Self.password.utf8.count), Self.password, true) }

    deinit {
        guard !kept else { return }
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func security(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        // A stuck securityd fails the test in ten seconds rather than hanging the run; only this child is stopped.
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    private static func keepOffSearchList(_ path: String) {
        var list: CFArray?
        guard SecKeychainCopyDomainSearchList(.user, &list) == errSecSuccess, let keychains = list as? [SecKeychain] else { return }
        let others = keychains.filter { keychain in
            var length: UInt32 = 1024
            var name = [CChar](repeating: 0, count: 1024)
            return SecKeychainGetPath(keychain, &length, &name) != errSecSuccess || String(cString: name) != path
        }
        if others.count != keychains.count { SecKeychainSetDomainSearchList(.user, others as CFArray) }
    }

    /// Only this folder's own files, and only ones no run of the last two hours could still be using: throwaway
    /// keychains and the empty lock files (`.fl…`) the keychain calls leave beside them. Named ones stay.
    private static func sweep() {
        let options: FileManager.DirectoryEnumerationOptions = []
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: options)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("sidea-remote-") || file.lastPathComponent.hasPrefix(".fl") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if modified.timeIntervalSinceNow < -7200 { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// Raw bytes over TLS, pinned the way the phone pins: by the key's SPKI hash, whatever the certificate says.
final class PinnedClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.client")
    private var received = Data()
    private var waiters: [(id: UUID, check: (Data) -> Bool, done: CheckedContinuation<Data, Never>)] = []
    private var ended = false

    init(port: UInt16, pin: Data) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            let point = chain?.first.flatMap(SecCertificateCopyKey).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
            complete(point.map(SelfSignedCertificate.spkiHash(publicKey:)) == pin)
        }, DispatchQueue(label: "test.verify"))
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls))
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.end() }
            if case .cancelled = state { self?.end() }
        }
        connection.start(queue: queue)
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.received.append(data); self.check() }
            if complete || error != nil { self.end() } else { self.read() }
        }
    }

    private func end() {
        queue.async { [self] in
            ended = true
            check()
        }
    }

    private func check() {
        waiters.removeAll { waiter in
            guard ended || waiter.check(received) else { return false }
            waiter.done.resume(returning: received)
            return true
        }
    }

    func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }
    func send(_ text: String) { send(Data(text.utf8)) }

    /// Everything received so far once `until` holds, or the connection ends, or `seconds` pass. A wait that's met
    /// returns at once, so the limit is generous: a TLS handshake on a loaded Mac running the whole suite can take
    /// seconds. Running out ends only this wait, not the connection.
    func wait(_ seconds: Double = 10, until: @escaping (Data) -> Bool) async -> Data {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let id = UUID()
                waiters.append((id, until, continuation))
                check()
                queue.asyncAfter(deadline: .now() + seconds) { [self] in
                    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
                    waiters.remove(at: index).done.resume(returning: received)
                }
            }
        }
    }

    func text(until marker: String, within seconds: Double = 10) async -> String {
        String(decoding: await wait(seconds) { String(decoding: $0, as: UTF8.self).contains(marker) }, as: UTF8.self)
    }

    func close() { connection.cancel() }
}

func maskedFrame(_ opcode: UInt8, _ payload: Data) -> Data {
    let mask: [UInt8] = [9, 8, 7, 6]
    var out = Data([0x80 | opcode, 0x80 | UInt8(payload.count)])
    out.append(contentsOf: mask)
    out.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset & 3] })
    return out
}

/// A short Claude conversation: a prompt with a pasted image, a Bash call and an Edit with its patch.
enum TranscriptFixture {
    static let image = png()

    /// `day` as yyyy-MM-dd; today's keeps it in the bridge's recent list.
    static func lines(session: String, cwd: String, day: String = "2026-10-01") -> [[String: Any]] {
        func entry(_ type: String, _ uuid: String, _ second: Int, _ content: [[String: Any]], extra: [String: Any] = [:]) -> [String: Any] {
            ["type": type, "uuid": uuid, "sessionId": session, "timestamp": "\(day)T10:00:0\(second)Z", "cwd": cwd,
             "message": ["role": type, "id": "m-\(uuid)", "model": "claude-opus-5-5", "content": content]].merging(extra) { a, _ in a }
        }
        let file = cwd + "/a.js"
        return [
            entry("user", "u1", 0, [["type": "text", "text": "Fix the build"],
                                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": image.base64EncodedString()]]]),
            entry("assistant", "a1", 1, [["type": "text", "text": "Running tests."], ["type": "tool_use", "id": "c1", "name": "Bash", "input": ["command": "npm test"]]]),
            entry("user", "u2", 2, [["type": "tool_result", "tool_use_id": "c1", "content": "ok", "is_error": false]]),
            entry("assistant", "a2", 3, [["type": "tool_use", "id": "c2", "name": "Edit", "input": ["file_path": file, "old_string": "x = 1", "new_string": "x = 2"]]]),
            entry("user", "u3", 4, [["type": "tool_result", "tool_use_id": "c2", "content": "edited"]],
                  extra: ["toolUseResult": ["filePath": file, "structuredPatch": [["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1,
                                                                                   "lines": ["-x = 1", "+x = 2"]]]]]),
        ]
    }

    /// Where Claude Code would keep it, under `home`.
    static func write(_ lines: [[String: Any]], session: String, home: URL) throws {
        let project = home.appendingPathComponent(".claude/projects/-fixture")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
        try (text.joined(separator: "\n") + "\n").write(to: project.appendingPathComponent(session + ".jsonl"), atomically: true, encoding: .utf8)
    }

    static var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// What Side A's own loop does in the app: index `home`'s transcripts into `root`, so `sessions recent` lists them.
    static func index(home: URL, root: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [bridge.path, "--root", root.path, "sessions", "index"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// The repository's own bridge, which the built app copies into its resources.
    static let bridge = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../bridge/sidea_bridge.py").standardized

    private static func png() -> Data {
        func chunk(_ kind: String, _ body: Data) -> Data {
            var length = UInt32(body.count).bigEndian
            let tagged = Data(kind.utf8) + body
            var crc = UInt32(tagged.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)) }).bigEndian
            return Data(bytes: &length, count: 4) + tagged + Data(bytes: &crc, count: 4)
        }
        // 40 by 30, 8-bit RGB: a blue-to-orange gradient, so a phone showing it shows something (a near-black one
        // looked like a broken tile).
        let header = Data([0, 0, 0, 40, 0, 0, 0, 30, 8, 2, 0, 0, 0])
        var raw = Data()
        for y in 0..<30 {
            raw.append(0)
            for x in 0..<40 { raw.append(contentsOf: [UInt8(60 + x * 4), UInt8(90 + y * 3), UInt8(220 - x * 4)]) }
        }
        var compressed = Data(count: Int(compressBound(uLong(raw.count))))
        var size = uLongf(compressed.count)
        _ = compressed.withUnsafeMutableBytes { out in
            raw.withUnsafeBytes { compress(out.bindMemory(to: Bytef.self).baseAddress, &size, $0.bindMemory(to: Bytef.self).baseAddress, uLong(raw.count)) }
        }
        compressed.count = Int(size)
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + chunk("IHDR", header) + chunk("IDAT", compressed) + chunk("IEND", Data())
    }
}

/// A loopback port nobody listens on now, as the kernel hands out: a random pick from a range sometimes landed on
/// another process's plain listener, and the client's TLS then failed against it (-9836).
func freePort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
    }
    return bound ? UInt16(bigEndian: addr.sin_port) : UInt16.random(in: 50_000...59_000)
}
