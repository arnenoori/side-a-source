import Foundation
import SideACore
import SideAProtocol

/// A session that arrived here by a move and whose agent has since exited (quit, or crashed). It is still this computer's
/// to run, so it can move on, or back where it came from, as a running one does, with nothing to stop: the move carries
/// what is in the folder it landed in, and the login that arrived with it by the same rules. Undone, it starts nothing.
extension Moves {
    /// The arrival that made `conversation` this computer's, while its record names the folder it landed in and the hosted
    /// session it ran as. Says nothing about whether it runs.
    func arrival(of conversation: String) -> (id: String, incoming: Incoming)? {
        guard journal.ownership(of: conversation).mayRun,
              let entry = journal.all.last(where: { $0.session == conversation && $0.role == .destination && $0.step == .live }),
              let known = incoming[entry.id], known.folder != nil, known.session != nil else { return nil }
        return (entry.id, known)
    }

    /// `conversation` as a move reads a session, when it arrived here and nothing of it runs now: hosted under the name it
    /// had, in the folder it landed in, idle, with no process. How the phone's move and Bring Back find it.
    func ended(_ conversation: String) async -> LiveSession? {
        guard let arrival = arrival(of: conversation), let running = await live() else { return nil }
        await hosted.refresh()
        return runs(conversation, arrival.incoming, in: running) ? nil : Self.standIn(conversation, arrival.incoming)
    }

    /// The same from the lists as last read, for a menu.
    func ended(_ conversation: String, running: [LiveSession]) -> LiveSession? {
        guard let arrival = arrival(of: conversation), !runs(conversation, arrival.incoming, in: running) else { return nil }
        return Self.standIn(conversation, arrival.incoming)
    }

    /// For `prepare`: the arrival a move of `session` carries and the session that stands in for it, when its agent has
    /// exited; nil when it runs here or never arrived, which is a plain move.
    func endedArrival(of session: LiveSession) async throws -> (id: String, session: LiveSession)? {
        guard let conversation = session.sessionID, let arrival = arrival(of: conversation) else { return nil }
        guard let running = await live() else { throw MoveFailure.refused(Self.cantTell) }
        await hosted.refresh()
        guard !runs(conversation, arrival.incoming, in: running) else { return nil }
        guard let folder = arrival.incoming.folder, FileManager.default.fileExists(atPath: folder) else { throw MoveFailure.refused(folderGone) }
        return (arrival.id, Self.standIn(conversation, arrival.incoming))
    }

    /// Where `carry` would stop a running session: nothing of it may have started here since the move was agreed.
    func stillEnded(_ plan: Plan) async throws {
        guard let running = await live() else { throw MoveFailure.refused(Self.cantTell) }
        await hosted.refresh()
        guard let id = plan.ended, let known = incoming[id], !runs(plan.conversation, known, in: running) else {
            throw MoveFailure.refused("It started again here, so it stayed.")
        }
        guard FileManager.default.fileExists(atPath: plan.cwd) else { throw MoveFailure.refused(folderGone) }
    }

    /// The account an ended arrival ran on, as the other computer is told of it.
    func arrivalAccount(_ id: String) -> (id: String, wire: MoveAccount)? {
        guard let account = incoming[id]?.account, let wire = logins.account(account) else { return nil }
        return (account, wire)
    }

    /// How an ended arrival ran, for the journal: Run Here starts it on that account.
    func arrivalSeat(_ id: String) -> Seat { incoming[id]?.account.map(logins.seat) ?? Seat() }

    static let cantTell = "Side A can't tell yet whether it's running. Try again in a moment."
    private var folderGone: String { "The folder it ran in on \(me().name) is gone, so it can't move." }

    private func runs(_ conversation: String, _ known: Incoming, in running: [LiveSession]) -> Bool {
        running.contains { $0.sessionID == conversation } || hosted.sessions.contains { $0.sessionID == conversation || $0.name == known.session }
    }

    static func standIn(_ conversation: String, _ known: Incoming) -> LiveSession {
        var session = LiveSession(pid: 0, sessionID: conversation, name: nil, title: known.offer.title, cost: nil, cwd: known.folder, status: "idle",
                                  waitingFor: nil, since: nil)
        session.hosted = known.session
        session.agent = known.offer.agent.rawValue
        session.model = known.offer.model
        session.effort = known.offer.effort
        // What it ran with here: the arrival's mode, never one the computer it came from chose.
        session.mode = known.mode
        return session
    }
}
