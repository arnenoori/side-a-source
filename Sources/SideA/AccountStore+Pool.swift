import AppKit
import Foundation
import ServiceManagement
import SideACore

enum PoolShareState: Equatable {
    case off, connecting
    case shared(command: String)
    case problem(String)
}

extension AccountStore: PoolDecisions {
    var poolFiles: PoolFiles { PoolFiles(root: root) }
    var poolFile: URL { poolFiles.pool }
    private var poolKeyFile: URL { poolFiles.key }
    /// SideAPool: serves the pool on its port while the app isn't running.
    private var poolHelper: SMAppService { Self.poolHelper() }
    /// A local build registers its own, so it never stops or replaces the installed app's.
    nonisolated static func poolHelper() -> SMAppService {
        SMAppService.agent(plistName: Bundle.main.bundleIdentifier == "com.arnenoori.sidea.dev" ? "com.sidea.pool.dev.plist" : "com.sidea.pool.plist")
    }
    private var poolShareKeyFile: URL { root.appendingPathComponent("runtime/pool-share-key") }

    func setPoolShare(_ enabled: Bool) async {
        config.poolShare = enabled
        persist()
        await syncPoolShare()
    }

    /// The old key stops working at once: Macs that joined need the new command.
    func newPoolShareKey() async {
        try? FileManager.default.removeItem(at: poolShareKeyFile)
        await syncPoolShare()
    }

    /// One pass at a time, so two listeners can't race to be `shared`; a change during a pass runs another after it.
    /// Turning off takes effect before anything else.
    func syncPoolShare() async {
        poolShareGeneration += 1
        if config.poolShare != true { pool?.unshare(); poolShareState = .off }
        guard !poolShareRunning else { return }
        poolShareRunning = true
        defer { poolShareRunning = false }
        var generation: Int
        repeat {
            generation = poolShareGeneration
            await applyPoolShare(generation)
        } while generation != poolShareGeneration
    }

    private func applyPoolShare(_ generation: Int) async {
        guard let pool, config.poolShare == true else {
            pool?.unshare()
            poolShareState = .off
            return
        }
        poolShareState = .connecting
        let status = await tailscaleStatus()
        guard generation == poolShareGeneration, self.pool === pool else { return }
        guard let address = status.addresses.first(where: { !$0.contains(":") }), let login = status.login, !login.isEmpty else {
            pool.unshare()
            poolShareState = .problem("Turn on Tailscale on this Mac to share its pool.")
            return
        }
        guard !Pool.sharedIdentity(login) else {
            pool.unshare()
            poolShareState = .problem("This Mac is a tagged Tailscale device, so Side A can't tell your devices from others. Sign it in as yourself to share its pool.")
            return
        }
        do {
            let key = try privateKey(poolShareKeyFile)
            let peers = PoolPeers(login: login)
            let port = try await pool.share(on: address, port: poolPreferredPort, gate: PoolGate(key: key, admit: { await peers.admits($0) }))
            // The listener opened while the setting moved on: nothing listens unless a later pass opens it again.
            guard generation == poolShareGeneration, self.pool === pool else { pool.unshare(); return }
            poolShareState = .shared(command: Pool.joinCommand(address: address, port: port, key: key))
            autopilotLog.write("Pool shared with \(login)'s devices at \(address):\(port).")
        } catch {
            guard generation == poolShareGeneration else { return }
            poolShareState = .problem("Couldn't share the pool: \(error.localizedDescription)")
        }
    }

    func setPool(_ enabled: Bool) async {
        config.pool = enabled
        persist()
        if enabled && !shellSwitching { await setShellSwitching(true) }
        await syncPool()
    }

    func syncPool() async {
        guard !isDemo || checksLogins else { return }
        guard config.pool == true else {
            pool?.stop()
            // A start under way sees pool mode off when it finishes, and stops.
            if case .starting = poolRun {} else { poolRun = .off }
            poolShareGeneration += 1
            poolShareState = .off
            // The plan first: a helper that finds none leaves for good.
            for file in [poolFiles.plan, poolFiles.app, poolFile] { try? FileManager.default.removeItem(at: file) }
            lastPoolPlan = nil
            if poolHelper.status != .notRegistered {
                try? await poolHelper.unregister()
                // Turned back on while it went: that start found it still registered and left it.
                if config.pool == true { registerPoolHelper() }
            }
            await syncCodexPoolHomes()
            return
        }
        switch poolRun {
        case .starting, .running: return
        case .off, .failed: poolRun = .starting
        }
        do {
            let proxy = PoolProxy(key: try poolKey(), decisions: self)
            // Claimed before the port: the helper lets it go within a second of seeing this process named here.
            try writePrivate(PoolFiles.claim(), to: poolFiles.app)
            let port: UInt16
            do { port = try await takePoolPort(proxy) } catch {
                // Nobody serves under this claim, so the helper mustn't stand down for it.
                try? FileManager.default.removeItem(at: poolFiles.app)
                throw error
            }
            // Turned off while it started.
            guard config.pool == true else { proxy.stop(); poolRun = .off; return }
            // Turning pool mode off and on while the port opened removed the claim.
            try writePrivate(PoolFiles.claim(), to: poolFiles.app)
            // The file first: a pool with no file to find would serve nobody and block every retry.
            do {
                try writePrivate("http://127.0.0.1:\(port) \(proxy.key) \(ProcessInfo.processInfo.processIdentifier)\n", to: poolFile)
            } catch {
                proxy.stop()
                throw error
            }
            poolRun = .running(proxy, port: port)
            if poolQuitObserver == nil {
                // The helper takes over once the claim is gone. Without one, no pool file is left for shells to find, so
                // commands use logins again at once.
                let files = poolFiles
                poolQuitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                    try? FileManager.default.removeItem(at: files.app)
                    if Self.poolHelper().status != .enabled { try? FileManager.default.removeItem(at: files.pool) }
                }
            }
            autopilotLog.write("Pool mode on, at 127.0.0.1:\(port).")
            writePoolPlan()
            registerPoolHelper()
            await syncPoolShare()
            await syncCodexPoolHomes()
        } catch {
            poolRun = config.pool == true ? .failed(error.localizedDescription) : .off
            self.error = "Pool mode couldn't start: \(error.localizedDescription)"
        }
    }

    /// The fixed port, waiting up to 10 s for the helper to let it go; any free port if something else holds it.
    private func takePoolPort(_ proxy: PoolProxy) async throws -> UInt16 {
        for _ in 0..<50 {
            if let port = try? await proxy.start(port: poolPreferredPort, exactly: true) { return port }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return try await proxy.start(port: poolPreferredPort)
    }

    /// What the helper serves by while the app is gone, rewritten as accounts and their usage change.
    func writePoolPlan() {
        guard pool != nil, !isDemo, let python, let bridgeURL else { return }
        let members = AgentProvider.allCases.flatMap(poolMembers).filter { health[$0.id]?.takesWork != false }.map { account in
            PoolPlan.Member(id: account.id, provider: account.provider, name: account.name, priority: account.priority, usage: usage[account.id])
        }
        let plan = PoolPlan(python: python, bridge: bridgeURL.path, members: members, full: config.moveAt)
        guard plan != lastPoolPlan || !FileManager.default.fileExists(atPath: poolFiles.plan.path),
              let data = try? JSONEncoder().encode(plan) else { return }
        do {
            try writePrivate(String(decoding: data, as: UTF8.self), to: poolFiles.plan)
            lastPoolPlan = plan
        } catch {
            autopilotLog.note("pool plan", "Pool: the plan for while Side A is closed couldn't be saved: \(error.localizedDescription)")
        }
    }

    private func registerPoolHelper() {
        guard !isDemo, poolHelper.status != .enabled else { return }
        do {
            try poolHelper.register()
        } catch {
            // A build run outside its app bundle has no agent to register; the pool still works while the app runs.
            autopilotLog.note("pool helper", "Pool: the helper that serves while Side A is closed couldn't start: \(error.localizedDescription)")
        }
    }

    /// Kept across launches: sessions already running hold this key, and an update relaunches the app under them.
    private func poolKey() throws -> String { try privateKey(poolKeyFile) }

    private func privateKey(_ file: URL) throws -> String {
        if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), saved.count == 64 {
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.featureUnsupported) }
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        try writePrivate(key + "\n", to: file)
        return key
    }

    private func writePrivate(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// Accounts the pool may hand `provider`'s requests to.
    func poolMembers(_ provider: AgentProvider) -> [Account] {
        config.accounts.filter { $0.provider == provider && $0.ready && $0.allowAuto }
    }

    func poolAccount(_ provider: AgentProvider, session: String?, excluding: Set<String>) -> String? {
        let now = Date().timeIntervalSince1970
        let full = config.moveAt
        let planned = provider == .claude ? planning(usage) : usage
        let members = poolMembers(provider).filter { account in
            !excluding.contains(account.id) && (poolBlocked[account.id] ?? 0) <= now && health[account.id]?.takesWork != false
        }.sorted { ($0.priority ?? .normal).rank < ($1.priority ?? .normal).rank }
        let usable = { (id: String) in
            members.contains { $0.id == id } && planned[id].map { Planner.hasHeadroom($0, full: full, now: now) } ?? true
        }
        let chosen = poolRouter.route(session: session, now: now, usable: usable) {
            Planner.best(members, usage: planned, health: health, active: activeIDs[provider], full: full, now: now)
                // Unread or stale accounts are still worth a try before refusing the request.
                ?? members.first { usable($0.id) }?.id
                // Codex serves a full account from its credits and says 429 if it has none, so that call is OpenAI's.
                ?? (provider == .codex ? members.first?.id : nil)
        }
        poolConversations = poolRouter.conversations
        return chosen
    }

    func poolToken(_ account: String, refused: Bool) async throws -> PoolCredential {
        let codex = config.accounts.first { $0.id == account }?.provider == .codex
        return try await poolTokens.token(account, refused: refused, codex: codex, now: Date().timeIntervalSince1970) { [unowned self] in
            try await self.bridgeOutput($0)
        }
    }

    func poolTokenFailed(_ account: String, _ error: any Error) {
        let message = error.localizedDescription
        let name = config.accounts.first { $0.id == account }?.name ?? account
        poolTokens.forget(account)
        if BridgeErrorKind(error) == .signIn {
            poolBlocked[account] = Date().timeIntervalSince1970 + 600
            if health[account]?.takesWork != false { health[account] = .signIn() }
            warnSignIn(account, message)
        } else {
            // Busy or unreachable for a moment (Claude Code renewing it, the Keychain slow): not a dead login.
            poolBlocked[account] = Date().timeIntervalSince1970 + 120
        }
        autopilotLog.note("pool \(account)", "Pool: \(name)'s login couldn't be read: \(message)")
    }

    func poolAnswered(_ account: String, status: Int, headers: HTTPHeaders) {
        let now = Date().timeIntervalSince1970
        let found = config.accounts.first { $0.id == account }
        let name = found?.name ?? account
        let codex = found?.provider == .codex
        takeLive(codex ? Pool.codexLimits(headers) : Pool.limits(headers), for: account, at: now)
        switch status {
        case 429:
            poolBlocked[account] = codex ? Pool.codexRetryAt(headers, now: now) : Pool.retryAt(headers, now: now)
            autopilotLog.note("pool \(account)", "Pool: \(name) is at its limit; new requests go to another account.")
        case 403:
            poolBlocked[account] = now + 600
            autopilotLog.note("pool \(account)", "Pool: \(name) refused a request (403); trying it again in 10 minutes.")
        case 401:
            poolTokens.forget(account)
            poolBlocked[account] = now + 600
            if health[account]?.takesWork != false { health[account] = .signIn() }
            warnSignIn(account, "Sign in")
            autopilotLog.note("pool \(account)", "Pool: \(name)'s login was refused (\(status)).")
        default:
            poolBlocked[account] = nil
            if status < 400 {
                var activity = poolHealth[found?.provider ?? .claude] ?? PoolActivity()
                activity.served += 1
                activity.servedAt = now
                activity.servedBy = name
                poolHealth[found?.provider ?? .claude] = activity
            }
        }
    }

    func poolRefused(_ provider: AgentProvider?, status: Int, message: String) {
        var activity = poolHealth[provider ?? .claude] ?? PoolActivity()
        activity.failedAt = Date().timeIntervalSince1970
        activity.failure = message
        poolHealth[provider ?? .claude] = activity
        autopilotLog.note("pool refused \(provider?.rawValue ?? "other")", "Pool: answered \(status): \(message)")
    }

    func poolHealthReport() -> [String: Int] {
        let now = Date().timeIntervalSince1970
        let full = config.moveAt
        var health: [String: Int] = [:]
        for provider in AgentProvider.allCases {
            // A full Codex account can still answer from its credits.
            let ready = poolMembers(provider).filter { account in
                self.health[account.id]?.takesWork != false && (provider == .codex || usage[account.id].map { Planner.hasHeadroom($0, full: full, now: now) } ?? true)
            }
            health[provider.rawValue] = ready.count
        }
        return health
    }

    /// Checks every member's login with the service's usage endpoint, renewing one that is due; no model runs, no quota is spent.
    /// A Mac that joined another's pool asks that one instead.
    func testPool() async {
        guard !poolTesting else { return }
        poolTesting = true
        defer { poolTesting = false }
        await checkRemotePool()
        guard pool != nil else { poolTest = nil; return }
        var results: [String: String] = [:]
        for account in AgentProvider.allCases.flatMap(poolMembers) {
            do {
                _ = try await poolToken(account.id, refused: false)
                _ = try await bridgeOutput(["usage", account.id])
                if health[account.id]?.takesWork == false { health[account.id] = nil; poolBlocked[account.id] = nil }
                results[account.id] = (poolBlocked[account.id] ?? 0) > Date().timeIntervalSince1970 ? "Login works; resting after a refusal" : "Ready"
            } catch where [.rateLimited, .idle].contains(BridgeErrorKind(error)) {
                results[account.id] = "Ready"
            } catch {
                poolTokenFailed(account.id, error)
                results[account.id] = error.localizedDescription.replacingOccurrences(of: "Side A: ", with: "")
            }
        }
        poolTest = results
    }

    /// `codex` goes through a pool only while that pool has a Codex account to serve it; the shell checks for this home's config.
    func syncCodexPoolHomes() async {
        guard !isDemo else { return }
        await checkRemotePool()
        let local = poolPort.flatMap { poolMembers(.codex).isEmpty ? nil : "http://127.0.0.1:\($0)" }
        let remote = remotePool.flatMap { $0.codexAccounts > 0 ? $0.url : nil }
        for (isRemote, url) in [(false, local), (true, remote)] where codexPoolHomes[isRemote] != (url ?? "") {
            guard (try? await bridgeOutput(["codex-pool-home"] + (url.map { ["--url", $0] } ?? []) + (isRemote ? ["--remote"] : []))) != nil else { continue }
            codexPoolHomes[isRemote] = url ?? ""
        }
    }

    private var remotePoolFile: URL { root.appendingPathComponent("runtime/pool-remote") }

    func checkRemotePool() async {
        guard let line = try? String(contentsOf: remotePoolFile, encoding: .utf8).split(separator: " ").map(String.init), line.count >= 2,
              let url = URL(string: line[0].trimmingCharacters(in: .whitespacesAndNewlines) + "/side-a/health") else {
            remotePool = nil
            return
        }
        let address = line[0]
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Bearer \(line[1].trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard status == 200 else {
                remotePool = (address, false, status == 401 ? 0 : remotePool?.codexAccounts ?? 0, status == 401 ? "It refused this Mac's key; run the join command it shows again." : "It answered \(status).")
                return
            }
            let claude = json["claude"] as? Int ?? 0, codex = json["codex"] as? Int ?? 0
            remotePool = (address, true, codex, "Reachable: \(claude) Claude and \(codex) Codex account\(claude + codex == 1 ? "" : "s") ready.")
        } catch {
            remotePool = (address, false, remotePool?.url == address ? remotePool?.codexAccounts ?? 0 : 0, "Unreachable, so commands here use this Mac's own logins: \(error.localizedDescription)")
        }
    }
}

/// Admits a peer only when tailscaled says it is signed in as this Mac's own Tailscale user: a shared
/// node or another person on the tailnet would otherwise use this Mac's subscriptions.
actor PoolPeers {
    private let login: String
    private var seen: [String: (admitted: Bool, at: Date)] = [:]
    private var asking: [String: Task<Bool, Never>] = [:]
    private let whois: @Sendable (String) async -> String?

    /// A device removed from the account is out within this long. Each connection asks, and each answer is a process.
    static let remembered: TimeInterval = 60

    init(login: String, whois: @escaping @Sendable (String) async -> String? = { await TailscaleCLI.shared.whois($0) }) {
        self.login = login
        self.whois = whois
    }

    func admits(_ address: String) async -> Bool {
        if let known = seen[address], Date().timeIntervalSince(known.at) < Self.remembered { return known.admitted }
        if let task = asking[address] { return await task.value }
        let whois = whois, login = login
        let task = Task { Pool.admits(peer: await whois(address), login: login) }
        asking[address] = task
        let admitted = await task.value
        asking[address] = nil
        if seen.count > 256 { seen = [:] }
        seen[address] = (admitted, Date())
        return admitted
    }
}
