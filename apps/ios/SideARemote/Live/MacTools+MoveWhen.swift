import Foundation
import SideAProtocol
import SideARemoteKit

/// When a session that is working goes (capability `moves.when`): after this turn, or now, cutting its turn off. A host
/// without the capability moves only an idle session, and is never asked for anything else.
enum MoveWhen {
    /// Its turn is under way or waits on an answer, so a plain move would be refused.
    static func isWorking(_ session: RemoteSession) -> Bool { ![.idle, .finished].contains(session.status) }

    /// Waiting on an answer: stopping the turn would drop the question, so it only goes once the turn ends.
    static func asksYou(_ session: RemoteSession) -> Bool { session.status == .waiting || !session.openRequests.isEmpty }

    /// The `when` a move of `session` carries: none for an idle one, or on a host that doesn't know the field.
    static func asked(_ session: RemoteSession, chosen: MoveRequest.When, tools: MacTools) -> MoveRequest.When? {
        guard tools.can(.movesWhen), isWorking(session) else { return nil }
        return asksYou(session) ? .afterTurn : chosen
    }
}

extension SessionMoves {
    /// The move waiting for this session's turn to end, while there is one. Its session runs here meanwhile.
    func waiting(for session: RemoteSession) -> MoveRecord? {
        guard let conversation = session.conversationID else { return nil }
        return records.first { $0.conversationID == conversation && $0.state == .waiting }
    }

    func drop(_ id: String) { set(records.filter { $0.id != id }) }
}

extension MacTools {
    /// Cancels a move waiting for its turn; true when it was. 409 says it has started and 404 that it is over, which the
    /// host's list then shows, so neither is an error to the person who tapped Cancel.
    @discardableResult
    func cancelMove(_ record: MoveRecord) async throws -> Bool {
        if isDemo {
            guard let demo = moves.demo else { throw ToolError.demo }
            return demo.cancel(record.id)
        }
        let client = try await client()
        do {
            try await client.reaching { try await client.cancelMove(record.id) }
        } catch let failure as RemoteFailure where [404, 409].contains(failure.status) {
            await loadMoves()
            return false
        }
        moves.drop(record.id)
        return true
    }

    /// A waiting move goes by itself once its session's turn ends, and nothing says so: from then on its record is read as a
    /// move under way is, until the host says it went or why it didn't.
    func noteWaiting(_ state: RemoteState) {
        let waiting = moves.records.filter { $0.state == .waiting }
        guard !waiting.isEmpty || !moves.rested.isEmpty else { return }
        let working = Set(state.sessions.values.filter(MoveWhen.isWorking).compactMap(\.conversationID))
        let rested = Set(waiting.map(\.conversationID).filter { !working.contains($0) })
        guard rested != moves.rested else { return }
        moves.rested = rested
        if !rested.isEmpty, isLive { Task { await loadMoves() } }
    }
}
