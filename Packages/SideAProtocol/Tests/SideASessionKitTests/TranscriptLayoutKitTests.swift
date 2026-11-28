import Foundation
import SideAProtocol
@testable import SideASessionKit
import Testing

/// The layout with the plainest records an app could have, as the Mac uses it before it has outgoing bubbles.
private struct Sent: OutgoingTurn {
    let id: String
    let at: Date
    var isPendingNote = false
    var waits = false
}

private struct Answer: Hashable, Identifiable { let id: String }

private typealias Layout = TranscriptLayout<Answer, Sent>

private func tool(_ id: String, _ name: String = "Bash", status: TranscriptTool.Status = .ok, at: Double? = nil, ended: Double? = nil) -> TranscriptTool {
    TranscriptTool(id: id, name: name, summary: name, status: status, startedAt: at, endedAt: ended)
}

private func message(_ seq: Int, _ role: TranscriptRole, _ text: String = "", at: Double? = nil, tools: [TranscriptTool] = []) -> TranscriptMessage {
    TranscriptMessage(seq: seq, uuid: "u\(seq)", role: role, at: at, text: text, tools: tools)
}

@Test func aShortRunOfStepsStaysFlatAndALongOneFoldsIntoAGroup() {
    let three = Layout.items(messages: [message(1, .user, "go"), message(2, .tools, tools: [tool("a"), tool("b"), tool("c")])], earlier: 0, working: true)
    #expect(three.map(\.id) == ["m-1", "t-a", "t-b", "t-c"])
    let four = Layout.items(messages: [message(1, .user, "go"), message(2, .tools, tools: [tool("a", at: 10, ended: 12), tool("b"), tool("c"), tool("d", at: 70, ended: 75)])],
                            earlier: 0, working: true)
    #expect(four.map(\.id) == ["m-1", "g-a"])
    guard case .group(let group) = four[1] else { return #expect(Bool(false)) }
    #expect(group.tools.count == 4 && group.title == "Worked for 1m 5s · 4 steps" && !group.running)
    // The group keeps the id of its first step, so a fourth step arriving changes what the row is, not which row.
    #expect(TranscriptRules.flatRun == 3)
}

@Test func aTurnEndsWithItsLastReplyOnceTheSessionIsNoLongerWorking() {
    let messages = [message(1, .user, "go", at: 100), message(2, .assistant, "partway", at: 110), message(3, .assistant, "done", at: 160)]
    #expect(Layout.items(messages: messages, earlier: 0, working: true).endedTurns.isEmpty)
    let settled = Layout.items(messages: messages, earlier: 2, working: false)
    #expect(settled.map(\.id) == ["earlier", "m-1", "m-2", "m-3", "end-3"] && settled.endedTurns == [3])
    guard case .turnEnd(let end) = settled[4] else { return #expect(Bool(false)) }
    #expect(end.duration == 60)
}

@Test func theAppsOwnSentMessagesFallWhereTheyWereSent() {
    let messages = [message(1, .user, "first", at: 100), message(2, .assistant, "reply", at: 200)]
    let items = Layout.items(messages: messages, earlier: 0, working: true, outgoing: [Sent(id: "late", at: Date(timeIntervalSince1970: 300)), Sent(id: "mid", at: Date(timeIntervalSince1970: 150))])
    // The one sent after the reply starts the next turn, so the turn before it has ended; one that waits ends nothing.
    #expect(items.map(\.id) == ["m-1", "o-mid", "m-2", "end-2", "o-late"])
    let queued = Layout.items(messages: messages, earlier: 0, working: true, outgoing: [Sent(id: "late", at: Date(timeIntervalSince1970: 300), waits: true)])
    #expect(queued.map(\.id) == ["m-1", "m-2", "o-late"])
    #expect(Layout.items(messages: [], earlier: 0, answered: [Answer(id: "r1")]).map(\.id) == ["a-r1"])
}

@Test func rowsKeepEachMessageWithTheStepsThatFollowIt() {
    let items = Layout.items(messages: [message(1, .user, "go"), message(2, .tools, tools: [tool("a"), tool("b")]), message(3, .assistant, "done")], earlier: 0)
    let rows = Layout.rows(items)
    #expect(rows.map(\.id) == ["m-1", "m-3"] && rows[0].items.count == 3 && rows[1].items.map(\.id) == ["m-3", "end-3"])
}

@Test func aFinishedTurnsWorkFoldsBehindOneLineAndItsAnswerStaysOut() {
    let messages = [message(1, .user, "go", at: 100), message(2, .tools, at: 101, tools: [tool("a"), tool("b")]), message(3, .assistant, "done", at: 220)]
    let items = Layout.items(messages: messages, earlier: 0, working: false)
    let folded = Layout.folded(items, working: false, since: nil)
    #expect(folded.map(\.id) == ["m-1", "fold-m-1", "m-3", "end-3"])
    guard case .turn(let fold) = folded[1] else { return #expect(Bool(false)) }
    #expect(fold.items.map(\.id) == ["t-a", "t-b"] && fold.duration == 120 && !fold.live && !fold.holds(message: 3))
    // While it works, the fold is live and has no length yet.
    let live = Layout.folded(Layout.items(messages: Array(messages.prefix(2)), earlier: 0, working: true), working: true, since: Date(timeIntervalSince1970: 100))
    guard case .turn(let running) = live.last else { return #expect(Bool(false)) }
    #expect(running.live && running.duration == nil && running.started == Date(timeIntervalSince1970: 100))
}

@Test func aStepReadsAsOneShortSentence() {
    func label(_ name: String, _ action: IslandAction, status: TranscriptTool.Status = .ok) -> String {
        ToolLabel(TranscriptTool(id: "t", name: name, summary: "", action: action, status: status)).accessibilityText
    }
    #expect(label("Bash", .command("swift test")) == "Ran swift test")
    #expect(label("Bash", .command("swift test"), status: .running) == "Running swift test")
    #expect(label("Read", .read(path: "/r/app/Sources/Store.swift")) == "Read Store.swift")
    #expect(label("Glob", .search("**/*.swift")) == "Listed **/*.swift")
    #expect(ToolLabel(TranscriptTool(id: "t", name: "TodoWrite", summary: "", status: .ok)).accessibilityText == "Updated the plan")
    #expect(TranscriptTool(id: "t", name: "Bash", summary: "", status: .ok, startedAt: 10, endedAt: 12.5).duration == 2.5)
    #expect(SessionFormat.duration(0.4) == nil && SessionFormat.duration(0.4, exact: true) == "0.4s" && SessionFormat.duration(72) == "1m 12s" && SessionFormat.duration(3700) == "1h 1m")
}
