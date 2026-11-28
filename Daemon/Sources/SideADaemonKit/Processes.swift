import Foundation

/// One finished child process.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: String
    public let errors: String
    public let timedOut: Bool
}

/// Runs programs without a shell. Arguments are never joined into a command line, and stdin is closed unless text is given
/// (a program that waits on a terminal prompt then fails at once instead of hanging the daemon).
///
/// This is `posix_spawn` and `waitpid` rather than Foundation's `Process`: on Linux, `Process` never noticed the exit of
/// `tmux new-session -d`, whose client forks its server, so the call waited for ever. Output goes to files, not pipes, for
/// the same reason: the server it leaves behind holds a pipe's write end open, and reading to end of file would wait for
/// the server instead of the program.
public enum Run {
    public static func process(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, input: Data? = nil,
                               timeout: TimeInterval = 30) async -> ProcessResult {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidead-run-\(UUID().uuidString)")
        let outFile = folder.appendingPathComponent("out"), errFile = folder.appendingPathComponent("err")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return ProcessResult(status: 127, output: "", errors: "no room for the program's output: \(error)", timedOut: false)
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let outFD = open(outFile.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        let errFD = open(errFile.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        var pipeFDs: [Int32] = [-1, -1]
        if input != nil {
            _ = pipe(&pipeFDs)
            // The child gets the read end as its stdin; a copy of the write end would keep its stdin from ever ending.
            for descriptor in pipeFDs { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        }
        let nullFD = input == nil ? open("/dev/null", O_RDONLY | O_CLOEXEC) : -1
        defer { for descriptor in [outFD, errFD, nullFD] where descriptor >= 0 { close(descriptor) } }
        guard outFD >= 0, errFD >= 0 else { return ProcessResult(status: 127, output: "", errors: "no room for the program's output", timedOut: false) }

        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        #else
        var actions: posix_spawn_file_actions_t?
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input == nil ? nullFD : pipeFDs[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outFD, 1)
        posix_spawn_file_actions_adddup2(&actions, errFD, 2)
        // A server the program starts must not keep the daemon's sockets and pipes open: `tmux new-session` forks a server
        // that outlives the daemon, and one holding the listener keeps the port bound after it stops. NIO sets no
        // close-on-exec, so every descriptor but the three above is closed here. Darwin has no `addclosefrom`: its
        // `POSIX_SPAWN_CLOEXEC_DEFAULT`, set below, does the same.
        #if os(Linux)
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        #endif

        // The daemon ignores SIGTERM and SIGPIPE (it handles them itself); a program it starts must begin with the defaults,
        // with nothing blocked, or it could neither be stopped nor see a broken pipe.
        #if os(Linux)
        var attributes = posix_spawnattr_t()
        #else
        var attributes: posix_spawnattr_t?
        #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var everything = sigset_t(), nothing = sigset_t()
        sigfillset(&everything)
        sigemptyset(&nothing)
        posix_spawnattr_setsigdefault(&attributes, &everything)
        posix_spawnattr_setsigmask(&attributes, &nothing)
        #if canImport(Darwin)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        #else
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        #endif

        let settings = environment ?? ProcessInfo.processInfo.environment
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = settings.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var spawnedPID: pid_t = 0
        let spawned = posix_spawn(&spawnedPID, executable, &actions, &attributes, argv, envp)
        if input != nil { close(pipeFDs[0]) }
        guard spawned == 0 else {
            if input != nil { close(pipeFDs[1]) }
            return ProcessResult(status: 127, output: "", errors: "\(executable) couldn't start (\(String(cString: strerror(spawned))))", timedOut: false)
        }
        if let input {
            // SIGPIPE is ignored by the daemon, so a program that exits first fails the write instead of killing us.
            input.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = write(pipeFDs[1], base + offset, raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            close(pipeFDs[1])
        }
        let finished = Finished()
        let pid = spawnedPID
        let waiter = Thread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            finished.fire(status)
        }
        waiter.start()
        let timer = Task {
            try await Task.sleep(for: .seconds(timeout))
            finished.timedOut()
            kill(pid, SIGTERM)
        }
        let raw = await finished.wait()
        timer.cancel()
        // Exited normally: the code. Killed by a signal: 128 plus it, as a shell reports it.
        let status: Int32 = (raw & 0x7F) == 0 ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F)
        return ProcessResult(status: status, output: String(decoding: (try? Data(contentsOf: outFile)) ?? Data(), as: UTF8.self),
                             errors: String(decoding: (try? Data(contentsOf: errFile)) ?? Data(), as: UTF8.self), timedOut: finished.didTimeOut)
    }

    final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var late = false
        private var waiters: [CheckedContinuation<Int32, Never>] = []

        func fire(_ code: Int32) {
            lock.lock(); status = code; let pending = waiters; waiters = []; lock.unlock()
            for waiter in pending { waiter.resume(returning: code) }
        }

        func timedOut() { lock.lock(); late = true; lock.unlock() }
        var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return late }

        func wait() async -> Int32 {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let status { lock.unlock(); continuation.resume(returning: status); return }
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// The first executable called `name` on `PATH` (and `extra`), or nil.
    public static func which(_ name: String, extra: [String] = [], environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let folders = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init) + extra
        return folders.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

extension Run {
    /// A process that runs: one a signal reaches, and not one that ended and waits to be reaped, which `kill(pid, 0)`
    /// cannot tell apart. tmux 3.4, the oldest Linux hosting supports, can leave a remain-on-exit pane's agent so until
    /// another of its children ends; the bridge reads it the same way (`hostos.exited`).
    public static func running(_ pid: Int) -> Bool { pid > 1 && (kill(pid_t(pid), 0) == 0 || errno == EPERM) && !exited(pid) }

    static func exited(_ pid: Int) -> Bool {
        #if os(Linux)
        // The name in parentheses may itself hold spaces and parentheses; the state follows the last one.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let name = stat.lastIndex(of: ")") else { return false }
        return stat[stat.index(after: name)...].split(separator: " ").first.map { $0 == "Z" || $0 == "X" } ?? false
        #else
        return false
        #endif
    }
}

/// `read(2)`, named so it isn't taken for `FileHandle.read`.
private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
    #else
    Glibc.read(descriptor, buffer, count)
    #endif
}

extension FileHandle {
    /// What `read(2)` returns next, retrying when a signal interrupts it; empty at the end. Foundation's `availableData` treats
    /// EINTR as fatal on Linux, and a child's exit signals this process (it showed under amd64 emulation).
    func nextChunk(limit: Int = 65_536) -> Data {
        var buffer = [UInt8](repeating: 0, count: limit)
        while true {
            let descriptor = fileDescriptor
            let count = buffer.withUnsafeMutableBytes { systemRead(descriptor, $0.baseAddress, limit) }
            if count > 0 { return Data(buffer[0..<count]) }
            if count == 0 || errno != EINTR { return Data() }
        }
    }
}
