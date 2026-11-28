import Foundation
import SideACore
import SideAProtocol

/// The accounts side of a move (docs/moving-sessions-prd.md, 4.9). A login lives on one computer at a time: it is
/// taken out of use here before it is sent, and deleted here only when the other computer says it holds it.
@MainActor
protocol MoveLogins {
    /// The account a session runs on, when it runs on one of its own.
    func account(of session: LiveSession) -> (id: String, wire: MoveAccount)?
    /// An account here as the other computer is told of it: for a session with no process to read it from.
    func account(_ id: String) -> MoveAccount?
    /// The account here that is signed in as `email`.
    func signedIn(_ agent: AgentProvider, email: String) -> String?
    func hasAny(_ agent: AgentProvider) -> Bool
    /// Why this account's login must stay here when `session` leaves, or nil when it can go.
    func staying(_ account: String, besides session: LiveSession) async -> String?
    /// Takes the login out of use here and returns it for sending.
    func hold(_ account: String) async throws -> MoveLogin
    /// The other computer holds it: this computer's copy is deleted.
    func release(_ account: String, to peer: String) async
    /// It did not leave: back into use here.
    func restore(_ account: String) async
    /// Stores a login that arrived, under the account with its email or a new one.
    func receive(_ login: MoveLogin, agent: AgentProvider) async throws -> (id: String, added: Bool)
    /// Deletes a login that arrived with a move that then did not start.
    func remove(_ account: String, added: Bool) async
    /// How a session is started on that account.
    func seat(_ account: String) -> Moves.Seat
}

/// A computer whose accounts play no part: every session runs on whatever login the CLI finds.
struct NoLogins: MoveLogins {
    func account(of session: LiveSession) -> (id: String, wire: MoveAccount)? { nil }
    func account(_ id: String) -> MoveAccount? { nil }
    func signedIn(_ agent: AgentProvider, email: String) -> String? { nil }
    func hasAny(_ agent: AgentProvider) -> Bool { true }
    func staying(_ account: String, besides session: LiveSession) async -> String? { "Logins don't move from this computer." }
    func hold(_ account: String) async throws -> MoveLogin { throw MoveFailure.refused("Logins don't move from this computer.") }
    func release(_ account: String, to peer: String) async {}
    func restore(_ account: String) async {}
    func receive(_ login: MoveLogin, agent: AgentProvider) async throws -> (id: String, added: Bool) {
        throw MoveFailure.refused("This computer can't take a login.")
    }
    func remove(_ account: String, added: Bool) async {}
    func seat(_ account: String) -> Moves.Seat { Moves.Seat() }
}

/// The app's accounts: the library in `AccountStore`, and the stored logins through the bridge (`bridge/move_login.py`).
@MainActor
final class AppLogins: MoveLogins {
    private weak var store: AccountStore?
    private let ask: @MainActor ([String: Any]) async throws -> [String: Any]
    /// Accounts whose login went to another computer, and that computer's name.
    private(set) var lent: [String: String] = [:]
    private let lentURL: URL

    init(store: AccountStore, folder: URL, ask: @escaping @MainActor ([String: Any]) async throws -> [String: Any]) {
        self.store = store; self.ask = ask
        lentURL = folder.appendingPathComponent("lent.json")
        if let data = FileManager.default.contents(atPath: lentURL.path), let saved = try? JSONDecoder().decode([String: String].self, from: data) { lent = saved }
    }

    private func find(_ id: String) -> Account? { store?.config.accounts.first { $0.id == id } }

    private func setReady(_ id: String, _ ready: Bool) {
        guard let store, let index = store.config.accounts.firstIndex(where: { $0.id == id }) else { return }
        store.config.accounts[index].ready = ready
        store.persist()
    }

    private func setLent(_ id: String, _ peer: String?) {
        lent[id] = peer
        do { try PrivateFile.write(lent, to: lentURL) } catch { RemoteLog.shared("couldn't save which logins are away: \(error.localizedDescription)") }
    }

    func account(of session: LiveSession) -> (id: String, wire: MoveAccount)? {
        guard let store, let id = store.sessions.accountID(of: session, agent: session.provider), let wire = account(id) else { return nil }
        return (id, wire)
    }

    func account(_ id: String) -> MoveAccount? {
        guard let account = find(id), !account.email.isEmpty else { return nil }
        return MoveAccount(email: account.email, name: account.name)
    }

    func signedIn(_ agent: AgentProvider, email: String) -> String? {
        store?.config.accounts.first { $0.provider == agent && $0.ready && $0.email.caseInsensitiveCompare(email) == .orderedSame }?.id
    }

    func hasAny(_ agent: AgentProvider) -> Bool { store?.config.accounts.contains { $0.provider == agent && $0.ready } ?? false }

    func staying(_ account: String, besides session: LiveSession) async -> String? {
        guard let store, let found = find(account) else { return "That account isn't on this computer." }
        let others = store.sessions.live.filter { $0.pid != session.pid && $0.provider == found.provider && store.sessions.accountID(of: $0, agent: $0.provider) == account }.count
        // New terminals here read the active account's login, so taking it would sign them out.
        if store.isActive(found) { return "\(found.name) is the account new sessions here use" }
        if others > 0 { return others == 1 ? "another session here is using \(found.name)" : "\(others) other sessions here are using \(found.name)" }
        guard let answer = try? await ask(["action": "login-can", "account": account]) else { return "\(found.name)'s login couldn't be read" }
        return answer["can"] as? Bool == true ? nil : (answer["why"] as? String ?? "\(found.name)'s login stays here")
    }

    func hold(_ account: String) async throws -> MoveLogin {
        guard let found = find(account) else { throw MoveFailure.refused("That account isn't on this computer.") }
        let answer = try await ask(["action": "login-hold", "account": account])
        guard let login = answer["login"], let text = String(data: try JSONSerialization.data(withJSONObject: login), encoding: .utf8) else {
            throw MoveFailure.refused("\(found.name)'s login couldn't be read.")
        }
        setReady(account, false)
        return MoveLogin(email: found.email, name: found.name, login: text)
    }

    func release(_ account: String, to peer: String) async {
        _ = try? await ask(["action": "login-release", "account": account])
        setLent(account, peer)
    }

    func restore(_ account: String) async {
        guard (try? await ask(["action": "login-restore", "account": account]))?["restored"] as? Bool == true else { return }
        setReady(account, true)
        setLent(account, nil)
    }

    func receive(_ login: MoveLogin, agent: AgentProvider) async throws -> (id: String, added: Bool) {
        guard let store, let blob = try? JSONSerialization.jsonObject(with: Data(login.login.utf8)) else { throw MoveFailure.refused("The login that arrived can't be read.") }
        let known = store.config.accounts.first { $0.provider == agent && $0.email.caseInsensitiveCompare(login.email) == .orderedSame }
        guard let id = known?.id ?? store.addAccount(name: login.name, email: login.email, provider: agent) else { throw MoveFailure.refused("The account couldn't be added.") }
        // The bridge writes the account's pin only for a ready account, so it is marked before the login is stored.
        let wasReady = known?.ready ?? false
        setReady(id, true)
        do {
            _ = try await ask(["action": "login-receive", "account": id, "login": blob])
        } catch {
            // Nothing was stored. An account that was here before stays as it was; nothing of its own is deleted.
            if known == nil { await remove(id, added: true) } else { setReady(id, wasReady) }
            throw error
        }
        setLent(id, nil)
        return (id, known == nil)
    }

    func remove(_ account: String, added: Bool) async {
        _ = try? await ask(["action": "login-remove", "account": account])
        guard let store else { return }
        guard added else { return setReady(account, false) }
        store.config.accounts.removeAll { $0.id == account }
        if store.config.selectedID == account { store.config.selectedID = store.config.accounts.first?.id }
        store.persist()
    }

    func seat(_ account: String) -> Moves.Seat {
        guard let found = find(account) else { return Moves.Seat() }
        return found.provider == .codex ? Moves.Seat(codexAccount: account) : Moves.Seat(pin: AccountStore.pinName(found.name))
    }
}

extension Moves {
    /// "On Mac mini" for an account whose login went there with a session, for the places that would say it is signed out.
    func away(_ account: String) -> String? {
        (logins as? AppLogins)?.lent[account].map { "On \($0)" }
    }
}
