import Observation
import SideAProtocol
import SideARemoteKit

@Observable
final class HandoffDrafts {
    nonisolated deinit {}

    private(set) var stages: [SessionKey: HandoffStage] = [:]
    private(set) var started: [String: HandoffLink] = [:]

    func started(_ name: String, from link: HandoffLink) { started[name] = link }

    func link(for session: RemoteSession) -> HandoffLink? {
        session.handoffFrom ?? session.hosted.flatMap { started[$0] }
    }

    subscript(_ session: SessionKey) -> HandoffDraft? { stages[session]?.pending }

    func sending(_ session: SessionKey) -> Bool { if case .sending? = stages[session] { true } else { false } }

    func handedOff(_ session: SessionKey) -> String? { if case .handedOff(_, _, let name)? = stages[session] { name } else { nil } }

    @discardableResult func move(_ session: SessionKey, _ event: HandoffStage.Event) -> String? {
        let next = HandoffStage.next(stages[session], event)
        if stages[session] != next.stage { stages[session] = next.stage }
        return next.giveBack
    }
}
