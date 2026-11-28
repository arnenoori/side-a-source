import Foundation
import SideAProtocol

/// `--demo --demo-macs 2`: the two demo Macs are linked, so a session on either can move to the other, which then lists it
/// while the one it left shows it as away. A working one goes after this turn or now (`moves.when`).
final class DemoMoves {
    nonisolated deinit {}

    private weak var root: AppRoot?
    private let macID: String
    /// How long the hand-over takes, so the sheet and the row show it under way.
    var delay: Duration = .seconds(1.5)
    /// The demo's own clock for a working session's turn: it ends this long after a move starts waiting for it.
    var turnEnds: Duration = .seconds(8)
    /// Each waiting move's turn end, by move id, so Cancel stops it.
    var turns: [String: Task<Void, Never>] = [:]

    private init(root: AppRoot, macID: String) { self.root = root; self.macID = macID }

    static func link(_ root: AppRoot) {
        guard root.macs.count > 1 else { return }
        for mac in root.macs {
            mac.tools.moves.demo = DemoMoves(root: root, macID: mac.macID)
            mac.sessions.replace(mac.sessions.sessions.map(movable), finished: [:])
        }
    }

    /// What the host would offer: a conversation it hosts that isn't waiting on you.
    static func movable(_ session: RemoteSession) -> RemoteSession {
        guard session.conversationID != nil, session.cwd != nil, session.openRequests.isEmpty,
              [.idle, .finished, .working].contains(session.status) else { return session }
        var session = session
        session.abilities.insert(.move)
        return session
    }

    var home: AppModel? { root?.model(for: macID) }

    var computers: [RemoteComputer] {
        (root?.macs ?? []).filter { $0.macID != macID }.map { RemoteComputer(id: $0.macID, name: $0.mac.name, os: $0.mac.kind) }
    }

    func preview(_ id: SessionKey, to computer: String) throws -> MovePreview {
        guard let home, let there = root?.model(for: computer), let session = home.sessions.session(id) else { throw ToolError.gone }
        let signedIn = session.accountName.map { name in there.accounts.accounts.contains { $0.name == name } } ?? true
        return MovePreview(computer: RemoteComputer(id: there.macID, name: there.mac.name, os: there.mac.kind),
                           landing: session.cwd.map { "\($0)/.sidea-worktrees/sa-\(session.project)-3f2a" },
                           permissionMode: home.tools.mode(of: session)?.raises == true ? .default : nil,
                           account: session.accountName, login: signedIn ? .there : .sent)
    }

    func move(_ id: SessionKey, to computer: String) throws -> MoveRecord {
        let (record, session) = try record(id, to: computer, state: .moving)
        go(record, session)
        return record
    }

    /// The record a move of `id` starts as, with the session as it is now.
    func record(_ id: SessionKey, to computer: String, state: MoveRecord.State) throws -> (MoveRecord, RemoteSession) {
        guard let home, let there = root?.model(for: computer), let session = home.sessions.session(id),
              let conversation = session.conversationID else { throw ToolError.gone }
        let record = MoveRecord(id: "mv-demo-\(UUID().uuidString.prefix(8).lowercased())", conversationID: conversation, agent: session.agent,
                                title: home.tools.title(for: session), project: session.project, state: state, computer: there.macID,
                                computerName: there.mac.name, at: Date.now.timeIntervalSince1970)
        return (record, session)
    }

    /// The hand-over: `delay` later the session runs on the other computer.
    func go(_ record: MoveRecord, _ session: RemoteSession) {
        Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            self?.land(record, session)
        }
    }

    private func land(_ record: MoveRecord, _ session: RemoteSession) {
        guard let home, let there = root?.model(for: record.computer) else { return }
        let name = "sa-\(session.project)-\(record.id.suffix(4))"
        var arrived = session
        arrived.hosted = name
        arrived.status = .idle
        arrived.statusAt = Date.now.timeIntervalSince1970
        home.sessions.replace(home.sessions.sessions.filter { $0.id != session.id }, finished: [:])
        there.sessions.replace(there.sessions.sessions.filter { $0.id != session.id } + [arrived], finished: [:])
        if let messages = home.transcripts.messages[session.id] { there.transcripts.set(messages, hasEarlier: false, for: arrived.id) }
        there.tools.moves.forget(conversation: record.conversationID)
        home.tools.moves.update(record.with(state: .away, session: name))
    }
}
