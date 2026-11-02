import AppKit
import Foundation
import SideACore

enum PoolShareState: Equatable {
    case off, connecting
    case shared(command: String)
    case problem(String)
}

extension AccountStore: PoolDecisions {
    var poolFile: URL { root.appendingPathComponent("runtime/pool") }
    private var poolKeyFile: URL { root.appendingPathComponent("runtime/pool-key") }
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
            pool = nil
            poolPort = nil
            poolShareGeneration += 1
            poolShareState = .off
            try? FileManager.default.removeItem(at: poolFile)
            await syncCodexPoolHomes()
            return
        }
        guard pool == nil, !poolStarting else { return }
        poolStarting = true
        defer { poolStarting = false }
        do {
            let proxy = PoolProxy(key: try poolKey(), decisions: self)
            let port = try await proxy.start(port: poolPreferredPort)
            // Turned off while it started.
            guard config.pool == true else { proxy.stop(); return }
            // The file first: a pool with no file to find would serve nobody and block every retry.
            do {
                try writePrivate("http://127.0.0.1:\(port) \(proxy.key) \(ProcessInfo.processInfo.processIdentifier)\n", to: poolFile)
            } catch {
                proxy.stop()
                throw error
            }
            pool = proxy
            if poolQuitObserver == nil {
                // A quit leaves no file behind for shells to find: commands use logins again at once.
                let file = poolFile
                poolQuitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                    try? FileManager.default.removeItem(at: file)
                }
            }
            poolPort = port
            autopilotLog.write("Pool mode on, at 127.0.0.1:\(port).")
            await syncPoolShare()
            await syncCodexPoolHomes()
        } catch {
            self.error = "Pool mode couldn't start: \(error.localizedDescription)"
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
        let planned = provider == .claude ? planning(usage) : usage
        let members = poolMembers(provider).filter { account in
            !excluding.contains(account.id) && (poolBlocked[account.id] ?? 0) <= now && health[account.id]?.takesWork != false
        }.sorted { ($0.priority ?? .normal).rank < ($1.priority ?? .normal).rank }
        let usable = { (id: String) in
            members.contains { $0.id == id } && planned[id].map { Planner.hasHeadroom($0, now: now) } ?? true
        }
        let chosen = poolRouter.route(session: session, now: now, usable: usable) {
            Planner.best(members, usage: planned, health: health, active: activeIDs[provider], now: now)
                // Unread or stale accounts are still worth a try before refusing the request.
                ?? members.first { usable($0.id) }?.id
                // Codex serves a full account from its credits and says 429 if it has none, so that call is OpenAI's.
                ?? (provider == .codex ? members.first?.id : nil)
        }
        poolConversations = poolRouter.conversations
        return chosen
    }

    func poolToken(_ account: String, refused: Bool) async throws -> PoolCredential {
        let now = Date().timeIntervalSince1970
        // The bridge renews five minutes ahead, so a token kept until four minutes ahead is never one it would keep too.
        if !refused, let cached = poolTokens[account], cached.expires - 240 > now { return cached.credential }
        // A session's subagents ask at once; one bridge run answers them all.
        if let pending = poolTokenReads[account] { return try await pending.value }
        let codex = config.accounts.first { $0.id == account }?.provider == .codex
        let args = [codex ? "codex-pool-token" : "pool-token", account] + (refused ? poolTokens[account].map { ["--refused", $0.hash] } ?? [] : [])
        let read = Task { [unowned self] in
            struct Token: Decodable { let accessToken: String; let accountId: String?; let expiresAt: Double; let hash: String }
            let token = try JSONDecoder().decode(Token.self, from: try await bridgeOutput(args))
            let credential = PoolCredential(token: token.accessToken, accountID: token.accountId)
            poolTokens[account] = (credential, token.expiresAt / 1000, token.hash)
            return credential
        }
        poolTokenReads[account] = read
        defer { poolTokenReads[account] = nil }
        return try await read.value
    }

    func poolTokenFailed(_ account: String, _ error: any Error) {
        let message = error.localizedDescription
        let name = config.accounts.first { $0.id == account }?.name ?? account
        poolTokens[account] = nil
        if message.contains("Sign in") {
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
            poolTokens[account] = nil
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
        var health: [String: Int] = [:]
        for provider in AgentProvider.allCases {
            // A full Codex account can still answer from its credits.
            let ready = poolMembers(provider).filter { account in
                self.health[account.id]?.takesWork != false && (provider == .codex || usage[account.id].map { Planner.hasHeadroom($0, now: now) } ?? true)
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
            } catch where error.localizedDescription.contains("429") || error.localizedDescription.contains("idle") {
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
        // Many connections from one address share one question.
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
