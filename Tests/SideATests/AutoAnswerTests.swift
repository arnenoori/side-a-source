import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

/// A demo store keeps its config in memory; requests come in through `add`, so their answers are seen here.
@MainActor
private final class Overnight {
    let store = AccountStore(demo: true)
    var answers: [IslandAnswer] = []
    var island: Island { store.island }

    init(on: Bool = true) { store.setAnswerRecommended(on) }

    func add(_ tool: String, _ input: [String: Any]) throws -> Island.Pending {
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "agent": "claude", "pid": 301, "slot": "mac", "request": [
            "session_id": "s1", "tool_name": tool, "cwd": "/tmp/app", "tool_input": input,
        ]])
        let id = island.add(try #require(IslandRequest(message: data)), account: nil) { [weak self] in self?.answers.append($0) }
        return try #require(island.pending.first { $0.id == id })
    }

    func question(_ options: [String]) throws -> Island.Pending {
        try add("AskUserQuestion", ["questions": [["question": "Which database?", "multiSelect": false, "options": options.map { ["label": $0] }]]])
    }
}

@MainActor @Test func aRecommendedChoiceIsSentAfterAMinuteAndMarkedAsSo() throws {
    let scene = Overnight()
    let item = try scene.question(["SQLite", "Postgres (Recommended)"])
    #expect(scene.island.autoAnswerAt[item.id] == item.arrived.addingTimeInterval(60))

    scene.island.answerDue(now: item.arrived.addingTimeInterval(59))
    #expect(scene.answers.isEmpty && scene.island.pending.count == 1)
    scene.island.answerDue(now: item.arrived.addingTimeInterval(60))
    #expect(scene.answers == [.answers(["Which database?": "Postgres (Recommended)" + IslandRequest.autoAnswerNote], input: item.request.input)])
    #expect(scene.island.pending.isEmpty && scene.island.resolved[item.id]?.by == .auto)

    let wire = Island.resolution(item.id, .auto, scene.answers.first, at: Date())
    #expect(wire.by == .autoAnswered && wire.answer == .answers)
    // The phone's Autopilot list reads it back from the log line.
    let decision = try #require(Autopilot.decision("Auto-answered in app: Which database? Postgres (Recommended)", at: 1))
    #expect(decision.kind == .answered && decision.title == "Answered for you in app" && decision.reason == "Which database? Postgres (Recommended)")
}

/// An auto-answer settles through the same path as any other: the card that slides in under the pointer ignores a
/// Mac click for a moment.
@MainActor @Test func anAutoAnswerGuardsTheCardThatTakesItsPlace() throws {
    let scene = Overnight()
    let item = try scene.question(["Postgres (Recommended)"])
    let next = try scene.add("Bash", ["command": "ls"])
    #expect(scene.island.current?.id == item.id)
    scene.island.answerDue(now: item.arrived.addingTimeInterval(60))
    #expect(scene.island.current?.id == next.id && scene.island.arrived?.id == next.id)
    #expect(!scene.island.respond(.allow, next.id, quietly: true, by: .mac) && scene.island.pending.count == 1)
}

@MainActor @Test func aPlanIsNeverApprovedByItself() throws {
    let scene = Overnight()
    let item = try scene.add("ExitPlanMode", ["plan": "# Ship it"])
    #expect(scene.island.autoAnswerAt[item.id] == nil)
    scene.island.answerDue(now: item.arrived.addingTimeInterval(60))
    #expect(scene.answers.isEmpty && scene.island.pending.count == 1)
}

@MainActor @Test func anAnswerFromAnywhereElseCancelsTheTimer() throws {
    let scene = Overnight()
    let item = try scene.question(["SQLite", "Postgres (Recommended)"])
    scene.island.answer(.answers(["Which database?": "SQLite"], input: item.request.input), item.id, quietly: true)
    #expect(scene.island.autoAnswerAt.isEmpty)
    scene.island.answerDue(now: item.arrived.addingTimeInterval(61))
    #expect(scene.answers == [.answers(["Which database?": "SQLite"], input: item.request.input)])
    #expect(scene.island.resolved[item.id]?.by == .mac)
}

@MainActor @Test func nothingIsSentWithoutARecommendationForPermissionsOrWhileOff() throws {
    let scene = Overnight()
    let unmarked = try scene.question(["SQLite", "Postgres"])
    let bash = try scene.add("Bash", ["command": "ls"])
    #expect(scene.island.autoAnswerAt.isEmpty)
    scene.island.answerDue(now: Date().addingTimeInterval(600))
    #expect(scene.answers.isEmpty && Set(scene.island.pending.map(\.id)) == [unmarked.id, bash.id])

    let off = Overnight(on: false)
    let item = try off.question(["Postgres (Recommended)"])
    off.island.answerDue(now: item.arrived.addingTimeInterval(600))
    #expect(off.answers.isEmpty)
    // Turning it on gives a waiting request its minute from then, not at once.
    off.store.setAnswerRecommended(true)
    let armed = try #require(off.island.autoAnswerAt[item.id])
    #expect(armed.timeIntervalSinceNow > 59)
    off.store.setAnswerRecommended(false)
    #expect(off.island.autoAnswerAt.isEmpty)
}

/// The timer itself, shortened: it wakes and answers without anyone calling `answerDue`.
@MainActor @Test func theTimerFiresByItself() async throws {
    let scene = Overnight()
    scene.island.autoAnswerAfter = 0.05
    _ = try scene.question(["Postgres (Recommended)"])
    #expect(scene.answers.isEmpty)
    for _ in 0..<200 where scene.answers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(scene.answers.count == 1 && scene.island.pending.isEmpty)
}
