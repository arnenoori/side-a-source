import Foundation
@testable import SideA
import SideAProtocol
import SideASessionKit
import Testing

private func message(_ seq: Int, _ role: TranscriptRole, _ text: String? = nil, tools: [TranscriptTool] = [], inherited: Bool = false) -> TranscriptMessage {
    TranscriptMessage(seq: seq, uuid: "u\(seq)", role: role, at: Double(seq), inherited: inherited, text: text, tools: tools)
}

private func page(_ messages: [TranscriptMessage], generation: String = "g1", before: String? = nil) -> TranscriptPage {
    let object: [String: Any?] = [
        "sessionID": "claude-s1", "generation": generation, "messages": [], "replaced": [], "before": before, "after": "a", "hasMoreAfter": false,
        "count": messages.count, "inheritedBefore": 0, "reset": false,
    ]
    // Built through its decoder, as the bridge's reply is, then given the messages.
    let data = try! JSONSerialization.data(withJSONObject: object.compactMapValues { $0 }) // swiftlint:disable:this force_try
    var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any] // swiftlint:disable:this force_try force_cast
    json["messages"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(messages)) // swiftlint:disable:this force_try
    return try! JSONDecoder().decode(TranscriptPage.self, from: JSONSerialization.data(withJSONObject: json)) // swiftlint:disable:this force_try
}

@Test func theMacsWindowKeepsWordsForItsMessageViewAndStepsForTheLayout() {
    let run = TranscriptTool(id: "t1", name: "Bash", summary: "swift test", action: .command("swift test"), status: .failed, startedAt: 2, endedAt: 9, output: "1 failure")
    let window = WireWindow(page([message(1, .user, "fix it"), message(2, .thinking, "hm"), message(3, .tools, tools: [run]), message(4, .assistant, "Done.\n\n```swift\nlet a = 1\n```"),
                                  message(5, .compact, "Compacted")]))
    // Words are laid out once, off the main thread, in the shape the Mac's message view already draws.
    #expect(window.prepared.keys.sorted() == [1, 4, 5])
    #expect(window.prepared[1]?.role == "user" && window.prepared[1]?.text == "fix it" && window.prepared[1]?.key == "w1")
    #expect(window.prepared[4]?.segments.map(\.kind) == [.prose, .code] && window.prepared[5]?.role == "compact")
    // Steps and thinking are the layout's, with what the old view dropped: status, time and output.
    let items = MacLayout.items(messages: window.messages, earlier: 0, working: false)
    #expect(items.map(\.id) == ["m-1", "t-thinking-2", "t-t1", "m-4", "m-5", "end-4"], "\(items.map(\.id))")
    guard case .tool(let step) = items[2] else { return #expect(Bool(false)) }
    #expect(step.status == .failed && step.duration == 7 && step.output == "1 failure" && ToolLabel(step).accessibilityText == "Ran swift test")
    #expect(WireWindow.classic(.tools) == nil && WireWindow.classic(.thinking) == nil && WireWindow.classic(.error) == "error")
}

@Test func anEarlierPageJoinsTheFrontOnce() {
    var window = WireWindow(page([message(5, .user, "later"), message(6, .assistant, "reply")], before: "c5"))
    #expect(window.before?.raw == "c5")
    window.prepend(page([message(3, .user, "earlier"), message(4, .assistant, "ok"), message(5, .user, "later")], before: "c3"))
    #expect(window.messages.map(\.seq) == [3, 4, 5, 6] && window.before?.raw == "c3" && window.prepared[3]?.text == "earlier")
    // The start of the conversation: nothing is before it.
    window.prepend(page([message(1, .user, "first")]))
    #expect(window.messages.map(\.seq) == [1, 3, 4, 5, 6] && window.before == nil)
    // A page of a rebuilt transcript doesn't belong to this window.
    window.prepend(page([message(0, .user, "other")], generation: "g2", before: "x"))
    #expect(window.messages.map(\.seq) == [1, 3, 4, 5, 6] && window.before == nil)
}

@MainActor @Test func theWindowsKeptAreTheOnesOpenedLast() {
    let desk = SessionDesk(prefs: SessionPrefs(defaults: temporaryDefaults()))
    for index in 0..<(SessionDesk.wireKept + 3) {
        desk.wire["c\(index)"] = WireWindow(page([message(1, .user, "hi")]))
        desk.keepWire("c\(index)")
    }
    desk.keepWire("c3")
    desk.wire["new"] = WireWindow(page([message(1, .user, "hi")]))
    desk.keepWire("new")
    #expect(desk.wire.count == SessionDesk.wireKept && desk.wire["c0"] == nil && desk.wire["c3"] != nil && desk.wire["c4"] == nil && desk.wire["new"] != nil)
}
