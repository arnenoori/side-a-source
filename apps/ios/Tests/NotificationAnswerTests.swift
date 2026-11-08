import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import XCTest
@testable import SideARemote

@MainActor
final class NotificationAnswerTests: XCTestCase {
    private final class Silent: Transport, @unchecked Sendable {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
        func socket(_ request: URLRequest) -> any SocketConnection { fatalError("no socket") }
    }

    private struct NoToken: CredentialStore {
        func token(for macID: String) async throws -> String? { nil }
        func setToken(_ token: String?, for macID: String) async throws {}
    }

    private let endpoint = Endpoint(macID: "answers", baseURL: URL(string: "https://100.64.0.9:47800")!, serverKeyHash: "k", name: "Studio")

    private func outbox() throws -> Outbox {
        try Outbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("answers-\(UUID().uuidString).sqlite"))
    }

    /// A notification's Allow and the app's are one outbox item, so whichever goes second is a replay.
    func testANotificationsAnswerIsTheItemTheAppMakes() async throws {
        let engine = SyncEngine(endpoint: endpoint, credentials: NoToken(), outbox: try outbox(), transport: Silent())
        for answer in [RemoteAnswer.allow(confirmDestructive: false), .deny(message: nil), .approvePlan(acceptEdits: true)] {
            let app = await engine.answer("r1", answer, confirm: "sig")
            XCTAssertEqual(NotificationAnswer.item(answer, to: "r1", macID: endpoint.macID, now: app.createdAt, confirm: "sig"), app)
        }
    }

    /// A Mac too old to list dropped replies says only that it gave up on a session's queue: what this phone queued
    /// there goes back in the field, once per drop.
    func testAQueueDropFromTheMacGivesBackWhatWasQueued() async throws {
        let model = AppModel.unpaired()
        let link = LiveLink(mac: PairedMac(endpoint: endpoint, deviceID: "d", deviceName: "iPhone"), outbox: try outbox(), transport: Silent())
        link.attach(model)
        addTeardownBlock { @MainActor in link.stop() }
        let transcripts = model.transcripts
        let queued = transcripts.send("after this", to: "s")
        transcripts.mark(queued.id, in: "s", .queued)
        var state = RemoteState()
        state.queueDrops = ["s": 1]
        link.track(state)
        XCTAssertFalse(transcripts.outgoing["s"]?.contains { $0.id == queued.id } ?? false)
        XCTAssertEqual(transcripts.drafts["s"], "after this")

        let next = transcripts.send("and then", to: "s")
        transcripts.mark(next.id, in: "s", .queued)
        link.track(state)
        XCTAssertTrue(transcripts.outgoing["s"]?.contains { $0.id == next.id } ?? false)
    }
}
