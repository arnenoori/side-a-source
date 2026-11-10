import Foundation

/// Runs a program to its end without holding a Swift concurrency thread for it. Stdout and stderr drain at the same
/// time, so a child that fills one pipe while the other is read never stalls; stdin is `input` or the null device.
/// A run past `timeout` gets SIGTERM, and SIGKILL a second later if that didn't end it; a second after that the
/// caller has its answer even if something the child started still holds a pipe open.
enum ProcessRunner {
    struct Result: Sendable {
        var status: Int32 = -1
        var output = Data()
        var errors = Data()
        var elapsed: TimeInterval = 0
        var timedOut = false
        /// Why it couldn't start; nothing ran.
        var launchError: (any Error)?
    }

    /// `environment` overrides and `removing` drops keys of this app's environment, which the child otherwise gets
    /// whole. `group` signals the child's process group on timeout, for a child that leads one.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:], removing: [String] = [],
                    input: Data? = nil, timeout: TimeInterval?, priority: QualityOfService = .default, group: Bool = false) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.qualityOfService = priority
        if !environment.isEmpty || !removing.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for key in removing { merged.removeValue(forKey: key) }
            merged.merge(environment) { $1 }
            process.environment = merged
        }
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let run = Run()
        return await withCheckedContinuation { continuation in
            run.continuation = continuation
            process.terminationHandler = { finished in run.finish { $0.result.status = finished.terminationStatus } }
            do { try process.run() } catch {
                process.terminationHandler = nil
                return continuation.resume(returning: Result(launchError: error))
            }
            DispatchQueue.global().async { let data = output.fileHandleForReading.readDataToEndOfFile(); run.finish { $0.result.output = data } }
            DispatchQueue.global().async { let data = errors.fileHandleForReading.readDataToEndOfFile(); run.finish { $0.result.errors = data } }
            if let input {
                // A child that exits without reading must not take this app down with SIGPIPE.
                signal(SIGPIPE, SIG_IGN)
                DispatchQueue.global().async {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                }
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard run.waiting else { return }
                    run.finish(counts: false) { $0.result.timedOut = true }
                    // Exited, but something it started still holds a pipe open: the caller doesn't wait for that.
                    guard process.isRunning else { return run.abandon() }
                    stop(process, group: group, signal: SIGTERM)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        stop(process, group: group, signal: SIGKILL)
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { run.abandon() }
                    }
                }
            }
        }
    }

    /// Only while the process is unreaped, so its pid, and the group it leads, are still this run's.
    private static func stop(_ process: Process, group: Bool, signal: Int32) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if group { kill(-pid, signal) }
        kill(pid, signal)
    }

    /// Exit, stdout's end and stderr's end, in whatever order they come.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let started = Date()
        private var pending = 3
        var result = Result()
        var continuation: CheckedContinuation<Result, Never>?

        func finish(counts: Bool = true, _ update: (Run) -> Void) {
            lock.lock()
            update(self)
            if counts { pending -= 1 }
            let done = counts && pending == 0
            var result = self.result
            result.elapsed = Date().timeIntervalSince(started)
            let continuation = done ? self.continuation : nil
            if done { self.continuation = nil }
            lock.unlock()
            continuation?.resume(returning: result)
        }

        var waiting: Bool { lock.lock(); defer { lock.unlock() }; return continuation != nil }

        /// Returns what there is so far, once.
        func abandon() {
            lock.lock()
            var result = self.result
            result.elapsed = Date().timeIntervalSince(started)
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }
}
