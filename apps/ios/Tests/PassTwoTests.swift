import SideAProtocol
import SideARemoteKit
import XCTest
@testable import SideARemote

@MainActor
final class PassTwoTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(mac: MacConnection(name: "Mac", state: .connecting, lastSeen: .now), sessions: SessionsStore([]),
                 requests: RequestsStore([]), transcripts: TranscriptStore([:]), accounts: AccountsStore([]),
                 history: HistoryStore([]), isDemo: false, paired: true)
    }

    func testADraftSurvivesTheCacheRoundTrip() throws {
        let before = model()
        before.transcripts.drafts["a"] = "half a thought"
        before.transcripts.drafts["b"] = "   "
        let cache = before.cache(finished: [:])
        XCTAssertEqual(cache.drafts, ["a": "half a thought"], "a blank field isn't a draft")

        let after = model()
        after.restore(try JSONDecoder().decode(StateCache.self, from: JSONEncoder().encode(cache)))
        XCTAssertEqual(after.transcripts.drafts["a"], "half a thought")
        XCTAssertNil(after.transcripts.drafts["b"])
    }

    func testACacheFromBeforeDraftsStillLoads() throws {
        let old = #"{"sessions":[],"finished":{},"accounts":[],"transcripts":{},"savedAt":0}"#
        let cache = try JSONDecoder().decode(StateCache.self, from: Data(old.utf8))
        XCTAssertNil(cache.drafts)
        let live = model()
        live.transcripts.drafts["a"] = "typed since"
        live.restore(cache)
        XCTAssertEqual(live.transcripts.drafts["a"], "typed since")
    }

    func testARestoredDraftNeverReplacesWhatIsBeingTyped() {
        let live = model()
        live.transcripts.drafts["a"] = "new"
        var cache = live.cache(finished: [:])
        cache.drafts = ["a": "old", "b": "kept"]
        live.restore(cache)
        XCTAssertEqual(live.transcripts.drafts["a"], "new")
        XCTAssertEqual(live.transcripts.drafts["b"], "kept")
    }

    func testChangingADraftTellsTheLinkToSave() {
        let store = TranscriptStore([:])
        var saves = 0
        store.onDraftsChanged = { saves += 1 }
        store.drafts["s"] = "one"
        store.drafts["s"] = "one"
        store.drafts["s"] = "two"
        XCTAssertEqual(saves, 2, "setting what's already there isn't a change")
    }

    private func flight(_ turn: String, _ text: String, at: Double, attachments: [String] = []) -> ReplyFlight {
        ReplyFlight(session: "s", turn: turn, body: RemoteReply(text: text, attachments: attachments), at: at, phase: .unsent(reason: "No."))
    }

    func testASecondFailedReplyCarriesTheFirst() {
        let first = flight("t1", "first", at: 1, attachments: ["u1"])
        let second = flight("t2", "second", at: 2, attachments: ["u2"])
        let joined = ReplyFlights.joined(second, after: [first])
        XCTAssertEqual(joined.body.text, "first\n\nsecond")
        XCTAssertEqual(joined.body.attachments, ["u1", "u2"])
        XCTAssertEqual(joined.turn, "t2")
        XCTAssertEqual(ReplyFlights.joined(second, after: []), second)
    }

    func testJoinedRepliesKeepTheirPhotosWithinTheLimit() {
        let many = (0..<ComposerAttachments.limit).map { "u\($0)" }
        let joined = ReplyFlights.joined(flight("t2", "b", at: 2, attachments: ["x"]), after: [flight("t1", "a", at: 1, attachments: many)])
        XCTAssertEqual(joined.body.attachments.count, ComposerAttachments.limit)
    }

    func testTheUnsentLineAndTheFieldHoldBothReplies() {
        let store = TranscriptStore([:])
        let one = store.send("first", to: "s")
        store.fail(one.id, in: "s", reason: "No.", item: "i1")
        XCTAssertEqual(store.drafts["s"], "first")

        let two = store.send("second", to: "s")
        store.fail(two.id, in: "s", reason: "No.", item: "i2", joining: ["first"])
        XCTAssertEqual(store.unsent["s"]?.text, "first\n\nsecond")
        XCTAssertEqual(store.drafts["s"], "first\n\nsecond", "the field still held just the first, so it takes both")
    }

    func testWhatIsBeingTypedIsNotReplacedByAJoin() {
        let store = TranscriptStore([:])
        store.drafts["s"] = "typing something else"
        let two = store.send("second", to: "s")
        store.fail(two.id, in: "s", reason: "No.", item: "i2", joining: ["first"])
        XCTAssertEqual(store.unsent["s"]?.text, "first\n\nsecond")
        XCTAssertEqual(store.drafts["s"], "typing something else")
    }

    func testALoadFailureIsKeptUntilOneLoads() {
        let store = TranscriptStore([:])
        store.loadFailed(true, for: "s")
        XCTAssertTrue(store.loadFailures.contains("s"))
        XCTAssertFalse(store.loadFailures.contains("t"))
        store.loadFailed(false, for: "s")
        XCTAssertTrue(store.loadFailures.isEmpty)
    }

    private final class Silent: Transport, @unchecked Sendable {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
        func socket(_ request: URLRequest) -> any SocketConnection { fatalError("no socket") }
    }

    func testAMacOutOfReachFailsTheOpenTranscript() async throws {
        let endpoint = Endpoint(macID: "passtwo", baseURL: URL(string: "https://100.64.0.9:47800")!, serverKeyHash: "k", name: "Studio")
        let outbox = try Outbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("passtwo-\(UUID().uuidString).sqlite"))
        let live = model()
        let link = LiveLink(mac: PairedMac(endpoint: endpoint, deviceID: "d", deviceName: "iPhone"), outbox: outbox, transport: Silent())
        link.attach(live)
        addTeardownBlock { @MainActor in link.stop() }
        let following = Task { await link.follow("s") }
        defer { following.cancel() }
        for _ in 0..<600 where !live.transcripts.loadFailures.contains("s") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(live.transcripts.loadFailures.contains("s"))
        XCTAssertNil(live.transcripts.messages["s"], "nothing is shown as loaded")
    }

    private func question(multi: Bool = false) -> IslandQuestion {
        IslandQuestion(question: "Which?", header: nil, options: [.init(label: "A", description: nil), .init(label: "B", description: nil)], multiSelect: multi)
    }

    func testPickingOnAloneQuestionSelectsAndNeverSends() {
        XCTAssertTrue(QuestionCard.isSingle([question()]))
        XCTAssertFalse(QuestionCard.advancesOnPick([question()]), "a lone single-choice question waits for Send Answer")
    }

    func testPickingAmongSeveralMovesOnButSendsNothing() {
        XCTAssertFalse(QuestionCard.isSingle([question(), question()]))
        XCTAssertTrue(QuestionCard.advancesOnPick([question(), question()]))
        XCTAssertFalse(QuestionCard.isSingle([question(multi: true)]))
    }

    func testAMacWithEverythingIsCurrent() {
        XCTAssertFalse(MacTools.lacksExpected(MacTools.everything))
        XCTAssertFalse(MacTools.lacksExpected(MacTools.everything.union([.hosted])))
    }

    func testAMacMissingWhatThisAppUsesNeedsAnUpdate() {
        XCTAssertTrue(MacTools.lacksExpected(MacTools.everything.subtracting([.history])))
        XCTAssertTrue(MacTools.lacksExpected([.events, .images]))
    }

    func testWhatAMacInstallsIsNotItsAge() {
        for setup: Capability in [.hosted, .terminal, .replyTerminal, .replyInbox, .hostedShow] {
            XCTAssertFalse(MacTools.expected.contains(setup), "\(setup.rawValue) comes from what's installed on the Mac, not from its version")
        }
    }

    func testAMacThatHasntSaidWhatItCanDoIsNotOld() {
        XCTAssertFalse(MacTools.lacksExpected([]))
        XCTAssertFalse(MacTools().needsMacUpdate)
    }

    func testEmptyAccountsSayNoAccountsOnlyOnceTheMacsAreLive() {
        XCTAssertEqual(AccountsView.emptyState([.live]), .noAccounts)
        XCTAssertEqual(AccountsView.emptyState([.live, .live]), .noAccounts)
        XCTAssertEqual(AccountsView.emptyState([.connecting]), .waiting)
        XCTAssertEqual(AccountsView.emptyState([.live, .connecting]), .waiting)
        XCTAssertEqual(AccountsView.emptyState([.offline(.macUnreachable)]), .banner)
        XCTAssertEqual(AccountsView.emptyState([.offline(.incompatible(installed: "0.5"))]), .banner)
        XCTAssertEqual(AccountsView.emptyState([.offline(.revoked)]), .pairAgain(.revoked))
        XCTAssertEqual(AccountsView.emptyState([.offline(.revoked), .live]), .banner)
    }
}
