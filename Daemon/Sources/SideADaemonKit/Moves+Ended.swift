import Foundation
import SideACore
import SideAProtocol

/// A session that arrived here by a move and whose agent has since exited (quit, or crashed), as the Mac's `Moves+Ended`.
/// It is still this computer's to run, so it can move on, or back where it came from, as a running one does, with nothing
/// to stop: the move carries what is in the folder it landed in, and the login that arrived with it by the same rules.
/// Undone, it starts nothing. Its pane, which tmux keeps dead, goes once the session runs on the other computer.
extension DaemonMoves {
    /// The arrival that made `conversation` this computer's, while its record names the folder it landed in and the hosted
    /// session it ran as. Says nothing about whether it runs.
    func arrival(of conversation: String) -> (id: String, incoming: Incoming)? {
        guard journal.ownership(of: conversation).mayRun,
              let entry = journal.all.last(where: { $0.session == conversation && $0.role == .destination && $0.step == .live }),
              let known = incoming[entry.id], known.folder != nil, known.session != nil else { return nil }
        return (entry.id, known)
    }

    /// `text` (a conversation, or the hosted name it ran as) as a move reads a row, when it arrived here and nothing of it
    /// runs now: hosted under the name it had, in the folder it landed in, idle, with no process.
    func ended(_ text: String) async -> LiveRow? {
        let named = journal.all.last(where: { $0.role == .destination && $0.step == .live && incoming[$0.id]?.session == text })?.session
        guard let arrival = arrival(of: text) ?? named.flatMap({ arrival(of: $0) }), !(await runs(arrival.incoming)) else { return nil }
        return LiveRow(standingIn: arrival.incoming)
    }

    /// For `prepare`: the arrival a move of `row` carries and the row that stands in for it, when its agent has exited; nil
    /// when it runs here or never arrived, which is a plain move.
    func endedArrival(of row: LiveRow) async throws -> (id: String, row: LiveRow)? {
        guard let conversation = row.id, let arrival = arrival(of: conversation), !(await runs(arrival.incoming)) else { return nil }
        guard let folder = arrival.incoming.folder, FileManager.default.fileExists(atPath: folder) else { throw MoveFailure.refused(folderGone) }
        return (arrival.id, LiveRow(standingIn: arrival.incoming))
    }

    /// Where `carry` would stop a running session: nothing of it may have started here since the move was agreed.
    func stillEnded(_ plan: Plan) async throws {
        guard let id = plan.ended, let known = incoming[id], !(await runs(known)) else { throw MoveFailure.refused("It started again here, so it stayed.") }
        guard FileManager.default.fileExists(atPath: plan.cwd) else { throw MoveFailure.refused(folderGone) }
    }

    /// The account an ended arrival ran on: as `commit` chose it, the login that came with it or the one this computer
    /// would run it on. Asked only when tmux no longer has its pane, whose own option says.
    func arrivalSlot(_ id: String) -> String? {
        guard let known = incoming[id] else { return nil }
        return (known.account ?? logins.fallback(known.offer.agent)).map { $0 == DaemonLogins.codex ? "" : $0 }
    }

    /// The session runs on the other computer now: the dead pane of its agent here goes too.
    func clearEnded(_ conversation: String) async {
        for pane in await engine.tmux.list() where pane.dead && pane.session == conversation { _ = await engine.tmux.end(pane.name) }
    }

    private var folderGone: String { "The folder it ran in on \(me().name) is gone, so it can't move." }

    private func runs(_ known: Incoming) async -> Bool {
        let conversation = known.offer.conversationID
        let rows = await engine.live(), panes = await engine.tmux.list()
        return rows.contains { $0.id == conversation } || panes.contains { !$0.dead && ($0.session == conversation || $0.name == known.session) }
    }
}

extension LiveRow {
    /// An arrival whose agent has exited, as a move reads a row. What it ran with here: the arrival's mode, never one the
    /// computer it came from chose.
    init(standingIn known: DaemonMoves.Incoming) {
        id = known.offer.conversationID
        pid = 0
        agent = known.offer.agent
        title = known.offer.title
        cwd = known.folder
        status = "idle"
        hosted = known.session
        mode = known.mode
        model = known.offer.model
        effort = known.offer.effort
        ports = []
        headless = false
    }
}
