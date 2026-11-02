import Foundation

actor SessionBridge {
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]?
    private var process: Process?
    private var input: FileHandle?
    private var next = 0
    private var waiting: [Int: (continuation: CheckedContinuation<Data, Error>, process: ObjectIdentifier)] = [:]

    /// `environment` replaces the inherited one; the Remote harness points HOME at its own transcripts with it.
    init(python: String, bridge: URL, root: URL, environment: [String: String]? = nil) {
        executable = URL(fileURLWithPath: python)
        arguments = [bridge.path, "--root", root.path, "sessions", "serve"]
        self.environment = environment
    }

    func request<T: Decodable & Sendable>(_ args: [String], as type: T.Type, timeout: Duration = .seconds(30)) async throws -> T {
        try Self.decode(try await send(args, timeout: timeout), as: type)
    }

    /// The raw reply, for callers that keep a copy to decode later.
    func data(_ args: [String], timeout: Duration = .seconds(30)) async throws -> Data {
        try await send(args, timeout: timeout)
    }

    func warm() throws { _ = try start() }

    static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let reply = try decoder.decode(Reply<T>.self, from: data)
        if let error = reply.error { throw BridgeFailure(message: error) }
        guard let result = reply.result else { throw BridgeFailure(message: "Session search did not answer.") }
        return result
    }

    func stop() {
        guard let process else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminate()
        self.process = nil
        input = nil
        fail(ObjectIdentifier(process), "Session search stopped. Try again.")
    }

    private func send(_ args: [String], timeout: Duration) async throws -> Data {
        let process = try start()
        next += 1
        let id = next
        var line = try JSONSerialization.data(withJSONObject: ["id": id, "args": args])
        line.append(0x0A)
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id)
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = (continuation, ObjectIdentifier(process))
            do { try input?.write(contentsOf: line) } catch { waiting.removeValue(forKey: id)?.continuation.resume(throwing: error) }
        }
    }

    private func start() throws -> Process {
        if let process { return process }
        // A write after the process exits must fail with EPIPE instead of killing the app.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let lines = LineReader()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            for line in lines.feed(data) {
                Task { await self?.deliver(line) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            Task { await self?.ended(finished) }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        return process
    }

    /// The bridge writes `{"id": N, …}` first, so the reply is routed without parsing all of it.
    private func deliver(_ line: Data) {
        let head = line.prefix(32)
        guard let colon = head.firstIndex(of: UInt8(ascii: ":")) else { return }
        let digits = head[head.index(after: colon)...].drop { $0 == 0x20 }.prefix { (0x30...0x39).contains($0) }
        guard let id = Int(String(decoding: digits, as: UTF8.self)) else { return }
        waiting.removeValue(forKey: id)?.continuation.resume(returning: line)
    }

    /// A stuck request restarts only the process it was sent to, never a newer one.
    private func expire(_ id: Int) {
        guard let request = waiting.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: BridgeFailure(message: "Session search took too long."))
        if let process, ObjectIdentifier(process) == request.process { stop() }
    }

    private func ended(_ finished: Process) {
        if finished === process {
            process = nil
            input = nil
        }
        fail(ObjectIdentifier(finished), "Session search stopped. Try again.")
    }

    private func fail(_ process: ObjectIdentifier, _ message: String) {
        for (id, request) in waiting where request.process == process {
            waiting[id] = nil
            request.continuation.resume(throwing: BridgeFailure(message: message))
        }
    }

    private struct Reply<T: Decodable>: Decodable {
        let result: T?
        let error: String?
    }
}

/// readabilityHandler runs serially, so the partial line needs no lock.
private final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<end])
            buffer.removeSubrange(buffer.startIndex...end)
        }
        return lines
    }
}
