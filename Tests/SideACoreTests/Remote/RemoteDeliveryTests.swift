import Foundation
@testable import SideACore
import Testing

private typealias D = RemoteDelivery

/// Every cell of protocol's delivery table, read across: auto, followUp, note, keys.
@Test(arguments: [
    (D.State.waiting, false, AgentProvider.claude, [D.Decision.refused(.waiting), .refused(.waiting), .note, .refused(.notHosted)]),
    (.waiting, true, .codex, [.refused(.waiting), .refused(.waiting), .note, .keys]),
    (.unknown, false, .claude, [.refused(.cannot), .refused(.cannot), .refused(.cannot), .refused(.notHosted)]),
    (.unknown, true, .claude, [.refused(.cannot), .refused(.cannot), .refused(.cannot), .keys]),
    (.working, true, .claude, [.typed, .queued, .note, .keys]),
    (.working, true, .codex, [.refused(.cannot), .refused(.cannot), .note, .keys]),
    (.working, false, .claude, [.note, .queued, .note, .refused(.notHosted)]),
    (.working, false, .codex, [.refused(.cannot), .refused(.cannot), .note, .refused(.notHosted)]),
    (.finishedWaiting, false, .claude, [.followUp, .followUp, .refused(.cannot), .refused(.notHosted)]),
    (.finishedWaiting, true, .codex, [.followUp, .followUp, .refused(.cannot), .keys]),
    (.idle, true, .claude, [.typed, .typed, .refused(.cannot), .keys]),
    (.idle, false, .claude, [.refused(.continueOnPhone), .refused(.continueOnPhone), .refused(.continueOnPhone), .refused(.notHosted)]),
])
func replyDeliveryFollowsTheTable(_ state: RemoteDelivery.State, _ hosted: Bool, _ agent: AgentProvider, _ expected: [RemoteDelivery.Decision]) {
    let modes: [ReplyMode] = [.auto, .followUp, .note, .keys]
    #expect(modes.map { D.decide(state, hosted: hosted, agent: agent, mode: $0, mailHooks: true, stopHooks: true) } == expected)
}

@Test func deliveriesThatNeedHooksSaySoWhenTheyreOff() {
    #expect(D.decide(.working, hosted: false, agent: .claude, mode: .auto, mailHooks: false, stopHooks: true) == .refused(.setup))
    // Codex's Stop hook never waits, so hooks being on or off changes nothing.
    for stopHooks in [true, false] {
        #expect(D.decide(.working, hosted: false, agent: .codex, mode: .auto, mailHooks: true, stopHooks: stopHooks) == .refused(.cannot))
        #expect(D.decide(.working, hosted: true, agent: .codex, mode: .followUp, mailHooks: true, stopHooks: stopHooks) == .refused(.cannot))
    }
    // Codex's notes go through the same mail hooks.
    #expect(D.decide(.working, hosted: false, agent: .codex, mode: .note, mailHooks: false, stopHooks: true) == .refused(.cannot))
    #expect(D.decide(.working, hosted: false, agent: .claude, mode: .followUp, mailHooks: true, stopHooks: false) == .refused(.setup))
}
