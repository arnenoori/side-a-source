import SideAProtocol
import SideARemoteKit
import Testing

// Every stage × event of a handoff picked on the phone.
@Test func everyEventFromEveryHandoffStage() {
    typealias S = HandoffStage
    let reviewed = Handoff(goal: "Ship it", branch: nil, failed: "", next: "", lastMessages: "", cwd: "/p", project: "p")
    let edited = Handoff(goal: "Ship it today", branch: nil, failed: "", next: "", lastMessages: "", cwd: "/p", project: "p")
    let codex = HandoffDraft(agent: .codex, modelID: "a"), kept = HandoffDraft(agent: .codex, modelID: "a", handoff: reviewed)
    let other = HandoffDraft(agent: .codex, modelID: "b"), otherKept = HandoffDraft(agent: .codex, modelID: "b", handoff: reviewed)
    let rewritten = HandoffDraft(agent: .codex, modelID: "a", handoff: edited)
    let events: [S.Event] = [.picked(other), .reviewed(edited), .send(message: "go"), .started(name: "n"), .notStarted, .dropped, .sessionGone]
    let table: [(S?, [S?])] = [
        (nil, [.drafted(other), nil, nil, nil, nil, nil, nil]),
        (.drafted(codex), [.drafted(other), .drafted(rewritten), .sending(codex, message: "go"), .drafted(codex), .drafted(codex), nil, nil]),
        (.drafted(kept), [.drafted(otherKept), .drafted(rewritten), .sending(kept, message: "go"), .drafted(kept), .drafted(kept), nil, nil]),
        (.sending(kept, message: "m"), [.sending(otherKept, message: "m"), .sending(rewritten, message: "m"), .sending(kept, message: "m"),
                                        .handedOff(kept, message: "m", name: "n"),
                                        .drafted(kept), nil, .sending(kept, message: "m")]),
    ]
    for (stage, row) in table {
        for (event, expected) in zip(events, row) {
            let next = S.next(stage, event)
            #expect(next.stage == expected && next.giveBack == nil, "\(String(describing: stage)) \(event)")
        }
    }
}

// The new session ending before it starts gives the words back and the draft with them, and nothing else does.
@Test func aHandoffThatEndsBeforeItStartsComesBack() {
    typealias S = HandoffStage
    let draft = HandoffDraft(agent: .codex, modelID: "a"), other = HandoffDraft(agent: .codex, modelID: "b")
    let gone = S.handedOff(draft, message: "go", name: "n")
    #expect(S.next(.sending(draft, message: "go"), .started(name: "n")).stage == gone)
    #expect(S.next(gone, .ended(name: "n")) == (.drafted(draft), "go"))
    #expect(S.next(gone, .arrived(name: "n")) == (nil, nil))
    #expect(S.next(gone, .ended(name: "m")) == (gone, nil) && S.next(gone, .arrived(name: "m")) == (gone, nil))
    #expect(S.next(gone, .sessionGone) == (gone, nil))
    #expect(S.next(gone, .picked(other)) == (.drafted(other), nil) && S.next(gone, .dropped) == (nil, nil))
    for event: S.Event in [.reviewed(Handoff(goal: "", failed: "", next: "", lastMessages: "", cwd: "/p", project: "p")), .send(message: "x"),
                           .started(name: "x"), .notStarted] {
        #expect(S.next(gone, event) == (gone, nil), "\(event)")
    }
    #expect(gone.pending == nil && S.drafted(draft).pending == draft && S.sending(draft, message: "go").pending == draft)
    for stage: S? in [nil, .drafted(draft), .sending(draft, message: "go")] {
        #expect(S.next(stage, .ended(name: "n")) == (stage, nil) && S.next(stage, .arrived(name: "n")) == (stage, nil))
    }
}

// Another set of photos is another request, so it never reuses the first one's idempotency key.
@Test func aHandoffAttemptWithOtherPhotosIsAnotherAttempt() {
    let draft = HandoffDraft(agent: .codex)
    #expect(HandoffAttempt(draft: draft, message: "m", photos: ["a"]) != HandoffAttempt(draft: draft, message: "m"))
    #expect(HandoffAttempt(draft: draft, message: "m") == HandoffAttempt(draft: draft, message: "m", photos: []))
}
