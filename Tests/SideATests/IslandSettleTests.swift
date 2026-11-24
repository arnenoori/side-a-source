import Foundation
@testable import SideA
import SideACore
import Testing

@MainActor private func requests(_ count: Int, in island: Island) throws -> [Island.Pending.ID] {
    try (0..<count).map { n in
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "agent": "claude", "pid": 960 + n, "slot": "mac", "request": [
            "session_id": "s-settle-\(n)", "tool_name": "Bash", "cwd": "/tmp/app", "tool_input": ["command": "echo \(n)"],
        ]])
        return island.add(try #require(IslandRequest(message: data)), account: nil) { _ in }
    }
}

@MainActor @Test func aRequestSettledElsewhereDoesNotMoveTheCardOnScreen() throws {
    let island = AccountStore(demo: true).island
    let ids = try requests(3, in: island)
    island.step(1)
    #expect(island.current?.id == ids[1])
    island.withdraw(ids[0], by: .remote(device: "d1", name: "Pocket"))
    #expect(island.current?.id == ids[1])
    island.withdraw(ids[2], by: .terminal)
    #expect(island.current?.id == ids[1])
}

@MainActor @Test func aCardThatSlidInIgnoresTheMacsAnswersForAMoment() throws {
    let island = AccountStore(demo: true).island
    let ids = try requests(2, in: island)
    #expect(island.current?.id == ids[0])
    island.withdraw(ids[0], by: .remote(device: "d1", name: "Pocket"))
    #expect(island.current?.id == ids[1])
    #expect(!island.respond(.allow, nil, quietly: true))
    #expect(!island.respond(.allow, ids[1], quietly: true))
    #expect(island.pending.map(\.id) == [ids[1]])
    #expect(island.respond(.deny(nil), ids[1], quietly: true, by: .remote(device: "d1", name: "Pocket")))
}

@MainActor @Test func afterTheMacsOwnAnswerTheNextCardTakesClicks() throws {
    let island = AccountStore(demo: true).island
    let ids = try requests(2, in: island)
    #expect(island.respond(.deny(nil), ids[0], quietly: true))
    #expect(island.respond(.deny(nil), nil, quietly: true))
    #expect(island.pending.isEmpty)
}

@MainActor @Test func controlOptionNOnAPlanKeepsPlanning() throws {
    let island = AccountStore(demo: true).island
    let data = try JSONSerialization.data(withJSONObject: ["v": 1, "agent": "claude", "pid": 970, "slot": "mac", "request": [
        "session_id": "s-plan", "tool_name": "ExitPlanMode", "cwd": "/tmp/app", "tool_input": ["plan": "# Plan\n1. Do it"],
    ]])
    let plan = island.add(try #require(IslandRequest(message: data)), account: nil) { _ in }
    island.deny()
    #expect(island.pending.map(\.id) == [plan] && island.revising == plan)
    island.withdraw(plan, by: .terminal)
    #expect(island.revising == nil)
    let ids = try requests(1, in: island)
    island.deny()
    #expect(!island.pending.contains { $0.id == ids[0] })
}
