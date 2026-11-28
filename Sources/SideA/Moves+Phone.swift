import Foundation
import SideACore
import SideAProtocol

/// Moves as the phone and the Mac's own sheet see them: what one would do, starting one without waiting for it,
/// and the list of sessions that are on their way or away.
extension Moves {
    static let failuresShownFor = 600.0

    /// What moving `session` to `peer` would do. Both computers are asked; nothing is stopped or kept.
    func preview(_ session: LiveSession, to peer: any MovePeer, os: HostOS? = nil, when: MoveRequest.When = .idle) async throws -> MovePreview {
        let plan = try await prepare(session, to: peer, when: when)
        await withdraw(plan, from: peer)
        return Self.preview(plan, peer: RemoteComputer(id: peer.id, name: peer.name, os: os))
    }

    static func preview(_ plan: Plan, peer: RemoteComputer) -> MovePreview {
        var login: MovePreview.Login?
        switch plan.answer.account {
        case .some(.here): login = .there
        case .some: login = plan.hands ? .sent : .other
        case nil: login = nil
        }
        return MovePreview(computer: peer, landing: plan.answer.landing, permissionMode: plan.answer.permissionMode,
                           account: login == nil ? nil : plan.offer.account?.name, login: login)
    }

    /// Agrees the move with `peer`, then carries it out without the caller waiting. Throws when it cannot start;
    /// what happens after is in `records()`.
    func start(_ session: LiveSession, to peer: any MovePeer) async throws -> MoveRecord {
        let plan = try await prepare(session, to: peer)
        let id = plan.offer.id
        running[id] = Task { [weak self] in
            _ = try? await self?.run(plan, to: peer)
            self?.running[id] = nil
            await self?.finished()
        }
        return MoveRecord(id: id, conversationID: plan.conversation, agent: plan.session.provider, title: plan.offer.title, project: plan.offer.project,
                          state: .moving, computer: peer.id, computerName: peer.name, at: now())
    }

    /// Sessions this computer is sending, has sent and not got back, or lost track of, and moves that just failed.
    func records() -> [MoveRecord] {
        let open: [MoveRecord] = journal.all.filter { $0.role == .source }.compactMap { entry in
            let state: MoveRecord.State
            switch entry.step {
            case .prepared, .held, .sent, .committing: state = .moving
            case .unknown: state = .unknown
            case .away: state = .away
            default: return nil
            }
            return Self.record(entry, state)
        }
        let failed = failures.filter { now() - $0.value.at < Self.failuresShownFor }.compactMap { id, failure in
            failure.entry.map { Self.record($0, .failed, message: failure.message, at: failure.at) }
                ?? MoveRecord(id: id, conversationID: "", agent: .claude, state: .failed, computer: "", computerName: "", at: failure.at, message: failure.message)
        }
        return (open + failed + waitingRecords()).sorted { $0.at > $1.at }
    }

    func record(_ id: String) -> MoveRecord? { records().first { $0.id == id } }

    private static func record(_ entry: MoveJournal.Entry, _ state: MoveRecord.State, message: String? = nil, at: Double? = nil) -> MoveRecord {
        MoveRecord(id: entry.id, conversationID: entry.session, agent: AgentProvider(rawValue: entry.agent) ?? .claude, title: entry.title, project: entry.project,
                   state: state, computer: entry.peer, computerName: entry.peerName, at: at ?? entry.updatedAt, session: entry.remote, message: message)
    }

    /// Asks the other computer again about a move whose outcome is unknown.
    func check(_ id: String) async -> MoveRecord? {
        await settle()
        return record(id)
    }

    /// For a move whose outcome is unknown and whose other computer cannot be asked any more (unlinked, wiped):
    /// the person decides it did not start there. The login kept aside goes back and the session starts here.
    func runHere(_ id: String) async {
        guard let entry = journal[id], entry.role == .source, entry.step == .unknown || entry.step == .committing, !inFlight.contains(id) else { return }
        if let peer = peer(entry.peer) { _ = try? await peer.abort(id) }
        guard journal[id]?.step == .unknown || journal[id]?.step == .committing else { return }
        await bringHome(entry)
    }

    /// Sends every hosted, idle session to `peer`, one at a time. Returns what did not go, with the reason.
    func sendAll(_ sessions: [LiveSession], to peer: any MovePeer) async -> [(session: LiveSession, reason: String)] {
        var stayed: [(LiveSession, String)] = []
        for session in sessions where session.hosted != nil {
            do { try await send(session, to: peer) } catch { stayed.append((session, error.localizedDescription)) }
        }
        return stayed
    }
}
