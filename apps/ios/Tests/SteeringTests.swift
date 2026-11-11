import SideAProtocol
import XCTest
@testable import SideARemote

@MainActor
final class SteeringTests: XCTestCase {
    private func user(_ seq: Int, _ text: String, at: Timestamp) -> TranscriptMessage {
        TranscriptMessage(seq: seq, uuid: "u\(seq)", role: .user, at: at, text: text)
    }

    private func assistant(_ seq: Int, at: Timestamp) -> TranscriptMessage {
        TranscriptMessage(seq: seq, uuid: "a\(seq)", role: .assistant, at: at, text: "ok")
    }

    func testSentTurnLeavesOnceTheMacShowsIt() {
        let store = TranscriptStore([:])
        let turn = store.send("Run the tests", to: "s", at: Date(timeIntervalSince1970: 1_000))
        store.mark(turn.id, in: "s", .sent)
        // An older turn with the same words doesn't count.
        store.set([user(0, "Run the tests", at: 100)], hasEarlier: false, for: "s")
        XCTAssertEqual(store.outgoing["s"]?.count, 1)
        store.set([user(0, "Run the tests", at: 100), user(1, "Run the tests", at: 1_001)], hasEarlier: false, for: "s")
        XCTAssertEqual(store.outgoing["s"], [])
    }

    func testNoteStaysAfterTheMacMovesOn() {
        let store = TranscriptStore([:])
        let turn = store.send("Use the staging DB", to: "s", at: Date(timeIntervalSince1970: 1_000))
        store.mark(turn.id, in: "s", .note)
        store.noteRead(in: "s")
        store.set([assistant(0, at: 900), assistant(1, at: 1_100)], hasEarlier: false, for: "s")
        XCTAssertEqual(store.outgoing["s"]?.map(\.state), [.read])
        // Drawn where it was sent, between the two assistant turns.
        let items = TranscriptLayout.items(messages: store.messages["s"]!, earlier: 0, working: true, outgoing: store.outgoing["s"]!)
        XCTAssertEqual(items.map(\.id), ["m-0", "o-\(turn.id)", "m-1"])
    }

    func testUnsentReplyGoesBackToTheField() {
        let store = TranscriptStore([:])
        let turn = store.send("Ship it", to: "s")
        store.fail(turn.id, in: "s", reason: "The Mac couldn't be reached.", item: "item-1")
        XCTAssertEqual(store.outgoing["s"], [])
        XCTAssertEqual(store.drafts["s"], "Ship it")
        XCTAssertEqual(store.unsent["s"]?.item, "item-1")
        // Something new in the field isn't overwritten.
        store.drafts["s"] = "Something else"
        let second = store.send("Ship it", to: "s")
        store.fail(second.id, in: "s", reason: "", item: nil)
        XCTAssertEqual(store.drafts["s"], "Something else")
    }

    func testTakeBackReturnsTheNote() {
        let store = TranscriptStore([:])
        let turn = store.send("Skip the docs", to: "s")
        store.mark(turn.id, in: "s", .note)
        XCTAssertEqual(store.pendingNote("s")?.id, turn.id)
        store.withdraw(turn.id, in: "s")
        XCTAssertNil(store.pendingNote("s"))
        XCTAssertEqual(store.drafts["s"], "Skip the docs")
    }

    func testSecondNoteTravelsWithTheFirst() {
        let model = AppModel.demo()
        let id = DemoData.ID.postgres
        let first = model.transcripts.send("Use port 5433", to: id)
        model.transcripts.mark(first.id, in: id, .note)
        model.reply("And skip the seed", to: id)
        XCTAssertEqual(model.transcripts.outgoing[id]?.count, 1)
        XCTAssertEqual(model.transcripts.outgoing[id]?.first?.text, "Use port 5433\n\nAnd skip the seed")
    }

    func testMailLineOnlyForMailThisPhoneDidntLeave() {
        let stop = MailState(kind: .stop, at: 1)
        XCTAssertEqual(TranscriptLayout.items(messages: [], earlier: 0, mail: stop).map(\.id), ["mail"])
        let note = TranscriptStore.Outgoing(id: "n", text: "hi", at: .now, state: .note)
        let items = TranscriptLayout.items(messages: [], earlier: 0, outgoing: [note], mail: MailState(kind: .note, at: 1))
        XCTAssertEqual(items.map(\.id), ["o-n"])
    }

    func testSteersFollowAbilities() {
        let data = DemoData(now: .now)
        let session = { (id: String) in data.sessions.first { $0.id == id } }
        // Unhosted Claude: stop mail and notes, no Esc.
        XCTAssertEqual(Steer.available(for: session(DemoData.ID.postgres)), [.stopBeforeNextStep, .note])
        // A note already waits, so a stop would replace it.
        XCTAssertEqual(Steer.available(for: session(DemoData.ID.ship)), [.note])
        // Hosted Codex: Esc only.
        XCTAssertEqual(Steer.available(for: session(DemoData.ID.lan)), [.interruptNow])
    }

    private func working(_ id: String, _ agent: AgentProvider, hosted: String? = nil, abilities: Set<SessionAbility>,
                         status: SessionStatus = .working) -> RemoteSession {
        RemoteSession(id: id, conversationID: id, agent: agent, title: id, project: "p", status: status, hosted: hosted, abilities: abilities)
    }

    private func model(_ sessions: [RemoteSession]) -> AppModel {
        AppModel(mac: MacConnection(name: "Mac", state: .live, lastSeen: .now), sessions: SessionsStore(sessions),
                 requests: RequestsStore([]), transcripts: TranscriptStore([:]), accounts: AccountsStore([]),
                 history: HistoryStore([]), isDemo: true, paired: true)
    }

    /// Only what the Mac's delivery table carries out mid-turn, by kind of session.
    func testSendsLongPressOffersWhatTheSessionTakes() {
        let model = model([
            working("hosted-claude", .claude, hosted: "sa-1", abilities: [.type, .terminal, .interrupt, .followUp]),
            working("hosted-codex", .codex, hosted: "sa-2", abilities: [.type, .terminal, .interrupt]),
            working("shared-codex", .codex, abilities: [.replyTerminal, .interrupt, .followUp]),
            working("claude", .claude, abilities: [.note, .interrupt, .followUp]),
            working("claude-no-stop-hook", .claude, abilities: [.note, .interrupt]),
            working("codex-mail", .codex, abilities: [.note]),
            working("idle", .claude, hosted: "sa-3", abilities: [.type, .terminal], status: .idle),
            working("asking", .claude, abilities: [.note], status: .waiting),
        ])
        XCTAssertEqual(model.deliveries("hosted-claude"), [.nextStep, .afterTurn, .interrupt])
        // The Mac refuses a reply to hosted Codex mid-turn, so it can only be stopped first.
        XCTAssertEqual(model.deliveries("hosted-codex"), [.interrupt])
        XCTAssertEqual(model.deliveries("shared-codex"), [.steer, .afterTurn, .interrupt])
        // Unhosted Claude has no instant interrupt, only stop mail.
        XCTAssertEqual(model.deliveries("claude"), [.nextStep, .afterTurn])
        XCTAssertEqual(model.deliveries("claude-no-stop-hook"), [.nextStep])
        XCTAssertEqual(model.deliveries("codex-mail"), [.nextStep])
        XCTAssertEqual(model.deliveries("idle"), [])
        XCTAssertEqual(model.deliveries("asking"), [])
    }

    func testSendAfterThisTurnQueuesAndNextStepWaits() async throws {
        let model = model([working("claude", .claude, abilities: [.note, .interrupt, .followUp])])
        model.send("After you finish, run the linter", to: "claude", as: .afterTurn)
        model.send("Use the staging DB", to: "claude", as: .nextStep)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(model.transcripts.outgoing["claude"]?.map(\.state), [.queued, .note])
    }

    func testInterruptAndSendSendsAfterTheStop() async throws {
        let model = model([working("hosted-claude", .claude, hosted: "sa-1", abilities: [.type, .terminal, .interrupt, .followUp])])
        model.send("Stop, use the other branch", to: "hosted-claude", as: .interrupt)
        XCTAssertEqual(model.transcripts.outgoing["hosted-claude"]?.map(\.state), [.sending])
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(model.transcripts.outgoing["hosted-claude"]?.map(\.state), [.sent])
    }

    func testAutoPredictsANoteOnlyForWorkingUnhostedClaude() {
        let model = AppModel.demo()
        XCTAssertEqual(model.predictedMode(DemoData.ID.postgres), .note)
        XCTAssertEqual(model.predictedMode(DemoData.ID.lan), .auto)
        XCTAssertEqual(model.predictedMode(DemoData.ID.spec), .auto)
    }
}
