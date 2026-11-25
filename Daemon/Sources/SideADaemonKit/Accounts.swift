import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SideACore
import SideAProtocol

/// How a session is pointed at one account's login. `CLAUDE_CONFIG_DIR` is the documented way: the folder holds the login
/// (`.credentials.json` on Linux) and also that account's settings, history and plugins. `CLAUDE_SECURESTORAGE_CONFIG_DIR`
/// is what the Mac app uses to move only the login, but Anthropic doesn't document it, and whether it moves the file on
/// Linux is the open question in docs/ports/phase-0.md; it is behind `--account-selector securestorage` until that is known.
public enum AccountSelector: String, Sendable {
    case configDir
    case secureStorage

    public var variable: String { self == .configDir ? "CLAUDE_CONFIG_DIR" : "CLAUDE_SECURESTORAGE_CONFIG_DIR" }

    public init?(option: String) {
        switch option.lowercased() {
        case "configdir", "config-dir", "claude_config_dir": self = .configDir
        case "securestorage", "secure-storage", "claude_securestorage_config_dir": self = .secureStorage
        default: return nil
        }
    }
}

/// One Claude account on this computer: a name and the folder Claude Code keeps its login in.
public struct StoredAccount: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var configDir: String
    public var provider: AgentProvider = .claude
}

/// `accounts.json` in the state folder, written 0600. The folders it names hold the logins; this holds only where they are.
public struct AccountBook: Sendable {
    public let file: URL
    public let home: URL

    public init(state: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        file = state.appendingPathComponent("accounts.json"); self.home = home
    }

    /// Where new accounts' folders go.
    public var folders: URL {
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".local/share")
        return base.appendingPathComponent("side-a/accounts")
    }

    public func load() -> [StoredAccount] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([StoredAccount].self, from: data)) ?? []
    }

    private func save(_ accounts: [StoredAccount]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts).write(to: file, options: .atomic)
        chmod(file.path, 0o600)
        // The bridge reads sessions and transcripts from each of these folders, not only from ~/.claude.
        try JSONEncoder().encode(accounts.map(\.configDir)).write(to: foldersFile, options: .atomic)
    }

    /// The JSON list of every account's folder, for the bridge (`SIDEAD_CLAUDE_DIRS_FILE`).
    public var foldersFile: URL { file.deletingLastPathComponent().appendingPathComponent("claude-dirs.json") }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case exists(String), unknown(String), notAFolder(String)
        public var description: String {
            switch self {
            case .exists(let name): "There is already an account called \(name)."
            case .unknown(let name): "There is no account called \(name)."
            case .notAFolder(let path): "\(path) isn't a folder."
            }
        }
    }

    static func slug(_ name: String) -> String {
        let letters = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        let squeezed = letters.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return squeezed.isEmpty ? "account" : String(squeezed.prefix(32))
    }

    /// A new account with an empty folder of its own, to sign in to with `CLAUDE_CONFIG_DIR=<folder> claude auth login`.
    @discardableResult
    public func add(_ name: String) throws -> StoredAccount {
        var accounts = load()
        let id = Self.slug(name)
        guard !accounts.contains(where: { $0.id == id || $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw Failure.exists(name) }
        let folder = folders.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let account = StoredAccount(id: id, name: name, configDir: folder.path)
        accounts.append(account)
        try save(accounts)
        return account
    }

    /// An account for a login that is already on this computer: `~/.claude` unless `directory` says another.
    @discardableResult
    public func adopt(_ name: String, directory: String? = nil) throws -> StoredAccount {
        var accounts = load()
        let id = Self.slug(name)
        guard !accounts.contains(where: { $0.id == id || $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw Failure.exists(name) }
        let path = directory ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home.appendingPathComponent(".claude").path
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { throw Failure.notAFolder(path) }
        let account = StoredAccount(id: id, name: name, configDir: path)
        accounts.append(account)
        try save(accounts)
        return account
    }

    /// Takes the account out of the list. Its folder, and the login in it, stay where they are.
    public func remove(_ idOrName: String) throws {
        var accounts = load()
        guard let at = accounts.firstIndex(where: { $0.id == idOrName || $0.name.caseInsensitiveCompare(idOrName) == .orderedSame }) else { throw Failure.unknown(idOrName) }
        accounts.remove(at: at)
        try save(accounts)
    }
}

/// What one login file says.
struct LoginFile: Sendable, Equatable {
    var token: String?
    var expiresAt: Double?
    var subscription: String?
    var tier: String?
    var email: String?

    /// `<folder>/.credentials.json`, and who it belongs to from Claude Code's own `.claude.json` (which sits beside a custom
    /// folder, and in the home folder for the default one).
    static func read(_ account: StoredAccount, home: URL) -> LoginFile {
        var login = LoginFile()
        let folder = URL(fileURLWithPath: account.configDir)
        if let data = try? Data(contentsOf: folder.appendingPathComponent(".credentials.json")),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let oauth = object["claudeAiOauth"] as? [String: Any] {
            login.token = oauth["accessToken"] as? String
            login.expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue
            login.subscription = oauth["subscriptionType"] as? String
            login.tier = oauth["rateLimitTier"] as? String
        }
        let isDefault = folder.standardizedFileURL.path == home.appendingPathComponent(".claude").standardizedFileURL.path
        for candidate in [folder.appendingPathComponent(".claude.json")] + (isDefault ? [home.appendingPathComponent(".claude.json")] : []) {
            if let data = try? Data(contentsOf: candidate), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let email = (object["oauthAccount"] as? [String: Any])?["emailAddress"] as? String {
                login.email = email.lowercased()
                break
            }
        }
        return login
    }

    func expired(at now: Double, margin: Double = 60) -> Bool { (expiresAt ?? 0) / 1000 < now + margin }
}

/// Reads an account's limits the way the Mac's bridge does (`claude_usage`): one GET with the account's own token. It never
/// refreshes a login: a refresh token spends itself, and on the Mac that is done under Claude Code's own lock. An expired
/// token is left for the next session that uses the account to renew; until then the reading is marked stale.
public struct UsageReader: Sendable {
    public var url: URL
    public var timeout: TimeInterval = 20
    /// How a request goes out; tests answer it themselves.
    public var fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    public init(url: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!) { self.url = url }

    public enum Failure: Error, Equatable, Sendable { case rejected, limited, unavailable(Int), offline }

    func read(token: String, tier: String?, subscription: String?) async throws -> AccountUsage {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli (side-a)", forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do { (data, response) = try await fetch(request) } catch { throw Failure.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 401 ? Failure.rejected : status == 429 ? Failure.limited : Failure.unavailable(status) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.unavailable(status) }
        return Self.parse(object, tier: tier, subscription: subscription)
    }

    static let labels: [(String, String)] = [("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly Opus"), ("seven_day_sonnet", "Weekly Sonnet")]

    static func parse(_ data: [String: Any], tier: String?, subscription: String?) -> AccountUsage {
        func percent(_ value: Any?) -> Double {
            let number = (value as? NSNumber)?.doubleValue ?? 0
            return number.isFinite ? min(max(number, 0), 100) : 0
        }
        func epoch(_ value: Any?) -> Double? {
            if let number = value as? NSNumber { let seconds = number.doubleValue; return seconds > 1e11 ? seconds / 1000 : seconds }
            guard let text = value as? String, !text.isEmpty else { return nil }
            let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return (fractional.date(from: text) ?? plain.date(from: text))?.timeIntervalSince1970
        }
        var windows: [UsageWindow] = []
        for (key, label) in labels {
            guard let entry = data[key] as? [String: Any] else { continue }
            windows.append(UsageWindow(id: key, label: label, percent: percent(entry["utilization"]), resetsAt: epoch(entry["resets_at"])))
        }
        // Per-model weekly caps arrive as scoped entries in `limits`.
        for limit in (data["limits"] as? [[String: Any]]) ?? [] {
            let model = (((limit["scope"] as? [String: Any])?["model"]) as? [String: Any])?["display_name"] as? String
            if limit["kind"] as? String == "weekly_scoped", let model {
                windows.append(UsageWindow(id: "model:" + model.lowercased(), label: "Weekly " + model, percent: percent(limit["percent"]), resetsAt: epoch(limit["resets_at"])))
            }
        }
        let plan = "\(tier ?? "") \(subscription ?? "")".lowercased()
        let capacity = plan.contains("20x") || plan.contains("ultra") ? 20.0 : plan.contains("5x") || plan.contains("max") ? 5.0 : 1.0
        return AccountUsage(windows: windows, stale: false, extra: extra(data), capacity: capacity)
    }

    static func extra(_ data: [String: Any]) -> ExtraUsage? {
        let spend = data["spend"] as? [String: Any] ?? [:]
        let legacy = data["extra_usage"] as? [String: Any] ?? [:]
        func money(_ value: Any?) -> Double? {
            guard let value = value as? [String: Any] else { return nil }
            return ((value["amount_minor"] as? NSNumber)?.doubleValue ?? 0) / pow(10, (value["exponent"] as? NSNumber)?.doubleValue ?? 0)
        }
        let enabled = (spend["enabled"] as? Bool) ?? (legacy["is_enabled"] as? Bool) ?? false
        let used = money(spend["used"]) ?? ((legacy["used_credits"] as? NSNumber)?.doubleValue ?? 0) / 100
        let limit = money(spend["limit"]) ?? (legacy["monthly_limit"] as? NSNumber).map { $0.doubleValue / 100 }
        let currency = ((spend["used"] as? [String: Any])?["currency"] as? String) ?? (legacy["currency"] as? String) ?? "USD"
        return ExtraUsage(enabled: enabled, used: used, limit: limit, currency: currency)
    }
}

/// The accounts a phone sees: each folder's login and limits.
public actor AccountsService {
    public let book: AccountBook
    public let selector: AccountSelector
    private let reader: UsageReader
    private let home: URL
    private let every: TimeInterval
    private var readings: [String: (usage: AccountUsage, at: Double)] = [:]
    private var lastTry: [String: Double] = [:]
    private var published: [String: RemoteAccount] = [:]

    public init(book: AccountBook, selector: AccountSelector = .configDir, reader: UsageReader = UsageReader(), every: TimeInterval = 60) {
        self.book = book; self.selector = selector; self.reader = reader; self.home = book.home; self.every = every
    }

    /// The variables a session for `id` starts with.
    public func environment(for id: String) -> [String: String]? {
        book.load().first { $0.id == id }.map { [selector.variable: $0.configDir] }
    }

    /// Reads every account's login and, when the last reading is old, its limits.
    public func list(refresh: Bool = false, now: Double = Date().timeIntervalSince1970) async -> [RemoteAccount] {
        var out: [RemoteAccount] = []
        for account in book.load() {
            let login = LoginFile.read(account, home: home)
            var issue: AccountIssue?
            let signedIn = login.token != nil
            let valid = signedIn && !login.expired(at: now)
            if !signedIn { issue = AccountIssue(kind: .signedOut) }
            else if !valid { issue = AccountIssue(kind: .signIn) }
            if valid, refresh || (now - (lastTry[account.id] ?? 0)) >= every, let token = login.token {
                lastTry[account.id] = now
                do {
                    readings[account.id] = (try await reader.read(token: token, tier: login.tier, subscription: login.subscription), now)
                } catch UsageReader.Failure.rejected {
                    issue = AccountIssue(kind: .signIn)
                } catch {
                    issue = AccountIssue(kind: .offline)
                }
            }
            var usage = readings[account.id]?.usage
            if usage != nil, !valid || issue != nil { usage?.stale = true }
            let full = 100.0
            let limited = usage.map { Planner.isLimited($0, now: now, full: full) } ?? false
            out.append(RemoteAccount(id: account.id, name: account.name, email: login.email ?? "", provider: account.provider, ready: valid && issue == nil,
                                     active: false, usage: usage, readAt: readings[account.id]?.at, sessions: 0, priority: nil, allowAuto: nil,
                                     limited: limited, fableOut: nil, backAt: usage.flatMap { Planner.backAt($0, now: now, full: full) }, issue: issue))
        }
        return out
    }

    /// The accounts that changed since the last call, and the ids that are gone.
    func changes(now: Double = Date().timeIntervalSince1970) async -> (changed: [RemoteAccount], gone: [String]) {
        let now = await list(now: now)
        var changed: [RemoteAccount] = []
        for account in now where published[account.id] != account { changed.append(account) }
        let gone = published.keys.filter { id in !now.contains { $0.id == id } }
        published = Dictionary(uniqueKeysWithValues: now.map { ($0.id, $0) })
        return (changed, gone)
    }
}

/// The accounts' part of the daemon: `GET /v1/accounts`, the snapshot's accounts and `usage.update` events.
public final class AccountServices: DaemonServices {
    let accounts: AccountsService
    private let task = TaskBox()

    public init(accounts: AccountsService) { self.accounts = accounts }

    public var capabilities: Set<Capability> { [] }

    public func snapshot(into parts: StateParts) async -> StateParts {
        var parts = parts
        parts.accounts = await accounts.list()
        return parts
    }

    public var routes: [DaemonRoute] {
        let accounts = accounts
        return [DaemonRoute("GET", "v1/accounts") { context in
            Wire.json(200, AccountList(accounts: await accounts.list(refresh: true), seq: await context.daemon.hub.seq))
        }]
    }

    public func start(_ daemon: SideADaemon) async {
        _ = await accounts.changes()
        let accounts = accounts
        task.set(Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                let (changed, gone) = await accounts.changes()
                if !changed.isEmpty { await daemon.hub.record(.usageUpdate(changed)) }
                for id in gone { await daemon.hub.record(.accountRemove(id: id)) }
            }
        })
    }

    public func stop() async { task.cancel() }

    final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        func set(_ new: Task<Void, Never>) { lock.lock(); task = new; lock.unlock() }
        func cancel() { lock.lock(); task?.cancel(); task = nil; lock.unlock() }
    }
}

/// Several services answering as one.
public struct CombinedServices: DaemonServices {
    let parts: [any DaemonServices]
    public init(_ parts: [any DaemonServices]) { self.parts = parts }
    public var capabilities: Set<Capability> { parts.reduce(into: []) { $0.formUnion($1.capabilities) } }
    public var routes: [DaemonRoute] { parts.flatMap(\.routes) }
    public func snapshot(into parts: StateParts) async -> StateParts {
        var parts = parts
        for service in self.parts { parts = await service.snapshot(into: parts) }
        return parts
    }
    public func start(_ daemon: SideADaemon) async { for service in parts { await service.start(daemon) } }
    public func stop() async { for service in parts { await service.stop() } }
}
