import Foundation
@testable import SideA
import SideAProtocol
import Testing

private func row(_ seq: Int, _ text: String, at: Double, role: TranscriptRole = .user, truncated: Bool = false) -> TranscriptMessage {
    TranscriptMessage(seq: seq, uuid: "u\(seq)", role: role, at: at, text: text, textTruncated: truncated)
}

@Test func theMacNamesTheReplyEachUserRowCameFromAndNeverTwiceForOne() {
    let sent = SentReplies()
    sent.record(conversation: "c", key: "k1", text: "  yes  ", at: 1_000)
    sent.record(conversation: "c", key: "k1:r1", text: "yes", at: 1_001)
    sent.record(conversation: "c", key: "k2", text: "yes", at: 1_010)
    sent.record(conversation: "other", key: "k9", text: "yes", at: 1_000)

    let first = sent.annotate([row(0, "hello", at: 900), row(1, "yes", at: 1_005), row(2, "yes", at: 1_020), row(3, "yes", at: 1_030)], conversation: "c")
    #expect(first.map(\.replyID) == [nil, "k1", "k2", nil], "oldest reply to the oldest row, a retry is its first attempt, a third look-alike is nobody's")
    let again = sent.annotate([row(2, "yes", at: 1_020), row(1, "yes", at: 1_005)], conversation: "c")
    #expect(again.map(\.replyID) == ["k2", "k1"])
}

@Test func aRowBeforeTheSendOrOfAnotherRoleIsNotTheReply() {
    let sent = SentReplies()
    sent.record(conversation: "c", key: "k1", text: "run it", at: 5_000)
    let rows = sent.annotate([row(0, "run it", at: 4_900), row(1, "run it", at: 5_000, role: .assistant), row(2, "run it", at: 4_975)], conversation: "c")
    #expect(rows.map(\.replyID) == [nil, nil, "k1"], "thirty seconds of clock difference is allowed, a hundred is not")
    #expect(SentReplies().annotate([row(0, "x", at: 1)], conversation: "c").first?.replyID == nil)
}

@Test func aLongReplyCutInTheTranscriptStillMatchesByItsStart() {
    let sent = SentReplies()
    let text = String(repeating: "word ", count: 2_000)
    sent.record(conversation: "c", key: "k1", text: text, at: 100)
    let cut = String(text.prefix(6_000)).trimmingCharacters(in: .whitespaces)
    #expect(sent.annotate([row(0, cut, at: 101, truncated: true)], conversation: "c").first?.replyID == "k1")
}
