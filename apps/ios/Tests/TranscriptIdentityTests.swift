import SideAProtocol
import SideARemoteShared
import XCTest
@testable import SideARemote

/// Rows already on screen keep their ids when a window grows or is refreshed: the scroll view keeps its place by id, so a row
/// that gets a new one (or leaves and returns) blanks the screenful the reader was on.
@MainActor
final class TranscriptIdentityTests: XCTestCase {
    private func rows(_ seqs: ClosedRange<Int>) -> [TranscriptMessage] {
        seqs.map { TranscriptMessage(seq: $0, uuid: "u\($0)", role: $0.isMultiple(of: 2) ? .user : .assistant, at: Double($0), text: "message \($0)") }
    }

    private func ids(_ store: TranscriptStore) -> [String] {
        TranscriptLayout.items(messages: store.messages["s"] ?? [], earlier: store.earlier["s"] ?? 0).map(\.id)
    }

    func testRefreshingAWindowChangesNothingOnScreen() {
        let store = TranscriptStore([:])
        store.set(rows(40...59), hasEarlier: true, for: "s")
        let shown = ids(store)
        // The same window again, as a reconnect that finds nothing new delivers it.
        store.set(rows(40...59), hasEarlier: true, for: "s")
        XCTAssertEqual(ids(store), shown)
    }

    func testRowsAddedAtEitherEndLeaveTheHeldOnesAsTheyWere() {
        let store = TranscriptStore([:])
        store.set(rows(40...59), hasEarlier: true, for: "s")
        let shown = ids(store).filter { $0.hasPrefix("m-") }
        store.set(rows(30...63), hasEarlier: true, for: "s")
        let grown = ids(store).filter { $0.hasPrefix("m-") }
        XCTAssertEqual(grown.dropFirst(10).prefix(shown.count).map { $0 }, shown, "the rows held are one unbroken run, in order, under the same ids")
        XCTAssertEqual(Set(grown).count, grown.count, "no id twice")
    }
}
