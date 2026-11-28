import Foundation
@testable import SideA
import SideAProtocol
import SideASessionKit
import Testing

@Test func upInAnEmptyFieldRecallsWhatWasSaid() {
    let prompts = PromptRecall.newestFirst(["first", "  second ", "first", "", "third"])
    #expect(prompts == ["third", "first", "second"])
    // Empty field: ↑ brings back the last, and again the one before.
    let one = PromptRecall.step(1, draft: "", at: nil, prompts: prompts)
    #expect(one?.draft == "third" && one?.index == 0)
    let two = PromptRecall.step(1, draft: "third", at: 0, prompts: prompts)
    #expect(two?.draft == "first" && two?.index == 1)
    // ↓ comes forward again, and past the newest clears the field.
    #expect(PromptRecall.step(-1, draft: "first", at: 1, prompts: prompts)?.draft == "third")
    let cleared = PromptRecall.step(-1, draft: "third", at: 0, prompts: prompts)
    #expect(cleared?.draft == "" && cleared?.index == nil)
    // Nothing older: the key is the text's own.
    #expect(PromptRecall.step(1, draft: "second", at: 2, prompts: prompts) == nil)
    // Something typed, or a recalled prompt since edited, keeps its arrow keys.
    #expect(PromptRecall.step(1, draft: "typing", at: nil, prompts: prompts) == nil && PromptRecall.step(1, draft: "third!", at: 0, prompts: prompts) == nil)
    #expect(PromptRecall.step(-1, draft: "", at: nil, prompts: prompts) == nil && PromptRecall.step(1, draft: "", at: nil, prompts: []) == nil)
}

@Test func aSentMessageShowsUntilTheConversationSaysIt() {
    let now = Date(timeIntervalSince1970: 1_000)
    let waiting = [Outgoing(text: "run it", at: now), Outgoing(text: "run it", at: now), Outgoing(text: "other", at: now)]
    // The same words said before it was sent are not its echo.
    #expect(SessionDesk.unsettled(waiting, said: [("run it", 900)], now: now).count == 3)
    // One echo settles one message.
    #expect(SessionDesk.unsettled(waiting, said: [(" run it\n", 1_001)], now: now).map(\.text) == ["run it", "other"])
    #expect(SessionDesk.unsettled(waiting, said: [("run it", 1_001), ("run it", 1_002), ("other", nil)], now: now).isEmpty)
    // One that never shows is taken down.
    #expect(SessionDesk.unsettled(waiting, said: [], now: now.addingTimeInterval(SessionDesk.outgoingKept + 1)).isEmpty)
}

@MainActor @Test func onlyAMessageTypedIntoTheConversationStaysAsOutgoing() {
    let desk = SessionDesk(prefs: SessionPrefs(defaults: temporaryDefaults()))
    let typed = desk.sending("hello", to: "c1")
    let queued = desk.sending("later", to: "c1")
    #expect(desk.sending("", to: "c1") == nil && desk.outgoing["c1"]?.count == 2)
    desk.sent(typed, in: "c1", shows: true)
    desk.sent(queued, in: "c1", shows: false)
    #expect(desk.outgoing["c1"]?.map(\.text) == ["hello"] && desk.prompts("c1") == ["hello"])
    desk.settle("c1", said: [("hello", Date().timeIntervalSince1970)])
    #expect(desk.outgoing["c1"]?.isEmpty == true)
}

@Test func aDroppedFileGoesInByItsPath() {
    #expect(FileMentions.dropped("/r/app/Sources/a.swift", folder: "/r/app", agent: .claude) == "@Sources/a.swift")
    #expect(FileMentions.dropped("/r/app/Sources/a.swift", folder: "/r/app/", agent: .codex) == "Sources/a.swift")
    #expect(FileMentions.dropped("/r/app/My Notes/a b.md", folder: "/r/app", agent: .claude) == "@\"My Notes/a b.md\"")
    // Outside the folder, or with no folder known, the whole path; a sibling folder that only shares a prefix is outside.
    #expect(FileMentions.dropped("/r/other/a.txt", folder: "/r/app", agent: .claude) == "/r/other/a.txt")
    #expect(FileMentions.dropped("/r/app2/a.txt", folder: "/r/app", agent: .claude) == "/r/app2/a.txt")
    #expect(FileMentions.dropped("/r/a b.txt", folder: nil, agent: .codex) == "\"/r/a b.txt\"")
}

@MainActor @Test func waitingRepliesCanBeRewordedOrDropped() {
    let store = AccountStore(demo: true)
    let sessions = store.sessions
    #expect(store.island.queue("c9", "first thought", from: nil) && store.island.queue("c9", "second", from: nil))
    let queued = sessions.queued("c9")
    #expect(queued.map(\.text) == ["first thought", "second"])
    // Reword: the words go to the field, and sending them replaces the reply they came from.
    sessions.reword("c9", queued[0])
    #expect(sessions.drafts["c9"] == "first thought" && sessions.desk.rewording["c9"] == queued[0].id)
    sessions.removeQueued("c9", queued[0])
    #expect(sessions.queued("c9").map(\.text) == ["second"] && sessions.desk.rewording["c9"] == nil)
    sessions.removeQueued("c9", sessions.queued("c9")[0])
    #expect(sessions.queued("c9").isEmpty)
}
