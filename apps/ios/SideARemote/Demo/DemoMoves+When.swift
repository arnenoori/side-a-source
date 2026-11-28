import Foundation
import SideAProtocol

/// A working demo session moves as the host moves one: After This Turn waits for the turn, which the demo ends `turnEnds`
/// later; Now cuts the turn off and goes. An idle one goes at once whatever was asked.
extension DemoMoves {
    func move(_ id: SessionKey, to computer: String, when: MoveRequest.When?) throws -> MoveRecord {
        guard when == .afterTurn, let session = home?.sessions.session(id), MoveWhen.isWorking(session) else { return try move(id, to: computer) }
        let (record, _) = try record(id, to: computer, state: .waiting)
        turns[record.id] = Task { [weak self, turnEnds] in
            try? await Task.sleep(for: turnEnds)
            if !Task.isCancelled { self?.endTurn(of: record.id) }
        }
        return record
    }

    /// The turn a move waits for is over: the session finishes it here, then goes.
    func endTurn(of id: String) {
        turns.removeValue(forKey: id)?.cancel()
        guard let home, let record = home.tools.moves.record(id), record.state == .waiting,
              var session = home.sessions.sessions.first(where: { $0.conversationID == record.conversationID }) else { return }
        session.status = .finished
        session.statusAt = Date.now.timeIntervalSince1970
        home.sessions.replace(home.sessions.sessions.map { $0.id == session.id ? session : $0 }, finished: [:])
        let moving = record.with(state: .moving)
        home.tools.moves.update(moving)
        go(moving, session)
    }

    /// False once it has started, as the host's 409.
    func cancel(_ id: String) -> Bool {
        guard let home, home.tools.moves.record(id)?.state == .waiting else { return false }
        turns.removeValue(forKey: id)?.cancel()
        home.tools.moves.drop(id)
        return true
    }
}
