import Foundation
import SideACore
import SideAProtocol

extension SessionCommands {
    /// The bridge reads the turn from the transcript: each edit that went through, from the turn's prompt to the next,
    /// with its note that a shell command's changes aren't among them.
    func claudeTurnDiff(_ live: LiveSession, key: SessionKey, turn: String) async throws(Failure) -> TurnDiff {
        guard let id = live.sessionID else { throw .noSession }
        do {
            return try RemoteTranscript.turnDiff(try await store.sessions.remoteReply(["turn-diff", "--turn", turn, "--", id]), key: key)
        } catch let failure as RemoteTranscript.Failure where failure.message.contains("isn't in this conversation") {
            throw Failure(status: 404, code: "turn_not_found", message: "Side A has no changes for that turn.")
        } catch {
            throw Self.readFailure(error)
        }
    }

    /// `/compact` typed into a hosted Claude while it's idle. The answer comes once it's in; hosted.attention follows
    /// if the conversation doesn't compact within two minutes.
    func claudeCompact(_ live: LiveSession) async throws(Failure) {
        guard let name = live.hosted else { throw Self.cannot(Self.compactRefusal) }
        switch Target(WireBuilders.key(live), store: store)?.state(store.island) {
        case .idle?, .finishedWaiting?: break
        case .waiting?: throw Failure(status: 409, code: "session_waiting", message: "Answer the open request first.")
        default: throw Self.cannot("Claude is working. Try when it's idle.")
        }
        let before = live.compactedAt ?? 0
        do {
            try await store.hosted.command(name, "/compact")
            let sessions = store.sessions, pid = live.pid
            store.hosted.expectCompaction(name) { (sessions.live.first { $0.pid == pid }?.compactedAt ?? 0) > before }
        } catch let error as HostedError {
            throw .hosted(error)
        } catch {
            throw Self.internalFailure("Side A couldn't type into that session.")
        }
    }

    nonisolated static let compactRefusal = "Compacting needs a session Side A hosts."

    func claudeReview(_ live: LiveSession) async throws(Failure) {
        throw Self.cannot("Ask Claude in a reply.")
    }
}
