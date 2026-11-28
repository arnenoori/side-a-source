import Foundation
import SideACore
import SideAProtocol

/// The accounts side of a move on Linux (docs/moving-sessions-prd.md 4.9; the Mac's `AppLogins` and
/// `bridge/move_login.py`). A Claude account here is a folder run with `CLAUDE_CONFIG_DIR`, its login the folder's
/// `.credentials.json`. A login lives on one computer at a time: it is moved aside before it is sent, deleted only on
/// the other computer's word that it holds it, and put back otherwise. The login in this computer's own folder (what
/// its terminals use) never leaves. Codex has no account model here: `~/.codex/auth.json` is this computer's own login,
/// so it never leaves, and one arrives only when there is none.
struct DaemonLogins: Sendable {
    let book: AccountBook
    let selector: AccountSelector
    let home: URL
    let environment: [String: String]
    /// Where a login waits between leaving its folder and the other computer's word.
    let held: URL

    static let codex = "codex"
    /// The id of this computer's own Claude folder when no account names it.
    static let own = ""

    var ownFolder: URL {
        environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
    }

    var codexHome: URL {
        environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
    }

    var codexAuth: URL { codexHome.appendingPathComponent("auth.json") }

    private static func same(_ a: String, _ b: URL) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// Every Claude account: the book's, and this computer's own folder when no account in the book is it.
    func claudeAccounts() -> [StoredAccount] {
        let listed = book.load().filter { $0.provider == .claude }
        guard !listed.contains(where: { Self.same($0.configDir, ownFolder) }) else { return listed }
        return [StoredAccount(id: Self.own, name: "this computer's own login", configDir: ownFolder.path)] + listed
    }

    func account(_ id: String) -> StoredAccount? { claudeAccounts().first { $0.id == id } }

    func isOwn(_ account: StoredAccount) -> Bool { account.id == Self.own || Self.same(account.configDir, ownFolder) }

    func login(_ account: StoredAccount) -> LoginFile { LoginFile.read(account, home: home) }

    /// The folder the CLI reads an account's conversations from: its own with `CLAUDE_CONFIG_DIR`, the shared one when
    /// only the login is moved (`--account-selector securestorage`).
    func projects(for id: String?) -> URL {
        guard selector == .configDir, let id, let account = account(id) else { return ownFolder.appendingPathComponent("projects") }
        return URL(fileURLWithPath: account.configDir).appendingPathComponent("projects")
    }

    /// Every Claude `projects` folder here, the one for `first` first.
    func allProjects(first: String?) -> [URL] {
        var out = [projects(for: first)]
        for account in claudeAccounts() {
            let folder = URL(fileURLWithPath: account.configDir).appendingPathComponent("projects")
            if !out.contains(where: { $0.standardizedFileURL.path == folder.standardizedFileURL.path }) { out.append(folder) }
        }
        return out
    }

    var codexStores: [URL] { [codexHome.appendingPathComponent("sessions")] }

    /// The variables a session on `account` starts with.
    func seat(_ account: String?) -> [String: String] {
        guard let account, account != Self.codex, let found = self.account(account), !isOwn(found) else { return [:] }
        return [selector.variable: found.configDir]
    }

    // MARK: What the other computer is told

    /// The account a session runs on, by its email: the account its pane was started on, else this computer's own.
    func account(of agent: AgentProvider, slot: String?) -> (id: String, wire: MoveAccount)? {
        if agent == .codex {
            guard let email = Self.codexEmail(at: codexAuth), !email.isEmpty else { return nil }
            return (Self.codex, MoveAccount(email: email, name: email))
        }
        let found = slot.flatMap { $0.isEmpty ? nil : account($0) } ?? account(Self.own) ?? claudeAccounts().first { isOwn($0) }
        guard let found, let email = login(found).email, !email.isEmpty else { return nil }
        return (found.id, MoveAccount(email: email, name: isOwn(found) ? email : found.name))
    }

    /// The account here that is signed in as `email`.
    func signedIn(_ agent: AgentProvider, email: String) -> String? {
        if agent == .codex {
            return Self.codexEmail(at: codexAuth)?.caseInsensitiveCompare(email) == .orderedSame ? Self.codex : nil
        }
        return claudeAccounts().first { account in
            let login = login(account)
            return login.token != nil && login.email?.caseInsensitiveCompare(email) == .orderedSame
        }?.id
    }

    func hasAny(_ agent: AgentProvider) -> Bool {
        agent == .codex ? FileManager.default.fileExists(atPath: codexAuth.path) : claudeAccounts().contains { login($0).token != nil }
    }

    /// The account a session runs on when no login of its own came: this computer's own when it is signed in, else the
    /// first account that is.
    func fallback(_ agent: AgentProvider) -> String? {
        if agent == .codex { return hasAny(.codex) ? Self.codex : nil }
        let signed = claudeAccounts().filter { login($0).token != nil }
        return (signed.first { isOwn($0) } ?? signed.first)?.id
    }

    // MARK: A login leaving

    /// Why this account's login must stay here when the session with `pid` leaves, or nil when it can go.
    func staying(_ id: String, agent: AgentProvider, besides pid: Int) -> String? {
        if agent == .codex { return "Codex's login here is this computer's own" }
        guard let account = account(id) else { return "that account isn't on this computer" }
        if isOwn(account) { return "\(account.name.isEmpty ? "it" : account.name) is this computer's own Claude Code login" }
        guard login(account).token != nil else { return "\(account.name) isn't signed in here" }
        let others = Self.registered(in: URL(fileURLWithPath: account.configDir)).filter { $0 != pid }.count
        if others > 0 { return others == 1 ? "another session here is using \(account.name)" : "\(others) other sessions here are using \(account.name)" }
        return nil
    }

    /// The running Claude Code processes that keep their registry in `folder` (`sessions/<pid>.json`).
    static func registered(in folder: URL) -> [Int] {
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("sessions").path)) ?? []
        return listing.compactMap { name in
            guard name.hasSuffix(".json"), let pid = Int(name.dropLast(5)), pid > 1 else { return nil }
            return Run.running(pid) ? pid : nil
        }
    }

    private func credentials(_ account: StoredAccount) -> URL { URL(fileURLWithPath: account.configDir).appendingPathComponent(".credentials.json") }
    private func heldFile(_ id: String) -> URL { held.appendingPathComponent("\(id).json") }

    /// Takes the login out of its folder and returns it for sending. Until `release` or `restore` it sits where no session
    /// and no renewal reads it.
    func hold(_ id: String, agent: AgentProvider) throws -> MoveLogin {
        guard agent == .claude, let account = account(id), !isOwn(account) else { throw MoveFailure.refused("That login stays on this computer.") }
        let source = credentials(account)
        guard let data = FileManager.default.contents(atPath: source.path), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["claudeAiOauth"] != nil, let text = String(data: data, encoding: .utf8) else {
            throw MoveFailure.refused("\(account.name)'s login couldn't be read.")
        }
        try PrivateFiles.write(data, to: heldFile(id))
        try FileManager.default.removeItem(at: source)
        return MoveLogin(email: login(account).email ?? account.email ?? "", name: account.name, login: text)
    }

    /// The other computer holds it: the copy kept aside here is deleted.
    func release(_ id: String) {
        try? FileManager.default.removeItem(at: heldFile(id))
    }

    /// It did not leave: back into its folder. True when there was one to put back.
    @discardableResult
    func restore(_ id: String) -> Bool {
        guard let account = account(id), let data = FileManager.default.contents(atPath: heldFile(id).path) else { return false }
        do {
            try PrivateFiles.write(data, to: credentials(account))
            try FileManager.default.removeItem(at: heldFile(id))
            return true
        } catch {
            DaemonLog.line("move: \(account.name)'s login couldn't be put back: \(error)")
            return false
        }
    }

    // MARK: A login arriving

    /// Stores a login that arrived, in the account with its email or in a new one. Never in this computer's own folder,
    /// whose login is what its terminals use.
    func receive(_ arrived: MoveLogin, agent: AgentProvider) throws -> (id: String, added: Bool) {
        guard let data = arrived.login.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MoveFailure.refused("The login that arrived can't be read.")
        }
        if agent == .codex {
            guard !FileManager.default.fileExists(atPath: codexAuth.path) else { throw MoveFailure.refused("This computer has a Codex login of its own.") }
            guard Self.codexEmail(object)?.caseInsensitiveCompare(arrived.email) == .orderedSame else {
                throw MoveFailure.refused("That login belongs to another account.")
            }
            try PrivateFiles.write(data, to: codexAuth)
            return (Self.codex, true)
        }
        guard object["claudeAiOauth"] != nil else { throw MoveFailure.refused("That isn't a Claude Code login.") }
        // Into an account of that email only when it holds no login file at all, so a failed start deletes nothing that
        // was here before.
        if let known = book.load().first(where: { $0.provider == .claude && !isOwn($0) && login($0).email?.caseInsensitiveCompare(arrived.email) == .orderedSame
            && !FileManager.default.fileExists(atPath: credentials($0).path) }) {
            try PrivateFiles.write(data, to: credentials(known))
            return (known.id, false)
        }
        let added = try book.add(movedIn: arrived.name, email: arrived.email.lowercased())
        do {
            try PrivateFiles.write(data, to: credentials(added))
        } catch {
            remove(added.id, agent: agent, added: true)
            throw error
        }
        return (added.id, true)
    }

    /// Deletes a login that arrived with a move that then did not start, so it exists only where it came from.
    func remove(_ id: String, agent: AgentProvider, added: Bool) {
        if agent == .codex || id == Self.codex {
            if added { try? FileManager.default.removeItem(at: codexAuth) }
            return
        }
        guard let account = account(id), !isOwn(account) else { return }
        try? FileManager.default.removeItem(at: credentials(account))
        guard added else { return }
        do { try book.remove(id) } catch { DaemonLog.line("move: the account \(account.name) couldn't be taken off the list: \(error)") }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: account.configDir))
    }

    // MARK: Codex's login

    /// The email claim of `auth.json`'s id token, as `bridge/codex_bridge.py` `login_email` reads it.
    static func codexEmail(at url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return codexEmail(object)
    }

    static func codexEmail(_ auth: [String: Any]) -> String? {
        guard let token = (auth["tokens"] as? [String: Any])?["id_token"] as? String else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1, let payload = Data(base64URL: String(parts[1])),
              let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return nil }
        return (claims["email"] as? String)?.lowercased()
    }
}

extension AccountBook {
    /// An account for a login that arrived with a moved session: a folder of its own, named for the account, with the
    /// email kept beside it until Claude Code records its own.
    func add(movedIn name: String, email: String) throws -> StoredAccount {
        var accounts = load()
        let base = name.isEmpty ? "Account" : String(name.prefix(60))
        var chosen = base, number = 2
        while accounts.contains(where: { $0.id == Self.slug(chosen) || $0.name.caseInsensitiveCompare(chosen) == .orderedSame })
                || FileManager.default.fileExists(atPath: folders.appendingPathComponent(Self.slug(chosen)).path) {
            chosen = "\(base) \(number)"
            number += 1
        }
        let id = Self.slug(chosen)
        let folder = folders.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let account = StoredAccount(id: id, name: chosen, configDir: folder.path, email: email)
        accounts.append(account)
        try save(accounts)
        return account
    }
}

/// Writing what nobody else may read: 0600, in a 0700 folder, replaced whole.
enum PrivateFiles {
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, url.path) != 0 {
            let reason = errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: reason) ?? .EIO)
        }
    }
}

/// One line to standard error: the daemon's log under systemd. Never a secret, a path inside a repository or a file name.
enum DaemonLog {
    static func line(_ text: String) {
        FileHandle.standardError.write(Data(("sidead: " + text + "\n").utf8))
    }
}
