import Observation
import SideAProtocol
import SideARemoteKit

@Observable
final class HandoffDrafts {
    nonisolated deinit {}

    private(set) var stages: [SessionKey: HandoffStage] = [:]
    /// Handoffs sent from here, by the new hosted session's name, until its row carries the link itself.
    private(set) var started: [String: HandoffLink] = [:]

    func started(_ name: String, from link: HandoffLink) { started[name] = link }

    /// The link a session shows above its first turn: the Mac's, else the one its start answered with.
    func link(for session: RemoteSession) -> HandoffLink? {
        session.handoffFrom ?? session.hosted.flatMap { started[$0] }
    }

    subscript(_ session: SessionKey) -> HandoffDraft? { stages[session]?.pending }

    func sending(_ session: SessionKey) -> Bool { if case .sending? = stages[session] { true } else { false } }

    /// Handed off as the hosted session of this name, which hasn't shown yet.
    func handedOff(_ session: SessionKey) -> String? { if case .handedOff(_, _, let name)? = stages[session] { name } else { nil } }

    /// Answers the words that go back to the session's field.
    @discardableResult func move(_ session: SessionKey, _ event: HandoffStage.Event) -> String? {
        let next = HandoffStage.next(stages[session], event)
        if stages[session] != next.stage { stages[session] = next.stage }
        return next.giveBack
    }
}
