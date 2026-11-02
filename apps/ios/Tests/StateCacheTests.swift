import SideAProtocol
import SideARemoteKit
import XCTest
@testable import SideARemote

@MainActor
final class StateCacheTests: XCTestCase {
    private func session(_ id: String, at: Timestamp) -> RemoteSession {
        RemoteSession(id: id, agent: .claude, title: id, project: "side-a", status: .working, statusAt: at)
    }

    private func messages(_ range: Range<Int>) -> [TranscriptMessage] {
        range.map { TranscriptMessage(seq: $0, uuid: "\($0)", role: .assistant, at: 0, text: "m\($0)") }
    }

    private func model() -> AppModel {
        AppModel(mac: MacConnection(name: "Mac", state: .connecting, lastSeen: .now), sessions: SessionsStore([]),
                 requests: RequestsStore([]), transcripts: TranscriptStore([:]), accounts: AccountsStore([]),
                 history: HistoryStore([]), isDemo: false, paired: true)
    }

    func testKeepsTheNewestPageOfTheMostRecentSessions() throws {
        let live = model()
        let sessions = (0..<20).map { session("s\($0)", at: Timestamp($0)) }
        live.sessions.replace(sessions, finished: [:])
        for session in sessions { live.transcripts.set(messages(0..<100), hasEarlier: false, for: session.id) }
        let cache = live.cache(finished: [:])
        XCTAssertEqual(cache.transcripts.count, StateCache.keptTranscripts)
        XCTAssertNotNil(cache.transcripts["s19"])
        XCTAssertNil(cache.transcripts["s0"])
        XCTAssertEqual(cache.transcripts["s19"]?.map(\.seq), Array(40..<100))

        let decoded = try JSONDecoder().decode(StateCache.self, from: JSONEncoder().encode(cache))
        let restored = model()
        restored.restore(decoded)
        XCTAssertEqual(restored.sessions.sessions.count, 20)
        XCTAssertEqual(restored.transcripts.messages["s19"]?.first?.seq, 40)
        // The trimmed part reads as earlier messages, as a page from the Mac would.
        XCTAssertEqual(restored.transcripts.earlier["s19"], 40)
        XCTAssertTrue(restored.requests.open.isEmpty)
    }
}
