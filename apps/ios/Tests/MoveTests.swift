import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import XCTest
@testable import SideARemote

@MainActor
final class MoveTests: XCTestCase {
    /// A host that answers each path with a fixed reply and remembers what it was asked.
    private final class Host: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        private let replies: [String: (status: Int, body: Data)]
        var requests: [URLRequest] { lock.withLock { seen } }

        init(_ replies: [String: (status: Int, body: Data)]) { self.replies = replies }

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

    private func tools(_ host: Host, sign: @escaping (Signed) -> String?) throws -> MacTools {
        let endpoint = Endpoint(macID: "moves", baseURL: try XCTUnwrap(URL(string: "https://100.64.0.9:47800")), serverKeyHash: "k", name: "MacBook Pro")
        let outbox = try Outbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("moves-\(UUID().uuidString).sqlite"))
        let engine = SyncEngine(endpoint: endpoint, credentials: KeychainCredentials(), outbox: outbox, transport: host)
        return MacTools(.live(.init(engine: engine, paired: PairedMac(endpoint: endpoint, deviceID: "d", deviceName: "iPhone"), outbox: outbox) {
            signer, purpose, subject, _ in sign(Signed(signer: signer, purpose: purpose, subject: subject))
        }))
    }

    private func moving(_ hello: Bool = true) -> RemoteState {
        var state = RemoteState()
        state.hello = Hello(app: "1", build: 1, mac: MacInfo(id: "moves", name: "MacBook Pro"), capabilities: hello ? [.moves] : [], epoch: "e",
                            serverTime: 0, endpoints: Endpoints(tailnet: "x"), keyID: "k")
        return state
    }

    private func record(_ state: MoveRecord.State, conversation: String, to computer: String = "demo-2", named name: String = "Mac mini",
                        session: String? = nil) -> MoveRecord {
        MoveRecord(id: "mv-\(conversation)", conversationID: conversation, agent: .claude, title: "Fix the login redirect", project: "app",
                   state: state, computer: computer, computerName: name, at: 1_800_000_000, session: session)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never: \(what)")
    }

    func testMoveShowsForASessionTheHostCanMoveOnAHostThatMoves() throws {
        let tools = try tools(Host([:])) { _ in nil }
        let movable = RemoteSession(id: "s", conversationID: "c", agent: .claude, title: "t", project: "p", status: .idle, abilities: [.transcript, .move])
        let stays = RemoteSession(id: "t", conversationID: "d", agent: .claude, title: "t", project: "p", status: .idle, abilities: [.transcript])
        XCTAssertFalse(MoveButton.shows(movable, tools: tools), "a host without moves")
        tools.apply(moving())
        XCTAssertTrue(MoveButton.shows(movable, tools: tools))
        XCTAssertFalse(MoveButton.shows(stays, tools: tools))
        tools.apply(moving(false))
        XCTAssertFalse(MoveButton.shows(movable, tools: tools))
    }

    func testAMoveIsSignedWithTheFaceIDKeyOverTheSessionAndWhereItGoes() async throws {
        let host = Host(["/v1/sessions/s/move": (202, try JSONEncoder().encode(record(.moving, conversation: "c", to: "mini")))])
        var asked: [Signed] = []
        let tools = try tools(host) { signed in
            asked.append(signed)
            return "v1.1.c.AAAA"
        }
        let session = RemoteSession(id: "s", conversationID: "c", agent: .claude, title: "t", project: "p", status: .idle, abilities: [.move])
        let started = try await tools.move(session, to: RemoteComputer(id: "mini", name: "Mac mini"), key: "key-1")

        let subject = try ConfirmMessage.subject(action: .moveSession, target: "s", body: MoveRequest(computer: "mini"))
        XCTAssertEqual(asked, [Signed(signer: .confirm, purpose: .action, subject: subject)])
        let sent = try XCTUnwrap(host.requests.last)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/v1/sessions/s/move")
        XCTAssertEqual(sent.value(forHTTPHeaderField: ConfirmSignature.header), "v1.1.c.AAAA")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Idempotency-Key"), "key-1")
        XCTAssertEqual(try JSONDecoder().decode(MoveRequest.self, from: XCTUnwrap(sent.httpBody)), MoveRequest(computer: "mini"))
        XCTAssertEqual(started.state, .moving)
        XCTAssertEqual(tools.moves.record(started.id)?.state, .moving)
    }

    func testACancelledFaceIDSendsNoMove() async throws {
        let host = Host([:])
        var asked: [DeviceKeys.Signer] = []
        let tools = try tools(host) { signed in
            asked.append(signed.signer)
            return nil
        }
        let session = RemoteSession(id: "s", conversationID: "c", agent: .claude, title: "t", project: "p", status: .idle, abilities: [.move])
        do {
            _ = try await tools.move(session, to: RemoteComputer(id: "mini", name: "Mac mini"), key: "key-1")
            XCTFail("moved without Face ID")
        } catch ToolError.cancelled {}
        XCTAssertEqual(asked, [.confirm], "never the unlock key")
        XCTAssertTrue(host.requests.isEmpty)
    }

    func testTheListAsksForMovesWhenItsSessionsChange() async throws {
        let list = MoveList(moves: [record(.away, conversation: "c", session: "sa-app-1a2b")])
        let host = Host(["/v1/moves": (200, try JSONEncoder().encode(list))])
        let tools = try tools(host) { _ in nil }
        var state = moving()
        state.epoch = "e"
        state.connection = .live(since: 1)
        tools.apply(state)
        try await until("read") { tools.moves.records == list.moves }
        let asked = host.requests.filter { $0.url?.path == "/v1/moves" }.count
        XCTAssertEqual(asked, 1)

        state.sessions["s"] = RemoteSession(id: "s", agent: .claude, title: "t", project: "p", status: .idle)
        tools.apply(state)
        try await until("read again") { host.requests.filter { $0.url?.path == "/v1/moves" }.count == 2 }
    }

    func testADemoMoveLandsOnTheOtherMacAndComesBackTheSameWay() async throws {
        let root = AppRoot(arguments: ["--demo", "--demo-macs", "2"])
        let book = root.macs[0], mini = root.macs[1]
        book.tools.moves.demo?.delay = .zero
        mini.tools.moves.demo?.delay = .zero
        let session = try XCTUnwrap(book.sessions.session(DemoData.ID.spec))
        XCTAssertTrue(MoveButton.shows(session, tools: book.tools))
        XCTAssertFalse(MoveButton.shows(try XCTUnwrap(book.sessions.session(DemoData.ID.syncTest)), tools: book.tools), "it waits on a request")

        let computers = try await book.tools.computers()
        XCTAssertEqual(computers.map(\.id), ["demo-2"])
        let preview = try await book.tools.movePreview(session.id, to: computers[0])
        XCTAssertEqual(preview.computer.name, "Mac mini")
        XCTAssertNil(MoveText.account(preview), "Mac mini is signed in to Work already")
        let landing = try await book.tools.movePreview(DemoData.ID.landing, to: computers[0])
        XCTAssertEqual(MoveText.account(landing), "Signs Mac mini in to Team")

        book.transcripts.drafts[session.id] = "Then update the README"
        let started = try await book.tools.move(session, to: computers[0], key: "k")
        XCTAssertEqual(started.state, .moving)
        try await until("landed") { mini.sessions.sessions.contains { $0.conversationID == DemoData.ID.spec } }
        XCTAssertNil(book.sessions.session(DemoData.ID.spec))
        let away = try XCTUnwrap(book.tools.moves.record(started.id))
        XCTAssertEqual(away.state, .away)
        XCTAssertEqual(book.movedRows.map(\.id), [started.id])
        XCTAssertEqual(MoveText.status(away), "On Mac mini")
        XCTAssertEqual(MovedActions(away, root: root).open, .session(DemoData.ID.spec, mac: "demo-2"))

        let there = try XCTUnwrap(MoveLanding.session(for: away, in: mini.sessions.sessions))
        XCTAssertEqual(there.hosted, away.session)
        book.handDraft(of: session.id, to: mini, as: there.id)
        XCTAssertEqual(mini.transcripts.drafts[there.id], "Then update the README")
        XCTAssertNil(book.transcripts.drafts[session.id])
        XCTAssertTrue(MoveButton.shows(there, tools: mini.tools), "bringing it back is a move the other way")
        let home = try await mini.tools.computers()
        XCTAssertEqual(home.map(\.id), [book.macID])
        _ = try await mini.tools.move(there, to: home[0], key: "k2")
        try await until("back") { book.sessions.session(DemoData.ID.spec) != nil }
        XCTAssertTrue(book.movedRows.isEmpty, "back on the MacBook, so nothing says it is away")
        XCTAssertEqual(mini.movedRows.map(\.state), [.away])
    }

    func testMovedRowsSayWhereEachSessionIsAndOfferWhatCanBeDone() throws {
        let root = AppRoot(arguments: ["--demo", "--demo-macs", "2"])
        let book = root.macs[0], mini = root.macs[1]
        book.tools.moves.set([record(.moving, conversation: "c1"), record(.away, conversation: "c2", session: "sa-app-1a2b"),
                              record(.unknown, conversation: "c3"), record(.failed, conversation: "c4"),
                              record(.away, conversation: "c5", to: "elsewhere", named: "build-box")])
        XCTAssertEqual(book.movedRows.map(\.conversationID), ["c1", "c2", "c3", "c5"], "a failed move ran here again")
        XCTAssertEqual(book.movedRows.map(MoveText.status), ["Moving to Mac mini…", "On Mac mini", "May be running on Mac mini", "On build-box"])

        let offers = book.movedRows.map { MovedActions($0, root: root) }
        XCTAssertEqual(offers.map(\.checks), [false, false, true, false])
        XCTAssertEqual(offers.map(\.open), [nil, nil, nil, nil], "Mac mini doesn't list it yet, and build-box isn't paired")

        mini.sessions.replace(mini.sessions.sessions + [RemoteSession(id: "m2", conversationID: "c2", agent: .claude, title: "t", project: "app",
                                                                      status: .idle, hosted: "sa-app-1a2b")], finished: [:])
        XCTAssertEqual(MovedActions(book.movedRows[1], root: root).open, .session("m2", mac: "demo-2"))

        let leaving = RemoteSession(id: "l", conversationID: "c1", agent: .claude, title: "t", project: "app", status: .idle)
        let back = RemoteSession(id: "b", conversationID: "c2", agent: .claude, title: "t", project: "app", status: .idle)
        XCTAssertTrue(book.tools.moves.isLeaving(leaving), "its row gives way while it moves")
        XCTAssertFalse(book.tools.moves.isLeaving(back))
        book.sessions.replace(book.sessions.sessions + [leaving, back], finished: [:])
        XCTAssertEqual(book.movedRows.map(\.conversationID), ["c1", "c3", "c5"], "listed here again, so it came back")
    }

    func testThePreviewSaysWhatHappensToTheAccountAndWhereItLands() {
        let mini = RemoteComputer(id: "mini", name: "Mac mini")
        XCTAssertEqual(MoveText.account(MovePreview(computer: mini, account: "Work", login: .sent)), "Signs Mac mini in to Work")
        XCTAssertEqual(MoveText.account(MovePreview(computer: mini, account: "Work", login: .other)), "Runs on Mac mini's own account")
        XCTAssertNil(MoveText.account(MovePreview(computer: mini, account: "Work", login: .there)))
        XCTAssertNil(MoveText.account(MovePreview(computer: mini)))
        XCTAssertEqual(MoveText.folder("/Users/you/Side A Sessions/app/.sidea-worktrees/sa-app-3f2a"), "~/Side A Sessions/app/.sidea-worktrees/sa-app-3f2a")
        XCTAssertEqual(MoveText.folder("/home/alex/code/app"), "~/code/app")
        XCTAssertEqual(MoveText.folder("/srv/app"), "/srv/app")
    }
}
