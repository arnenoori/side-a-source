import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import XCTest
@testable import SideARemote

/// A working session moving after its turn or now (capability `moves.when`), and the move that waits meanwhile.
@MainActor
final class MoveWhenTests: XCTestCase {
    /// A host that answers each path with a fixed reply and remembers what it was asked.
    private final class Host: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        private let replies: [String: (status: Int, body: Data)]
        var requests: [URLRequest] { lock.withLock { seen } }

        init(_ replies: [String: (status: Int, body: Data)]) { self.replies = replies }

        func asked(_ path: String, _ method: String = "GET") -> Int { requests.filter { $0.url?.path == path && $0.httpMethod == method }.count }

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

    private let mini = RemoteComputer(id: "mini", name: "Mac mini")

    private func tools(_ host: Host, sign: @escaping (Signed) -> String? = { _ in nil }) throws -> MacTools {
        let endpoint = Endpoint(macID: "book", baseURL: try XCTUnwrap(URL(string: "https://100.64.0.9:47800")), serverKeyHash: "k", name: "MacBook Pro")
        let outbox = try Outbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("move-when-\(UUID().uuidString).sqlite"))
        let engine = SyncEngine(endpoint: endpoint, credentials: KeychainCredentials(), outbox: outbox, transport: host)
        return MacTools(.live(.init(engine: engine, paired: PairedMac(endpoint: endpoint, deviceID: "d", deviceName: "iPhone"), outbox: outbox) {
            signer, purpose, subject, _ in sign(Signed(signer: signer, purpose: purpose, subject: subject))
        }))
    }

    private func state(_ capabilities: Set<Capability>, live: Bool = false, sessions: [RemoteSession] = []) -> RemoteState {
        var state = RemoteState()
        state.hello = Hello(app: "1", build: 1, mac: MacInfo(id: "book", name: "MacBook Pro"), capabilities: capabilities, epoch: "e",
                            serverTime: 0, endpoints: Endpoints(tailnet: "x"), keyID: "k")
        state.epoch = "e"
        if live { state.connection = .live(since: 1) }
        for session in sessions { state.sessions[session.id] = session }
        return state
    }

    private func session(_ status: SessionStatus, requests: [RequestID] = []) -> RemoteSession {
        RemoteSession(id: "s", conversationID: "c", agent: .claude, title: "Fix the login redirect", project: "app", status: status,
                      openRequests: requests, abilities: [.transcript, .move])
    }

    private func record(_ state: MoveRecord.State, conversation: String = "c") -> MoveRecord {
        MoveRecord(id: "mv-\(conversation)", conversationID: conversation, agent: .claude, title: "Fix the login redirect", project: "app",
                   state: state, computer: "mini", computerName: "Mac mini", at: 1_800_000_000)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never: \(what)")
    }

    func testAWorkingSessionIsOfferedAMoveOnlyByAHostThatMovesItAfterItsTurn() throws {
        let tools = try tools(Host([:]))
        let idle = session(.idle), working = session(.working), asking = session(.waiting, requests: ["r1"])
        tools.apply(state([.moves]))
        XCTAssertTrue(MoveButton.shows(idle, tools: tools))
        XCTAssertFalse(MoveButton.shows(working, tools: tools), "it would only be refused")
        XCTAssertFalse(MoveButton.shows(asking, tools: tools))
        XCTAssertNil(MoveWhen.asked(working, chosen: .now, tools: tools), "a host without moves.when is asked what it always was")

        tools.apply(state([.moves, .movesWhen]))
        XCTAssertTrue(MoveButton.shows(idle, tools: tools))
        XCTAssertTrue(MoveButton.shows(working, tools: tools))
        XCTAssertTrue(MoveButton.shows(asking, tools: tools))
        XCTAssertNil(MoveWhen.asked(idle, chosen: .now, tools: tools), "an idle session moves as it always did")
        XCTAssertEqual(MoveWhen.asked(working, chosen: .afterTurn, tools: tools), .afterTurn)
        XCTAssertEqual(MoveWhen.asked(working, chosen: .now, tools: tools), .now)
        XCTAssertEqual(MoveWhen.asked(asking, chosen: .now, tools: tools), .afterTurn, "stopping it would drop the question")

        tools.apply(state([.movesWhen]))
        XCTAssertFalse(MoveButton.shows(working, tools: tools), "a host that sends nothing")
    }

    func testTheSignedMoveAndThePreviewCarryWhen() async throws {
        let preview = MovePreview(computer: mini, landing: "/Users/you/Coding/app")
        let host = Host(["/v1/sessions/s/move": (202, try JSONEncoder().encode(record(.waiting))),
                         "/v1/sessions/s/move/preview": (200, try JSONEncoder().encode(preview))])
        var asked: [Signed] = []
        let tools = try tools(host) { signed in
            asked.append(signed)
            return "v1.1.c.AAAA"
        }
        tools.apply(state([.moves, .movesWhen]))
        let working = session(.working)

        _ = try await tools.movePreview(working.id, to: mini, when: .now)
        let previewed = try XCTUnwrap(host.requests.last { $0.url?.path == "/v1/sessions/s/move/preview" }?.httpBody)
        XCTAssertEqual(try JSONDecoder().decode(MoveRequest.self, from: previewed), MoveRequest(computer: "mini", when: .now))

        let started = try await tools.move(working, to: mini, when: .afterTurn, key: "key-1")
        let subject = try ConfirmMessage.subject(action: .moveSession, target: "s", body: MoveRequest(computer: "mini", when: .afterTurn))
        XCTAssertEqual(asked, [Signed(signer: .confirm, purpose: .action, subject: subject)])
        XCTAssertNotEqual(subject, try ConfirmMessage.subject(action: .moveSession, target: "s", body: MoveRequest(computer: "mini")),
                          "a host that drops when computes another subject and refuses")
        let sent = try XCTUnwrap(host.requests.last { $0.url?.path == "/v1/sessions/s/move" })
        XCTAssertEqual(try JSONDecoder().decode(MoveRequest.self, from: XCTUnwrap(sent.httpBody)), MoveRequest(computer: "mini", when: .afterTurn))
        XCTAssertEqual(started.state, .waiting)
        XCTAssertEqual(tools.moves.waiting(for: working), started)
    }

    func testCancelKeepsTheSessionAndAMoveThatStartedOrEndedIsReadAgain() async throws {
        let waiting = record(.waiting)
        let cancelPath = "/v1/moves/\(waiting.id)"

        let cancels = Host([cancelPath: (204, Data())])
        let kept = try tools(cancels)
        kept.apply(state([.moves, .movesWhen]))
        kept.moves.set([waiting])
        let cancelled = try await kept.cancelMove(waiting)
        XCTAssertTrue(cancelled)
        XCTAssertTrue(kept.moves.records.isEmpty)
        let sent = try XCTUnwrap(cancels.requests.last)
        XCTAssertEqual(sent.httpMethod, "DELETE")
        XCTAssertNil(sent.value(forHTTPHeaderField: ConfirmSignature.header), "it only keeps a session here: no signature")

        let refusal = #"{"error":{"code":"move_refused","message":"It has started moving, so it can't be cancelled.","retryable":false}}"#
        let started = Host([cancelPath: (409, Data(refusal.utf8)),
                            "/v1/moves": (200, try JSONEncoder().encode(MoveList(moves: [waiting.with(state: .moving)])))])
        let going = try tools(started)
        going.apply(state([.moves, .movesWhen]))
        going.moves.set([waiting])
        let stopped = try await going.cancelMove(waiting)
        XCTAssertFalse(stopped, "409 is no error: the list says where it stands")
        XCTAssertEqual(started.asked("/v1/moves"), 1)
        XCTAssertEqual(going.moves.records.map(\.state), [.moving])

        let over = #"{"error":{"code":"no_move","message":"That move is over.","retryable":false}}"#
        let ended = Host([cancelPath: (404, Data(over.utf8)), "/v1/moves": (200, try JSONEncoder().encode(MoveList(moves: [])))])
        let gone = try tools(ended)
        gone.apply(state([.moves, .movesWhen]))
        gone.moves.set([waiting])
        let found = try await gone.cancelMove(waiting)
        XCTAssertFalse(found)
        XCTAssertEqual(ended.asked("/v1/moves"), 1)
        XCTAssertTrue(gone.moves.records.isEmpty)
    }

    func testAWaitingMoveIsNotAMovedRowAndItsSessionStaysListed() throws {
        let root = AppRoot(arguments: ["--demo", "--demo-macs", "2"])
        let book = root.macs[0]
        let session = try XCTUnwrap(book.sessions.session(DemoData.ID.lan))
        let waiting = record(.waiting, conversation: DemoData.ID.lan)
        book.tools.moves.set([waiting])

        XCTAssertTrue(book.movedRows.isEmpty)
        XCTAssertFalse(book.tools.moves.isLeaving(session), "its row stays where it is")
        XCTAssertNil(MoveStatusLine.record(for: session.conversationID, in: book), "the field stays")
        XCTAssertFalse(book.tools.moves.inFlight)
        XCTAssertEqual(book.tools.moves.waiting(for: session), waiting)
        XCTAssertEqual(MoveText.status(waiting), "Moves to Mac mini after this turn")
        XCTAssertNil(book.tools.moves.waiting(for: try XCTUnwrap(book.sessions.session(DemoData.ID.ship))))

        book.tools.moves.set([waiting.with(state: .moving)])
        XCTAssertNil(book.tools.moves.waiting(for: session), "once it starts it is a move under way")
        XCTAssertTrue(book.tools.moves.isLeaving(session))
    }

    func testAWaitingMoveIsReadAgainOnceItsTurnEnds() async throws {
        let waiting = record(.waiting)
        let host = Host(["/v1/moves": (200, try JSONEncoder().encode(MoveList(moves: [waiting])))])
        let tools = try tools(host)
        tools.apply(state([.moves, .movesWhen], live: true, sessions: [session(.working)]))
        try await until("read") { tools.moves.records == [waiting] }
        XCTAssertFalse(tools.moves.inFlight, "nothing to follow while its turn goes on")

        tools.apply(state([.moves, .movesWhen], live: true, sessions: [session(.working)]))
        XCTAssertEqual(host.asked("/v1/moves"), 1)

        tools.apply(state([.moves, .movesWhen], live: true, sessions: [session(.finished)]))
        XCTAssertTrue(tools.moves.inFlight, "the host sends it now, by itself")
        try await until("read again") { host.asked("/v1/moves") >= 2 }
    }

    func testADemoSessionWaitsForItsTurnCanBeCancelledThenGoesWhenTheTurnEnds() async throws {
        let root = AppRoot(arguments: ["--demo", "--demo-macs", "2"])
        let book = root.macs[0], mini = root.macs[1]
        let demo = try XCTUnwrap(book.tools.moves.demo)
        demo.delay = .zero
        demo.turnEnds = .seconds(3_600)
        let session = try XCTUnwrap(book.sessions.session(DemoData.ID.lan))
        XCTAssertEqual(session.status, .working)
        XCTAssertTrue(MoveButton.shows(session, tools: book.tools))
        XCTAssertEqual(MoveWhen.asked(session, chosen: .afterTurn, tools: book.tools), .afterTurn)
        let computers = try await book.tools.computers()
        _ = try await book.tools.movePreview(session.id, to: computers[0], when: .afterTurn)

        let first = try await book.tools.move(session, to: computers[0], when: .afterTurn, key: "k")
        XCTAssertEqual(first.state, .waiting)
        XCTAssertEqual(book.tools.moves.waiting(for: session)?.id, first.id)
        XCTAssertTrue(book.movedRows.isEmpty)
        XCTAssertEqual(book.sessions.session(session.id)?.status, .working, "it carries on here while it waits")
        let cancelled = try await book.tools.cancelMove(first)
        XCTAssertTrue(cancelled)
        XCTAssertNil(book.tools.moves.waiting(for: session))
        XCTAssertNotNil(book.sessions.session(session.id))
        let again = try await book.tools.cancelMove(first)
        XCTAssertFalse(again)

        let second = try await book.tools.move(session, to: computers[0], when: .afterTurn, key: "k2")
        demo.endTurn(of: second.id)
        XCTAssertEqual(book.tools.moves.record(second.id)?.state, .moving)
        let late = try await book.tools.cancelMove(second)
        XCTAssertFalse(late, "it has started")
        try await until("landed") { mini.sessions.sessions.contains { $0.conversationID == DemoData.ID.lan } }
        XCTAssertNil(book.sessions.session(session.id))
        XCTAssertEqual(book.movedRows.map(\.id), [second.id])
        XCTAssertEqual(book.movedRows.first?.state, .away)
    }

    func testADemoTurnEndsOnTheDemosClockAndNowGoesAtOnce() async throws {
        let root = AppRoot(arguments: ["--demo", "--demo-macs", "2"])
        let book = root.macs[0], mini = root.macs[1]
        let demo = try XCTUnwrap(book.tools.moves.demo)
        demo.delay = .zero
        demo.turnEnds = .zero
        let computers = try await book.tools.computers()

        let ship = try XCTUnwrap(book.sessions.session(DemoData.ID.ship))
        let waited = try await book.tools.move(ship, to: computers[0], when: .afterTurn, key: "k")
        XCTAssertEqual(waited.state, .waiting)
        try await until("its turn ended and it landed") { mini.sessions.sessions.contains { $0.conversationID == DemoData.ID.ship } }
        XCTAssertEqual(book.tools.moves.record(waited.id)?.state, .away)

        let postgres = try XCTUnwrap(book.sessions.session(DemoData.ID.postgres))
        let now = try await book.tools.move(postgres, to: computers[0], when: .now, key: "k2")
        XCTAssertEqual(now.state, .moving, "its turn is cut off and it goes")
        try await until("landed") { mini.sessions.sessions.contains { $0.conversationID == DemoData.ID.postgres } }
        XCTAssertEqual(mini.sessions.sessions.first { $0.conversationID == DemoData.ID.postgres }?.status, .idle)
    }
}
