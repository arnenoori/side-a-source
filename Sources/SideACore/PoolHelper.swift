import Foundation
import SideAProtocol

/// The app serves the pool while it runs; the helper serves it on the same port and key while it doesn't, so a session
/// started through the pool keeps working after Side A quits or crashes.
public struct PoolFiles: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// "url key pid", read by the shell hook.
    public var pool: URL { root.appendingPathComponent("runtime/pool") }
    /// Kept across launches: running sessions hold it.
    public var key: URL { root.appendingPathComponent("runtime/pool-key") }
    public var app: URL { root.appendingPathComponent("runtime/pool-app") }
    /// Gone when pool mode is off.
    public var plan: URL { root.appendingPathComponent("runtime/pool-plan.json") }

    /// "pid started", started being the process's start time, so a pid the system gave to another process since doesn't count.
    public static func claim(pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String {
        "\(pid) \(started(pid).map { String($0) } ?? "0")\n"
    }

    public var appRunning: Bool {
        guard let text = try? String(contentsOf: app, encoding: .utf8) else { return false }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard let pid = parts.first.flatMap({ Int32($0) }), pid > 0, let started = Self.started(pid) else { return false }
        return parts.count < 2 || parts[1] == "0" || parts[1] == Substring(String(started))
    }

    /// Microseconds since 1970, or nil when no such process runs.
    static func started(_ pid: Int32) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        return Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec)
    }
}

public struct PoolPlan: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Sendable {
        public let id: String
        public let provider: AgentProvider
        public let name: String
        public let priority: AccountPriority?
        /// A window past its reset no longer counts, so a full account comes back on its own.
        public let usage: AccountUsage?
        public init(id: String, provider: AgentProvider, name: String, priority: AccountPriority?, usage: AccountUsage?) {
            self.id = id; self.provider = provider; self.name = name; self.priority = priority; self.usage = usage
        }
    }

    public let python: String
    public let bridge: String
    public let members: [Member]
    /// Autopilot's "full", in percent.
    public let full: Double

    public init(python: String, bridge: String, members: [Member], full: Double) {
        self.python = python; self.bridge = bridge; self.members = members; self.full = full
    }
}

public enum PoolBridge {
    public struct Failure: LocalizedError, BridgeError, Sendable {
        public let message: String
        public var kind: BridgeErrorKind = .other
        public var errorDescription: String? { message }
        public init(message: String, kind: BridgeErrorKind = .other) { self.message = message; self.kind = kind }
        public init(stderr: String) { (kind, message) = BridgeErrorKind.parse(stderr) }
    }

    public static func run(python: String, bridge: String, root: URL, _ args: [String], timeout: TimeInterval = 60) async throws -> Data {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [bridge, "--root", root.path] + args
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            // The bridge leads its own process group; stopping the group also stops a hung child.
            let watchdog = DispatchWorkItem { if process.isRunning { kill(-process.processIdentifier, SIGTERM); process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            defer { watchdog.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(stderr: message.flatMap { $0.isEmpty ? nil : $0 } ?? "The bridge stopped (\(process.terminationStatus)).")
            }
            return data
        }.value
    }
}

@MainActor public final class PoolFallback: PoolDecisions {
    public private(set) var plan: PoolPlan
    private let root: URL
    private let bridge: ([String]) async throws -> Data
    private let log: (String) -> Void
    private let clock: () -> Double
    private var router = PoolRouter()
    private var blocked: [String: Double] = [:]
    private let tokens = PoolTokenCache()

    public init(plan: PoolPlan, root: URL, log: @escaping (String) -> Void,
                bridge: (([String]) async throws -> Data)? = nil, clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.plan = plan
        self.root = root
        self.log = log
        self.clock = clock
        self.bridge = bridge ?? { args in try await PoolBridge.run(python: plan.python, bridge: plan.bridge, root: root, args) }
    }

    public func update(_ plan: PoolPlan) {
        self.plan = plan
    }

    private func members(_ provider: AgentProvider) -> [PoolPlan.Member] {
        // Stable: equal priorities keep the app's order.
        plan.members.enumerated().filter { $0.element.provider == provider }
            .sorted { (($0.element.priority ?? .normal).rank, $0.offset) < (($1.element.priority ?? .normal).rank, $1.offset) }
            .map(\.element)
    }

    public func poolAccount(_ provider: AgentProvider, session: String?, excluding: Set<String>) -> String? {
        let now = clock()
        let full = plan.full
        let open = members(provider).filter { !excluding.contains($0.id) && (blocked[$0.id] ?? 0) <= now }
        let usable = { (id: String) in
            open.first { $0.id == id }.map { member in member.usage.map { Planner.hasHeadroom($0, full: full, now: now) } ?? true } ?? false
        }
        return router.route(session: session, now: now, usable: usable) {
            open.first { usable($0.id) }?.id
                // Unread usage may be stale; Codex serves a full account from its credits.
                ?? (provider == .codex ? open.first?.id : nil)
        }
    }

    public func poolToken(_ account: String, refused: Bool) async throws -> PoolCredential {
        let codex = plan.members.first { $0.id == account }?.provider == .codex
        return try await tokens.token(account, refused: refused, codex: codex, now: clock(), bridge: bridge)
    }

    public func poolTokenFailed(_ account: String, _ error: any Error) {
        let message = error.localizedDescription
        tokens.forget(account)
        blocked[account] = clock() + (BridgeErrorKind(error) == .signIn ? 600 : 120)
        log("\(name(account))'s login couldn't be read: \(message)")
    }

    public func poolAnswered(_ account: String, status: Int, headers: HTTPHeaders) {
        let now = clock()
        let codex = plan.members.first { $0.id == account }?.provider == .codex
        switch status {
        case 429:
            blocked[account] = codex ? Pool.codexRetryAt(headers, now: now) : Pool.retryAt(headers, now: now)
            log("\(name(account)) is at its limit; new requests go to another account.")
        case 401, 403:
            if status == 401 { tokens.forget(account) }
            blocked[account] = now + 600
            log("\(name(account)) refused a request (\(status)); trying it again in 10 minutes.")
        default:
            blocked[account] = nil
        }
    }

    public func poolRefused(_ provider: AgentProvider?, status: Int, message: String) {
        log("answered \(status): \(message)")
    }

    public func poolHealthReport() -> [String: Int] {
        let now = clock()
        let full = plan.full
        var health: [String: Int] = [:]
        for provider in AgentProvider.allCases {
            health[provider.rawValue] = members(provider).filter { member in
                (blocked[member.id] ?? 0) <= now && (provider == .codex || member.usage.map { Planner.hasHeadroom($0, full: full, now: now) } ?? true)
            }.count
        }
        return health
    }

    private func name(_ account: String) -> String { plan.members.first { $0.id == account }?.name ?? account }
}

/// Side A's pool while the app isn't running (SideAPool, a launchd agent the app registers with pool mode on).
@MainActor public final class PoolHelper {
    private let files: PoolFiles
    private let version: String
    private let installed: () -> String?
    /// Replies the proxy is still streaming finish within this of a handback, before an updated helper restarts.
    private let drain: TimeInterval
    private var stoppedAt: Date?
    private let logFile: URL
    private var proxy: PoolProxy?
    private var decisions: PoolFallback?
    /// The proxy holds its decisions weakly; replies still streaming after a handback need theirs.
    private var handedBack: [(decisions: PoolFallback, at: Date)] = []
    private var lastFailure: String?
    private let port: UInt16
    private let bridge: (([String]) async throws -> Data)?

    /// `version`: what this process runs; `installed`: what's on disk now, read afresh each time.
    public init(root: URL, version: String, installed: @escaping () -> String?, logs: URL, port: UInt16 = PoolProxy.preferredPort,
                drain: TimeInterval = 600, bridge: (([String]) async throws -> Data)? = nil) {
        files = PoolFiles(root: root)
        self.version = version
        self.installed = installed
        self.drain = drain
        self.port = port
        self.bridge = bridge
        logFile = logs.appendingPathComponent("pool-helper.log")
    }

    public var serving: Bool { proxy != nil }

    /// Returns the process's exit status once it should leave.
    public func run() async -> Int32 {
        log("started, version \(version)")
        while true {
            if let status = await tick() { return status }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// One look at the files; an exit status once an updated helper should take over. It never leaves on its own
    /// otherwise: pool mode off unregisters it, and leaving with a status launchd doesn't restart would leave nobody to
    /// serve if pool mode came back on.
    public func tick() async -> Int32? {
        let updated = installed().map { $0 != version } ?? false
        if let data = try? Data(contentsOf: files.plan) {
            if let plan = try? JSONDecoder().decode(PoolPlan.self, from: data) {
                if files.appRunning { stop("Side A is serving the pool") } else if let decisions { decisions.update(plan) } else { await start(plan) }
            } else {
                // A plan from a newer app: the updated helper reads it.
                stop("the plan can't be read")
                failed("Side A's plan can't be read by this version")
            }
        } else {
            stop("pool mode is off")
        }
        guard updated, proxy == nil else { return nil }
        if let stoppedAt, Date().timeIntervalSince(stoppedAt) < drain { return nil }
        log("Side A was updated; restarting")
        return 75
    }

    private func start(_ plan: PoolPlan) async {
        guard let key = (try? String(contentsOf: files.key, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), key.count == 64 else {
            failed("no pool key yet")
            return
        }
        let decisions = PoolFallback(plan: plan, root: files.root, log: { [weak self] in self?.log($0) }, bridge: bridge)
        let proxy = PoolProxy(key: key, decisions: decisions)
        do {
            let port = try await proxy.start(port: self.port, exactly: true)
            guard !files.appRunning else { proxy.stop(); return }
            try Self.writePrivate("http://127.0.0.1:\(port) \(key) \(ProcessInfo.processInfo.processIdentifier)\n", to: files.pool)
            self.proxy = proxy
            self.decisions = decisions
            lastFailure = nil
            log("serving the pool at 127.0.0.1:\(port) with \(plan.members.count) accounts")
        } catch {
            proxy.stop()
            failed("couldn't open port \(self.port): \(error.localizedDescription)")
        }
    }

    /// Never readable by others, not even for a moment: the file holds the pool's key.
    private static func writePrivate(_ text: String, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    private func stop(_ reason: String) {
        guard let proxy else { return }
        proxy.stop()
        self.proxy = nil
        let now = Date()
        handedBack = handedBack.filter { now.timeIntervalSince($0.at) < 7200 } + (decisions.map { [($0, now)] } ?? [])
        decisions = nil
        stoppedAt = now
        log("stopped: \(reason)")
    }

    private func failed(_ message: String) {
        guard message != lastFailure else { return }
        lastFailure = message
        log(message)
    }

    private func log(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: logFile) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
