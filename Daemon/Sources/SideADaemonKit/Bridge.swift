import Foundation

/// Where the Python bridge and an interpreter for it are. The bridge is the same `bridge/*.py` the Mac app ships; the
/// daemon installs it beside its binary (`share/side-a/bridge`) or finds a checkout.
public struct BridgeLocation: Sendable {
    public let python: String
    public let directory: URL

    public var script: String { directory.appendingPathComponent("sidea_bridge.py").path }

    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment, executable: String = CommandLine.arguments.first ?? "") -> BridgeLocation? {
        guard let python = environment["SIDEAD_PYTHON"].flatMap({ Run.which($0, environment: environment) }) ?? Run.which("python3", extra: ["/usr/bin", "/usr/local/bin"], environment: environment) else { return nil }
        let binary = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        var candidates = [environment["SIDEAD_BRIDGE"].map { URL(fileURLWithPath: $0) }].compactMap { $0 }
        candidates += [binary.appendingPathComponent("../share/side-a/bridge"), binary.appendingPathComponent("../../share/side-a/bridge")]
        // A source checkout: `.build/<triple>/<config>/sidead` inside Daemon/, whose parent holds bridge/.
        var folder = binary
        for _ in 0..<7 { candidates.append(folder.appendingPathComponent("bridge")); folder = folder.deletingLastPathComponent() }
        guard let found = candidates.map({ $0.standardized }).first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("sidea_bridge.py").path) }) else { return nil }
        return BridgeLocation(python: python, directory: found)
    }
}

public struct BridgeFailure: Error, CustomStringConvertible, Sendable {
    public let message: String
    public var description: String { message }
}

/// One long-lived `sidea_bridge.py sessions serve`: a JSON request per line in, one reply per line out, as the Mac's
/// `SessionBridge` drives it, so reopening a conversation reuses its parsed transcript.
public actor SessionBridge {
    private let location: BridgeLocation
    private let root: URL
    private let environment: [String: String]
    private var process: Process?
    private var input: FileHandle?
    private var next = 0
    private var waiting: [Int: CheckedContinuation<Data, Error>] = [:]


    public init(location: BridgeLocation, root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.location = location; self.root = root; self.environment = environment
    }

    /// The whole reply line for `args`, as the bridge wrote it.
    public func data(_ args: [String], timeout: Duration = .seconds(30)) async throws -> Data {
        let process = try start()
        next += 1
        let id = next
        var line = try JSONSerialization.data(withJSONObject: ["id": id, "args": args])
        line.append(0x0A)
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id, process: ObjectIdentifier(process))
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            do { try input?.write(contentsOf: line) } catch { waiting.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    /// The reply's `result` as JSON, or the bridge's own error as `BridgeFailure`.
    public func result(_ args: [String], timeout: Duration = .seconds(30)) async throws -> Data {
        try Self.open(try await data(args, timeout: timeout))
    }

    static func open(_ reply: Data) throws -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { throw BridgeFailure(message: "The bridge sent something unreadable.") }
        if let error = object["error"] as? String { throw BridgeFailure(message: error) }
        guard let result = object["result"], let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) else {
            throw BridgeFailure(message: "The bridge didn't answer.")
        }
        return data
    }

    /// A command run once; its standard output (`hosting install`, `usage`, and the like).
    public func once(_ args: [String], timeout: TimeInterval = 60) async throws -> Data {
        let run = await Run.process(location.python, [location.script, "--root", root.path] + args, environment: environment, timeout: timeout)
        guard run.status == 0 else { throw BridgeFailure(message: run.errors.isEmpty ? "The bridge failed (\(run.status))." : run.errors) }
        return Data(run.output.utf8)
    }

    public func stop() {
        guard let process else { return }
        process.terminate()
        self.process = nil
        input = nil
        fail("The bridge stopped.")
    }

    private func start() throws -> Process {
        if let process { return process }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: location.python)
        process.arguments = [location.script, "--root", root.path, "sessions", "serve"]
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // A thread of its own blocks on the pipe: Foundation's readabilityHandler is not dependable on Linux.
        let reader = stdout.fileHandleForReading
        let (replies, deliver) = AsyncStream<[Data]>.makeStream()
        let thread = Thread {
            var buffer = LineBuffer()
            while true {
                let data = reader.nextChunk()
                if data.isEmpty { deliver.finish(); return }
                let lines = buffer.feed(data)
                if !lines.isEmpty { deliver.yield(lines) }
            }
        }
        thread.start()
        Task { [weak self] in for await lines in replies { await self?.received(lines) } }
        process.terminationHandler = { [weak self] finished in Task { await self?.ended(finished) } }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        return process
    }

    private func received(_ lines: [Data]) {
        for line in lines {
            let head = line.prefix(32)
            guard let colon = head.firstIndex(of: UInt8(ascii: ":")) else { continue }
            let digits = head[head.index(after: colon)...].drop { $0 == 0x20 }.prefix { (0x30...0x39).contains($0) }
            guard let id = Int(String(decoding: digits, as: UTF8.self)) else { continue }
            waiting.removeValue(forKey: id)?.resume(returning: line)
        }
    }

    private func expire(_ id: Int, process expired: ObjectIdentifier) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        continuation.resume(throwing: BridgeFailure(message: "The bridge took too long."))
        if let process, ObjectIdentifier(process) == expired { stop() }
    }

    private func ended(_ finished: Process) {
        if finished === process { process = nil; input = nil }
        fail("The bridge stopped.")
    }

    private func fail(_ message: String) {
        let pending = waiting
        waiting = [:]
        for (_, continuation) in pending { continuation.resume(throwing: BridgeFailure(message: message)) }
    }
}

struct LineBuffer {
    private var buffer = Data()
    mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var out: [Data] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            out.append(Data(buffer[buffer.startIndex..<end]))
            buffer.removeSubrange(buffer.startIndex...end)
        }
        return out
    }
}
