import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import XCTest
@testable import SideARemote

@MainActor
final class StateMachineTests: XCTestCase {
    private final class Silent: Transport, @unchecked Sendable {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
        func socket(_ request: URLRequest) -> any SocketConnection { fatalError("no socket") }
    }

    private let endpoint = Endpoint(macID: "flights", baseURL: URL(string: "https://100.64.0.9:47800")!, serverKeyHash: "k", name: "Studio")
    private let refused = APIError(code: ErrorCode(rawValue: "invalid"), message: "No.", retryable: false)
    private let needsFaceID = APIError(code: .confirmRequired, message: "Confirm with Face ID on your iPhone.", details: ["level": "biometric"])

    private func request(_ id: String = "r") -> RemoteRequest {
        RemoteRequest(id: id, sessionID: "s", agent: .claude, tool: "Bash", action: .command("ls"), headline: "Allow Bash",
                      risk: .normal, answers: [.allow, .deny], title: "t", arrivedAt: 0)
    }

    private func outbox() throws -> Outbox {
        try Outbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("flights-\(UUID().uuidString).sqlite"))
    }

    /// A link whose engine has settled with no token (`unpaired`), so only the states a test applies move it. This Mac
    /// has no device keys, which is what a cancelled Face ID looks like to the link: no signature comes back.
    private func link(_ outbox: Outbox) async throws -> (LiveLink, AppModel) {
        let model = AppModel.unpaired()
        let link = LiveLink(mac: PairedMac(endpoint: endpoint, deviceID: "d", deviceName: "iPhone"), outbox: outbox, transport: Silent())
        link.attach(model)
        try await until("unpaired") { link.state.connection == .unpaired }
        addTeardownBlock { @MainActor in link.stop() }
        return (link, model)
    }

    private func until(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never: \(what)")
    }

    private func signing(_ link: LiveLink) -> RemoteState {
        var state = link.state
        state.hello = Hello(app: "1", build: 1, mac: MacInfo(id: "m", name: "Studio"), capabilities: [.confirmActions], epoch: "e", serverTime: 0,
                            endpoints: Endpoints(tailnet: "x"), keyID: "k")
        return state
    }

    private func items(_ outbox: Outbox) async -> [Outbox.Item] { await outbox.items(for: "flights") }

    private func sent(_ item: Outbox.Item) throws -> RemoteReply { try JSONDecoder().decode(RemoteReply.self, from: item.body) }

    // MARK: Answers

    func testAnsweringAgainKeepsOneRowThatFollowsTheNewAttempt() {
        let store = TranscriptStore([:])
        store.onRetry = { _ in }
        store.record(.allowed, for: request(), in: "s")
        var state = RemoteState()
        state.outcomes["r:allow"] = .failed(refused)

        var (delivery, next) = AnswerAttempt.sending(item: "r:allow", retried: false).advanced(in: state, request: "r")
        store.deliver("r", in: "s", delivery!)
        XCTAssertEqual(store.answered["s"]?.first?.delivery, .failed("No."))
        XCTAssertNil(next)

        store.record(.denied, for: request(), in: "s")
        XCTAssertEqual(store.answered["s"]?.count, 1)
        XCTAssertEqual(store.answered["s"]?.first?.delivery, .sending)
        XCTAssertEqual(store.answered["s"]?.first?.outcome, .denied)

        // The earlier key's refusal is nothing to this attempt.
        (delivery, next) = AnswerAttempt.sending(item: "r:deny:a1", retried: false).advanced(in: state, request: "r")
        XCTAssertEqual(delivery, .sending)
        XCTAssertEqual(next, .sending(item: "r:deny:a1", retried: false))

        state.outcomes["r:deny:a1"] = .delivered(Data())
        (delivery, next) = AnswerAttempt.sending(item: "r:deny:a1", retried: false).advanced(in: state, request: "r")
        store.deliver("r", in: "s", delivery!)
        XCTAssertEqual(store.answered["s"]?.first?.delivery, .delivered)
        XCTAssertNil(next)
    }

    func testASettlingElsewhereReplacesAFailedRow() {
        let store = TranscriptStore([:])
        store.onRetry = { _ in }
        store.record(.allowed, for: request(), in: "s")
        store.deliver("r", in: "s", .failed("No."))
        store.record(.elsewhere("Denied on Mac"), for: request(), in: "s")
        XCTAssertEqual(store.answered["s"]?.count, 1)
        XCTAssertEqual(store.answered["s"]?.first?.delivery, .delivered)
    }

    func testAnUnknownAttemptWaitsForRetryUntilTheRequestSettles() {
        var state = RemoteState()
        state.outcomes["r:allow"] = .unknown
        let (delivery, next) = AnswerAttempt.sending(item: "r:allow", retried: false).advanced(in: state, request: "r")
        XCTAssertEqual(delivery, .unknown)
        XCTAssertEqual(next, .unknown(item: "r:allow"))
        // Being signed, the old outcome doesn't flip the row back.
        XCTAssertEqual(AnswerAttempt.retrying(item: "r:allow").advanced(in: state, request: "r").delivery, .sending)

        state.resolved["r"] = RequestResolution(requestID: "r", by: .mac, at: 1)
        let settled = AnswerAttempt.unknown(item: "r:allow").advanced(in: state, request: "r")
        XCTAssertNil(settled.delivery)
        XCTAssertNil(settled.next)
    }

    // MARK: Replies

    /// Cancelled Face ID, first send and Retry alike: nothing goes, and what was typed and attached stays.
    func testADeclinedSignatureSendsNothingAndKeepsTheReply() async throws {
        let outbox = try outbox()
        let (link, model) = try await link(outbox)
        link.apply(signing(link))
        let turn = model.transcripts.send("!rm -rf build", to: "s")
        link.reply(turn.text, turn: turn.id, to: "s", mode: .note, submit: .steer, resending: ["up1"])
        try await until("not sent") { model.transcripts.unsent["s"] != nil }
        let count = await items(outbox).count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.transcripts.drafts["s"], "!rm -rf build")
        let item = try XCTUnwrap(model.transcripts.unsent["s"]?.item)
        let saved = await outbox.flights(for: "flights")
        XCTAssertEqual(saved[item]?.body.attachments, ["up1"])

        let retried = model.transcripts.send("!rm -rf build", to: "s")
        link.retry(item: item, text: retried.text, turn: retried.id, session: "s")
        try await until("not sent again") { model.transcripts.unsent["s"] != nil }
        let afterRetry = await items(outbox).count
        XCTAssertEqual(afterRetry, 0)
        let again = try XCTUnwrap(model.transcripts.unsent["s"]?.item)
        let kept = await outbox.flights(for: "flights")
        XCTAssertEqual(kept[again]?.body.mode, .note)
        XCTAssertEqual(kept[again]?.body.submit, .steer)
        XCTAssertEqual(kept[again]?.body.attachments, ["up1"])
        XCTAssertEqual(kept.count, 1)
    }

    /// The Mac asks for Face ID and it's cancelled: no fresh reply with an empty tray, and Retry asks at that level
    /// instead of sending unsigned for another refusal.
    func testARefusalWhoseResignIsCancelledKeepsAttachmentsAndNeverGoesUnsigned() async throws {
        let outbox = try outbox()
        let (link, model) = try await link(outbox)
        let turn = model.transcripts.send("hello", to: "s")
        link.reply(turn.text, turn: turn.id, to: "s", mode: .auto, resending: ["up1", "up2"])
        try await until("queued") { await !self.items(outbox).isEmpty }
        let first = await items(outbox)[0]

        var state = link.state
        state.outcomes[first.id] = .failed(needsFaceID)
        try await until("in flight") { await outbox.flights(for: "flights")[first.id]?.phase == .queued(resigned: false) }
        link.apply(state)
        try await until("not sent") { model.transcripts.unsent["s"] != nil }
        let unsent = try XCTUnwrap(model.transcripts.unsent["s"])
        XCTAssertEqual(unsent.item, first.id)
        XCTAssertEqual(unsent.reason, needsFaceID.message)

        let retried = model.transcripts.send("hello", to: "s")
        link.retry(item: first.id, text: "hello", turn: retried.id, session: "s")
        try await until("not sent again") { model.transcripts.unsent["s"] != nil }
        let queued = await items(outbox)
        XCTAssertEqual(queued.map(\.id), [first.id], "only the first, unsigned one the Mac refused")
        let saved = await outbox.flights(for: "flights").values.first
        XCTAssertEqual(saved?.needs, .biometric)
        XCTAssertEqual(saved?.body.attachments, ["up1", "up2"])
    }

    /// After a kill, the turn is back as sending, and a refusal that comes later shows with its text.
    func testAFlightInTheOutboxSurvivesAKillAndItsRefusalStillShows() async throws {
        let outbox = try outbox()
        let body = RemoteReply(text: "Before the kill", mode: .note, attachments: ["up1"], submit: .steer)
        await outbox.enqueue(Outbox.Item(id: "item", macID: "flights", path: "/v1/sessions/s/reply", createdAt: 1, expiresAt: 9_999_999_999))
        await outbox.setFlight(ReplyFlight(session: "s", turn: "t", body: body, at: 1, phase: .queued(resigned: false)), item: "item", mac: "flights")

        let (link, model) = try await link(outbox)
        try await until("restored") { model.transcripts.outgoing["s"]?.first?.id == "t" }
        XCTAssertEqual(model.transcripts.outgoing["s"]?.first?.state, .sending)
        XCTAssertNil(model.transcripts.unsent["s"])

        var state = link.state
        state.outcomes["item"] = .failed(refused)
        link.apply(state)
        XCTAssertEqual(model.transcripts.unsent["s"], TranscriptStore.Unsent(text: "Before the kill", reason: "No.", item: "item"))
        XCTAssertEqual(model.transcripts.drafts["s"], "Before the kill")

        let retried = model.transcripts.send("Before the kill", to: "s")
        link.retry(item: "item", text: "Before the kill", turn: retried.id, session: "s")
        try await until("sent again") { await self.items(outbox).count == 2 }
        let again = try await sent(items(outbox).last { $0.id != "item" }!)
        XCTAssertEqual(again.attachments, ["up1"])
        XCTAssertEqual(again.mode, .note)
        XCTAssertEqual(again.submit, .steer)
    }

    func testAKilledReplyThatNeverQueuedWaitsForRetryAndADeliveredOneLeavesNoText() async throws {
        let outbox = try outbox()
        let body = RemoteReply(text: "Being signed", attachments: ["up1"])
        await outbox.setFlight(ReplyFlight(session: "a", turn: "t1", body: body, at: Date.now.timeIntervalSince1970), item: "signing", mac: "flights")
        await outbox.setFlight(ReplyFlight(session: "old", turn: "t2", body: body, at: 1, phase: .unsent(reason: "No.")), item: "expired", mac: "flights")
        await outbox.enqueue(Outbox.Item(id: "going", macID: "flights", path: "/v1/sessions/b/reply", createdAt: 1, expiresAt: 9_999_999_999))
        await outbox.setFlight(ReplyFlight(session: "b", turn: "t3", body: body, at: Date.now.timeIntervalSince1970, phase: .queued(resigned: false)), item: "going", mac: "flights")

        let (link, model) = try await link(outbox)
        try await until("restored") { model.transcripts.unsent["a"] != nil && model.transcripts.outgoing["b"]?.isEmpty == false }
        XCTAssertEqual(model.transcripts.unsent["a"]?.item, "signing")
        XCTAssertEqual(model.transcripts.drafts["a"], "Being signed")
        XCTAssertNil(model.transcripts.unsent["old"])

        var state = link.state
        state.outcomes["going"] = .delivered(Data(#"{"delivery":"note","sessionID":"b"}"#.utf8))
        link.apply(state)
        XCTAssertEqual(model.transcripts.outgoing["b"]?.first?.state, .note)
        try await until("gone from disk") { await outbox.flights(for: "flights").keys.sorted() == ["signing"] }
    }

    func testSendingFromTheFieldInsteadOfRetryKeepsThePhotosAndDropsTheOldFlight() async throws {
        let outbox = try outbox()
        await outbox.setFlight(ReplyFlight(session: "s", turn: "t", body: RemoteReply(text: "Old", attachments: ["up1"]), at: Date.now.timeIntervalSince1970,
                                           phase: .unsent(reason: "No.")), item: "old", mac: "flights")
        let (link, model) = try await link(outbox)
        try await until("restored") { model.transcripts.unsent["s"] != nil }
        let turn = model.transcripts.send("Old, edited", to: "s")
        XCTAssertNil(model.transcripts.unsent["s"])
        link.reply(turn.text, turn: turn.id, to: "s", mode: .auto)
        try await until("queued") { await !self.items(outbox).isEmpty }
        let body = try await sent(items(outbox)[0])
        XCTAssertEqual(body.attachments, ["up1"])
        try await until("one flight") { await outbox.flights(for: "flights")["old"] == nil }
    }

    func testForgettingAMacForgetsWhatWaitedForRetry() async throws {
        let outbox = try outbox()
        await outbox.setFlight(ReplyFlight(session: "s", turn: "t", body: RemoteReply(text: "Secret"), at: Date.now.timeIntervalSince1970,
                                           phase: .unsent(reason: "No.")), item: "old", mac: "flights")
        let (link, model) = try await link(outbox)
        try await until("restored") { model.transcripts.unsent["s"] != nil }
        link.forgetFlights()
        try await until("gone") { await outbox.flights(for: "flights").isEmpty }
    }

    // MARK: Live Activity

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { list.append(request) } }
        var all: [URLRequest] { lock.withLock { list } }
    }

    private func relayed(_ install: String) -> PairedMac {
        PairedMac(endpoint: Endpoint(macID: "m-\(install)", baseURL: URL(string: "https://100.64.0.1:47800")!, serverKeyHash: "k", name: install), deviceID: "d-\(install)",
                  deviceName: "iPhone", relayInstallID: install, relayURL: "https://relay.example")
    }

    /// The same vector as the relay's `macIDFor`.
    func testAnActivitysMacIDIsDerivedAsTheRelayDoes() {
        XCTAssertEqual(RelayDevice.activityMacID(install: "i-r1"), "IwXLK-99zxKcF6v-")
    }

    func testAnActivityTokenGoesToTheRelayOfTheMacThatStartedIt() async throws {
        let keychain = SharedKeychain.shared
        defer { for install in ["i-r1", "i-r2"] { keychain.set(nil, for: "secret.m-\(install)") } }
        keychain.set(Data([1, 2, 3]), for: "secret.m-i-r1")
        keychain.set(Data([4, 5, 6]), for: "secret.m-i-r2")
        let macs = [relayed("i-r2"), relayed("i-r1")]
        let calls = Calls()
        await RelayDevice.putActivity("A-1", token: "aabb", macID: RelayDevice.activityMacID(install: "i-r1"), bundleID: "com.arnenoori.sidea.remote.dev",
                                      environment: .sandbox, macs: macs) { calls.add($0); return 204 }
        await RelayDevice.deleteActivity("A-1", macID: RelayDevice.activityMacID(install: "i-r1"), macs: macs) { calls.add($0); return 204 }
        await RelayDevice.putActivity("A-2", token: "aabb", macID: "nobody", bundleID: "b", environment: .sandbox, macs: macs) { calls.add($0); return 204 }
        XCTAssertEqual(calls.all.map(\.httpMethod), ["PUT", "DELETE"])
        XCTAssertEqual(calls.all.map(\.url?.absoluteString), ["https://relay.example/v1/device/activities/A-1", "https://relay.example/v1/device/activities/A-1"])
        XCTAssertEqual(calls.all[0].value(forHTTPHeaderField: "Authorization"), "Bearer d1.i-r1.d-i-r1.AQID")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(calls.all[0].httpBody)) as? [String: String])
        XCTAssertEqual(body, ["updateToken": "aabb", "bundleID": "com.arnenoori.sidea.remote.dev", "apnsEnvironment": "sandbox"])
    }

    func testSwitchingLiveActivityOffEndsEveryRealCard() {
        XCTAssertTrue(PushRegistrar.endsWhenOff(macID: "mac", enabled: false))
        XCTAssertFalse(PushRegistrar.endsWhenOff(macID: "mac", enabled: true))
        XCTAssertFalse(PushRegistrar.endsWhenOff(macID: NotificationAnswer.demoMac, enabled: false))
    }

    /// After a relaunch there's no Queued turn left to fail: the phone that sent it still gets its words back, once.
    func testADroppedReplyComesBackWithOrWithoutItsTurnAndOnlyOnce() {
        let store = TranscriptStore([:])
        let sent = store.send("one", to: "s", at: Date(timeIntervalSince1970: 10))
        store.mark(sent.id, in: "s", .queued)
        let records = [DroppedReply(id: "a", sessionID: "s", text: "one", at: 20, device: "d1", reason: .sessionEnded),
                       DroppedReply(id: "b", sessionID: "s", text: "two", at: 21, device: "d1", reason: .sessionEnded),
                       DroppedReply(id: "c", sessionID: "t", text: nil, at: 22, device: nil, reason: .sessionEnded),
                       DroppedReply(id: "d", sessionID: "u", text: nil, at: 23, device: nil, reason: .oldQueue)]
        let kept = store.send("kept", to: "u", at: Date(timeIntervalSince1970: 10))
        store.mark(kept.id, in: "u", .queued)
        let settled = store.settle(records, device: "d1", settled: [])
        XCTAssertEqual(settled, ["a", "b", "c", "d"])
        XCTAssertEqual(store.drafts["s"], "one\n\ntwo")
        XCTAssertEqual(store.unsent["s"]?.text, "one\n\ntwo")
        XCTAssertEqual(store.outgoing["s"]?.count, 0)
        XCTAssertNil(store.drafts["t"], "another phone's reply isn't this one's to send")
        XCTAssertEqual(store.drafts["u"], "kept")
        XCTAssertEqual(store.unsent["u"]?.reason, "Side A updated before it could be sent.")

        store.clearUnsent("s")
        store.drafts["s"] = ""
        XCTAssertEqual(store.settle(records, device: "d1", settled: settled), settled)
        XCTAssertNil(store.unsent["s"], "seen before a relaunch, not seen again")
        XCTAssertEqual(store.settle([], device: "d1", settled: settled), [], "forgotten once the Mac has")
    }

    /// The same words queued again after the drop are a new promise.
    func testADroppedReplyLeavesALaterTurnWithTheSameWordsAlone() {
        let store = TranscriptStore([:])
        let again = store.send("same", to: "s", at: Date(timeIntervalSince1970: 100))
        store.mark(again.id, in: "s", .queued)
        _ = store.settle([DroppedReply(id: "a", sessionID: "s", text: "same", at: 50, device: "d1", reason: .sessionEnded)], device: "d1", settled: [])
        XCTAssertEqual(store.outgoing["s"]?.map(\.id), [again.id])
    }

    /// The Mac at this pairing's address answers to another id, so nothing this pairing signs can verify.
    func testAPairingForAnIdTheMacNoLongerAnswersToAsksToPairAgain() async throws {
        let tools = MacTools()
        tools.paired = PairedMac(endpoint: Endpoint(macID: "old", baseURL: URL(string: "https://100.64.0.1:47800")!, serverKeyHash: "k", name: "Studio"),
                                 deviceID: "d", deviceName: "iPhone")
        func answering(_ id: String) -> RemoteState {
            var state = RemoteState()
            state.hello = Hello(app: "1", build: 1, mac: MacInfo(id: id, name: "Studio"), capabilities: [.confirmSigned], epoch: "e", serverTime: 0,
                                endpoints: Endpoints(tailnet: "x"), keyID: "k")
            return state
        }
        tools.apply(answering("old"))
        XCTAssertNil(tools.answersAs)
        tools.apply(answering("new"))
        XCTAssertEqual(tools.answersAs, "new")
        XCTAssertTrue(tools.needsKeys)
    }

    func testAQueueTheMacGaveUpOnPutsTheReplyBackInTheField() {
        let store = TranscriptStore([:])
        let sent = store.send("try again", to: "s")
        let other = store.send("still sending", to: "s")
        store.mark(sent.id, in: "s", .queued)
        store.failQueued(in: "s", reason: "This session ended before it could be sent.")
        XCTAssertFalse(store.outgoing["s"]?.contains { $0.id == sent.id } ?? false)
        XCTAssertTrue(store.outgoing["s"]?.contains { $0.id == other.id } ?? false)
        XCTAssertEqual(store.drafts["s"], "try again")
    }
}
