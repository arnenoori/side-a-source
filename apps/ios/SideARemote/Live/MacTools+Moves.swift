import Foundation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

extension MacTools {
    /// How often, and for how long, a move under way is asked after: past a clone's worst case, and a list change asks again.
    static let movePoll: Duration = .seconds(2)
    static let movePolls = 90

    func computers() async throws -> [RemoteComputer] {
        if isDemo {
            guard let demo = moves.demo else { throw ToolError.demo }
            moves.set(computers: demo.computers)
            return demo.computers
        }
        let client = try await client()
        let list = try await client.reaching { try await client.computers() }.computers
        moves.set(computers: list)
        return list
    }

    /// 409 `move_refused` carries the sentence the sheet shows in place of Move. `when` is asked of both computers too.
    func movePreview(_ session: SessionKey, to computer: RemoteComputer, when: MoveRequest.When? = nil) async throws -> MovePreview {
        if isDemo {
            guard let demo = moves.demo else { throw ToolError.demo }
            return try demo.preview(session, to: computer.id)
        }
        let client = try await client()
        return try await client.reaching { try await client.movePreview(session, MoveRequest(computer: computer.id, when: when)) }
    }

    /// Face ID only: the host takes nothing else for a move, so the unlock key is never tried first. `key` is the sheet's,
    /// so Move tapped again after no answer is the same move. The signature covers `when`.
    func move(_ session: RemoteSession, to computer: RemoteComputer, when: MoveRequest.When? = nil, key: String) async throws -> MoveRecord {
        if isDemo {
            guard let demo = moves.demo else { throw ToolError.demo }
            let record = try demo.move(session.id, to: computer.id, when: when)
            moves.update(record)
            return record
        }
        let body = MoveRequest(computer: computer.id, when: when)
        let confirm = try await faceID(.action, subject: ConfirmMessage.subject(action: .moveSession, target: session.id, body: body),
                                       reason: "Move to \(computer.name)")
        let record = try await signed {
            let client = try await client()
            return try await client.reaching { try await client.move(session.id, body, confirm: confirm, idempotencyKey: key) }
        }
        moves.update(record)
        followMoves()
        return record
    }

    func checkMove(_ id: String) async throws -> MoveRecord {
        if isDemo {
            guard let record = moves.record(id) else { throw ToolError.gone }
            return record
        }
        let record = try await client().checkMove(id)
        moves.update(record)
        if moves.inFlight { followMoves() }
        return record
    }

    /// The host's moves, and the checkpoints it keeps for other computers, which are read on the same occasions.
    func loadMoves() async {
        await readMoves()
        if moves.inFlight { followMoves() }
        await loadStandby()
    }

    /// While a move is under way its record changes on the host and nothing says so, so it is read again until it settles.
    func followMoves() {
        guard isLive, moves.following == nil else { return }
        moves.following = Task { [weak self] in
            for _ in 0..<Self.movePolls {
                try? await Task.sleep(for: Self.movePoll)
                guard let self, !Task.isCancelled else { return }
                await self.readMoves()
                if !self.moves.inFlight { break }
            }
            self?.moves.following = nil
        }
    }

    private func readMoves() async {
        guard isLive, can(.moves), let client = try? await client() else { return }
        do { moves.set(try await client.moves().moves) } catch { RemoteLog.log(.sync, "moves not read: \(MacTools.message(error))") }
    }

    /// A session that left the list, or one that joined it, may be a move landing or ending; a link that just came back may
    /// have missed one.
    func noteMoves(_ state: RemoteState) {
        guard can(.moves) || can(.standby), state.epoch != nil else { return }
        noteWaiting(state)
        let sessions = Set(state.sessions.keys), live = state.connection.isLive
        let due = live && (!moves.seenLive || sessions != moves.seenSessions)
        moves.seenSessions = sessions
        moves.seenLive = live
        if due { Task { await loadMoves() } }
    }
}

extension AppModel {
    /// The moved rows this host's list shows.
    var movedRows: [MoveRecord] { tools.moves.shown(listed: sessions.sessions) }

    /// What was typed for `session` here and not sent waits in the field of `landed`, the same conversation on `other`.
    func handDraft(of session: SessionKey, to other: AppModel, as landed: SessionKey) {
        guard let draft = transcripts.drafts[session], !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        other.transcripts.drafts[landed] = NotificationDrafts.joined(other.transcripts.drafts[landed], draft)
        transcripts.drafts[session] = nil
    }

    /// Asks the host for its list now, so a session that just arrived is there without waiting for its event.
    func refreshSessions() async {
        guard let engine = link?.engine else { return }
        do { try await engine.refresh() } catch { RemoteLog.log(.sync, "sessions not refreshed: \(MacTools.message(error))") }
    }
}
