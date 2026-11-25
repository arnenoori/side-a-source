import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import XCTest
@testable import SideARemote

/// One message is one row. The Mac names the reply a user row came from (`replyID`, the reply's Idempotency-Key), and the phone's own
/// bubble leaves when that row arrives, whichever way the words reached the agent and whatever stage the bubble was in.
@MainActor
final class TranscriptEchoTests: XCTestCase {
    private func row(_ seq: Int, _ text: String, reply: String? = nil, at: Double) -> TranscriptMessage {
        TranscriptMessage(seq: seq, uuid: "u\(seq)", role: .user, at: at, text: text, replyID: reply)
    }

    private func reply(_ store: TranscriptStore, _ text: String, key: String, at: Date) -> TranscriptStore.Outgoing {
        let turn = store.send(text, to: "s", at: at)
        store.bind(turn.id, item: key, in: "s")
        return turn
    }

    /// (a) Delivered mid-turn through a Stop hook: the bubble was read from the mail, and the transcript's row carries the hook's
    /// own wording, so no words match.
    func testAHookDeliveredNoteSettlesByIdWhateverTheTranscriptSays() {
        let store = TranscriptStore([:])
        let now = Date()
        let turn = reply(store, "run the tests again", key: "k1", at: now)
        store.mark(turn.id, in: "s", .note)
        store.set([row(0, "The user sent you this from Side A: run the tests again (queued at 10:02)", reply: "k1", at: now.timeIntervalSince1970 + 120)],
                  hasEarlier: false, for: "s")
        XCTAssertTrue(store.outgoing["s"]?.isEmpty ?? true, "the bubble left; the transcript's row is the one message")
    }

    /// (b) Sent while the phone was offline: still sending when the Mac's row arrives, before the flight's own answer.
    func testAMessageQueuedOfflineSettlesWhenItsRowArrivesBeforeTheAnswer() {
        let store = TranscriptStore([:])
        let now = Date()
        let turn = reply(store, "yes", key: "k2", at: now)
        XCTAssertEqual(turn.state, .sending)
        store.set([row(0, "yes", reply: "k2", at: now.timeIntervalSince1970 + 5)], hasEarlier: false, for: "s")
        XCTAssertTrue(store.outgoing["s"]?.isEmpty ?? true)
        // The flight's own answer arrives later and finds nothing to move.
        store.mark(turn.id, in: "s", .sent)
        XCTAssertTrue(store.outgoing["s"]?.isEmpty ?? true)
    }

    /// (c) The window is replaced while the reply is in flight, and the same words were said before: only the named row is the reply's.
    func testARefetchedWindowNeverGivesAReplyTwoRowsOrTakesALookAlike() {
        let store = TranscriptStore([:])
        let now = Date()
        let older = row(0, "yes", at: now.timeIntervalSince1970 - 10)
        store.set([older], hasEarlier: false, for: "s")
        let turn = reply(store, "yes", key: "k3", at: now)
        store.mark(turn.id, in: "s", .sent)
        // A look-alike without an id, after the send: it is not named, so it settles by words as before; one bubble, one row.
        store.set([older, row(1, "yes", at: now.timeIntervalSince1970 + 1)], hasEarlier: false, for: "s")
        XCTAssertTrue(store.outgoing["s"]?.isEmpty ?? true)
        // A second reply with the same words: the Mac named the row for the first, so it cannot settle the second.
        let second = reply(store, "yes", key: "k4", at: now.addingTimeInterval(60))
        store.mark(second.id, in: "s", .sent)
        store.set([older, row(1, "yes", reply: "k3", at: now.timeIntervalSince1970 + 1)], hasEarlier: false, for: "s")
        XCTAssertEqual(store.outgoing["s"]?.map(\.id), [second.id], "a row named for another reply is not this one's")
        store.set([older, row(1, "yes", reply: "k3", at: now.timeIntervalSince1970 + 1), row(2, "yes", reply: "k4", at: now.timeIntervalSince1970 + 61)],
                  hasEarlier: false, for: "s")
        XCTAssertTrue(store.outgoing["s"]?.isEmpty ?? true)
    }
}
