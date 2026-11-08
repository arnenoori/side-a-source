import Foundation
import SideAProtocol

/// What a turn changed, and compact and review, by agent. Codex sessions on its app server are here; Claude's are in
/// SessionCommands+ClaudeTurns.swift.
extension SessionCommands {
    func turnDiff(_ id: String, turn: String) async throws(Failure) -> TurnDiff {
        guard let target = Target(id, store: store), let live = target.live else { throw .noSession }
        switch live.provider {
        case .claude: return try await claudeTurnDiff(live, key: target.key, turn: turn)
        case .codex:
            guard let diff = store.remote.codex.diff(live, turn: turn) else {
                throw Failure(status: 404, code: "turn_not_found", message: "Side A has no changes for that turn.")
            }
            return TurnDiff(sessionID: target.key, turnID: turn, files: diff.files, running: diff.running)
        }
    }

    func compact(_ id: String) async throws(Failure) {
        guard let live = Target(id, store: store)?.live else { throw .noSession }
        switch live.provider {
        case .claude: try await claudeCompact(live)
        case .codex:
            do throws(CodexTerminals.Failure) { try await store.remote.codex.compact(live) } catch { throw .codex(error) }
        }
    }

    func review(_ id: String, _ request: ReviewRequest) async throws(Failure) {
        guard request.target == .uncommittedChanges else {
            throw Failure(status: 422, code: "invalid_review", message: "Side A reviews uncommitted changes only.")
        }
        guard let live = Target(id, store: store)?.live else { throw .noSession }
        switch live.provider {
        case .claude: try await claudeReview(live)
        case .codex:
            do throws(CodexTerminals.Failure) { try await store.remote.codex.review(live) } catch { throw .codex(error) }
        }
    }

    /// A 409 that says why, for what an agent can't do.
    static func cannot(_ message: String) -> Failure {
        Failure(status: 409, code: "cannot_deliver", message: message, details: ["hint": "unsupported"])
    }
}
