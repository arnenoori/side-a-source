import Foundation
import SideACore
import SideAProtocol

/// A session that does not leave after all starts here again as it ran: on its account, with its model, effort and
/// permission mode. Both ways back go through here: the move's own rollback, and the settling pass that finishes a move
/// an app restart or a lost answer left open, which knows the session only from the journal.
extension Moves {
    /// What `session` runs with here, read before it is stopped and written down with the move.
    static func restart(of session: LiveSession, seat: Seat) -> MoveJournal.Restart {
        MoveJournal.Restart(pin: seat.pin, codexAccount: seat.codexAccount, model: Hosting.safeOption(session.model) ? session.model : nil,
                            effort: Hosting.safeOption(session.effort) ? session.effort : nil, permissionMode: session.mode)
    }

    /// The start that resumes `conversation` here as `settings` say. A mode that lets the agent act without asking is
    /// restored as it was only because `settings` are this computer's own record of how the session already ran here
    /// (a source entry's, or the live session's); an arrival is held to `arrival` instead, and nothing the other
    /// computer said reaches this.
    static func restart(_ conversation: String, as settings: MoveJournal.Restart?, agent: Hosting.Agent, cwd: String) -> HostedSessions.Start {
        var start = HostedSessions.Start(agent: agent, cwd: cwd, mode: .resume(conversation, model: settings?.model))
        start.origin = "move"
        start.pin = settings?.pin
        start.codexAccount = settings?.codexAccount
        start.effort = settings?.effort
        start.permissionMode = settings?.permissionMode.flatMap { Hosting.permissionArguments(agent, mode: $0) == nil ? nil : $0 }
        return start
    }
}
