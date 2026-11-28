import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import XCTest
@testable import SideARemote

@MainActor
final class StandbyTests: XCTestCase {
    /// A host that answers each path with a fixed reply and remembers what it was asked.
    private final class Host: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        private let replies: [String: (status: Int, body: Data)]
        var requests: [URLRequest] { lock.withLock { seen } }

        init(_ replies: [String: (status: Int, body: Data)]) { self.replies = replies }

        func asked(_ path: String) -> Int { requests.filter { $0.url?.path == path }.count }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { seen.append(request) }
            let reply = replies[request.url?.path ?? ""] ?? (404, Data())
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badURL)
            }
            return (reply.body, response)
        }

        func socket(_ request: URLRequest) -> any SocketConnection { fatalError("no socket") }
    }

    private struct Signed: Equatable {
        let signer: DeviceKeys.Signer
        let purpose: ConfirmPurpose
        let subject: String
    }

    private func live(_ host: Host, sign: @escaping (Signed) -> String?) throws -> MacTools.Live {
        let endpoint = Endpoint(macID: "mini", baseURL: try XCTUnwrap(URL(string: "https://100.64.0.9:47800")), serverKeyHash: "k", name: "Mac mini")
        let outbox = try Outbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("standby-\(UUID().uuidString).sqlite"))
        let engine = SyncEngine(endpoint: endpoint, credentials: KeychainCredentials(), outbox: outbox, transport: host)
        return MacTools.Live(engine: engine, paired: PairedMac(endpoint: endpoint, deviceID: "d", deviceName: "iPhone"), outbox: outbox) {
            signer, purpose, subject, _ in sign(Signed(signer: signer, purpose: purpose, subject: subject))
        }
    }

    private func state(_ capabilities: Set<Capability>) -> RemoteState {
        var state = RemoteState()
        state.hello = Hello(app: "1", build: 1, mac: MacInfo(id: "mini", name: "Mac mini"), capabilities: capabilities, epoch: "e",
                            serverTime: 0, endpoints: Endpoints(tailnet: "x"), keyID: "k")
        state.epoch = "e"
        state.connection = .live(since: 1)
        return state
    }

    private let copy = StandbyCopy(conversationID: "c", agent: .claude, title: "Fix the login redirect", project: "app", computer: "book",
                                   computerName: "MacBook", at: 1_800_000_000)
    private let running = MoveState(id: "sb-1", status: .live, session: "sa-app-1a2b", folder: "/Users/you/Side A Sessions/app/.sidea-worktrees/sa-app-1a2b")

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never: \(what)")
    }

    func testCheckpointsAreReadAndShownOnlyFromAHostThatKeepsThem() async throws {
        let list = StandbyList(copies: [copy])
        let host = Host(["/v1/standby": (200, try JSONEncoder().encode(list)), "/v1/moves": (200, try JSONEncoder().encode(MoveList(moves: [])))])
        let tools = MacTools(.live(try live(host) { _ in nil }))
        var keeps = state([.moves, .standby])
        tools.apply(keeps)
        try await until("read") { tools.standby.copies == list.copies }
        XCTAssertEqual(host.asked("/v1/standby"), 1)

        keeps.sessions["s"] = RemoteSession(id: "s", agent: .claude, title: "t", project: "p", status: .idle)
        tools.apply(keeps)
        try await until("read again when the list changes, as the moves are") { host.asked("/v1/standby") == 2 }

        tools.apply(state([.moves]))
        await tools.loadMoves()
        XCTAssertEqual(host.asked("/v1/standby"), 2, "a host without standby is never asked")

        let root = AppRoot(arguments: ["--demo", "--demo-macs", "2"])
        let mini = root.macs[1]
        XCTAssertEqual(mini.standbyRows.map(\.conversationID), [DemoData.ID.lan])
        mini.tools.apply(state([.moves]))
        XCTAssertTrue(mini.standbyRows.isEmpty, "the checkpoints go with the capability")
    }

    func testACopyIsSignedWithTheFaceIDKeyOverTheConversation() async throws {
        let host = Host(["/v1/standby/c/copy": (201, try JSONEncoder().encode(running))])
        var asked: [Signed] = []
        let tools = MacTools(.live(try live(host) { signed in
            asked.append(signed)
            return "v1.1.c.AAAA"
        }))
        let started = try await tools.continueCopy(copy)

        XCTAssertEqual(asked, [Signed(signer: .confirm, purpose: .action, subject: ConfirmMessage.subject(action: .copyStandby, target: "c"))])
        let sent = try XCTUnwrap(host.requests.last)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/v1/standby/c/copy")
        XCTAssertEqual(sent.value(forHTTPHeaderField: ConfirmSignature.header), "v1.1.c.AAAA")
        XCTAssertFalse(sent.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty ?? true)
        XCTAssertNil(sent.httpBody)
        XCTAssertEqual(started.name, "sa-app-1a2b", "found by the hosted name once the host lists it")
        XCTAssertEqual(started.cwd, running.folder)
        XCTAssertEqual(started.agent, .claude)
    }

    func testACancelledFaceIDSendsNoCopy() async throws {
        let host = Host([:])
        var asked: [DeviceKeys.Signer] = []
        let tools = MacTools(.live(try live(host) { signed in
            asked.append(signed.signer)
            return nil
        }))
        do {
            _ = try await tools.continueCopy(copy)
            XCTFail("copied without Face ID")
        } catch ToolError.cancelled {}
        XCTAssertEqual(asked, [.confirm], "never the unlock key")
        XCTAssertTrue(host.requests.isEmpty)
    }

    func testARefusalShowsItsSentence() async throws {
        let refusal = #"{"error":{"code":"move_refused","message":"That session is already running on Mac mini.","retryable":false}}"#
        let host = Host(["/v1/standby/c/copy": (409, Data(refusal.utf8))])
        let model = AppModel(mac: MacConnection(name: "Mac mini", state: .live, lastSeen: .now), sessions: SessionsStore([], macID: "mini"),
                             requests: RequestsStore([]), transcripts: TranscriptStore([:]), accounts: AccountsStore([]),
                             history: HistoryStore([]), isDemo: false, paired: true, live: try live(host) { _ in "v1.1.c.AAAA" })
        let actions = SessionActions()
        actions.host = model
        actions.continueCopy(copy)
        try await until("refused") { actions.failure != nil }
        XCTAssertEqual(actions.failure, "That session is already running on Mac mini.")
        XCTAssertNil(actions.started)

        let keys = host.requests.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        actions.continueCopy(copy)
        try await until("asked again") { host.asked("/v1/standby/c/copy") == 2 }
        let again = host.requests.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        XCTAssertNotEqual(again.last, keys.last, "an answered copy spends its key")
    }

    func testADemoCopyStartsOnTheMacMiniAndLeavesTheMacBookAsItWas() async throws {
        let root = AppRoot(arguments: ["--demo", "--demo-macs", "2"])
        let book = root.macs[0], mini = root.macs[1]
        mini.tools.standby.demo?.delay = .zero
        XCTAssertTrue(book.standbyRows.isEmpty)
        let copy = try XCTUnwrap(mini.standbyRows.first)
        XCTAssertEqual(StandbyText.title(copy), "Add LAN mode")
        XCTAssertEqual(StandbyText.from(copy), "From MacBook Pro")
        XCTAssertEqual(StandbyText.warning(copy),
                       "If MacBook Pro is still running this session, both will work, and anything they do outside the repository happens twice.")
        XCTAssertTrue(StandbySection.matches(copy, "lan macbook"))
        XCTAssertFalse(StandbySection.matches(copy, "postgres"))

        let original = try XCTUnwrap(book.sessions.session(DemoData.ID.lan))
        let before = book.sessions.sessions, count = mini.sessions.sessions.count
        let actions = SessionActions()
        actions.host = mini
        actions.continueCopy(copy)
        try await until("started") { actions.started != nil }
        let started = try XCTUnwrap(actions.started)
        let landed = try XCTUnwrap(mini.sessions.sessions.first { $0.hosted == started.name }, "the starting page finds it by its hosted name")
        XCTAssertEqual(mini.sessions.sessions.count, count + 1)
        XCTAssertNotEqual(landed.conversationID, DemoData.ID.lan, "a copy is a fork with its own conversation")
        XCTAssertEqual(landed.title, "Add LAN mode")
        XCTAssertEqual(mini.transcripts.messages[landed.id], try XCTUnwrap(book.transcripts.messages[original.id]), "a fork keeps the conversation so far")
        XCTAssertEqual(book.sessions.sessions, before, "the MacBook Pro can't be told, so nothing changes there")
        XCTAssertEqual(book.sessions.session(DemoData.ID.lan), original)

        let again = try await mini.tools.continueCopy(copy)
        XCTAssertEqual(again.name, started.name, "continued again, the copy already running answers")
        XCTAssertEqual(mini.sessions.sessions.count, count + 1)
    }
}
