import Foundation
@testable import SideA
import SideACore
import Testing

/// Requests settled away from the island: the phone, the terminal, or the session moving on.
@MainActor private func requests(_ count: Int, in island: Island) throws -> [Island.Pending.ID] {
    try (0..<count).map { n in
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "agent": "claude", "pid": 960 + n, "slot": "mac", "request": [
            "session_id": "s-settle-\(n)", "tool_name": "Bash", "cwd": "/tmp/app", "tool_input": ["command": "echo \(n)"],
        ]])
        return island.add(try #require(IslandRequest(message: data)), account: nil) { _ in }
    }
}

/// One answered on the phone before the card on screen leaves that card on screen, not the one after it.
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

/// The card on screen answered on the phone: the next one slides in, and a click or ⌃⌥Y aimed at the old card in that
/// moment doesn't allow the new one.
@MainActor @Test func aCardThatSlidInIgnoresTheMacsAnswersForAMoment() throws {
    let island = AccountStore(demo: true).island
    let ids = try requests(2, in: island)
    #expect(island.current?.id == ids[0])
    island.withdraw(ids[0], by: .remote(device: "d1", name: "Pocket"))
    #expect(island.current?.id == ids[1])
    #expect(!island.respond(.allow, nil, quietly: true))
    #expect(!island.respond(.allow, ids[1], quietly: true))
    #expect(island.pending.map(\.id) == [ids[1]])
    // The phone answering it is no stale click.
    #expect(island.respond(.deny(nil), ids[1], quietly: true, by: .remote(device: "d1", name: "Pocket")))
}

/// Answering one on the Mac moves straight on: the next card takes clicks at once.
@MainActor @Test func afterTheMacsOwnAnswerTheNextCardTakesClicks() throws {
    let island = AccountStore(demo: true).island
    let ids = try requests(2, in: island)
    #expect(island.respond(.deny(nil), ids[0], quietly: true))
    #expect(island.respond(.deny(nil), nil, quietly: true))
    #expect(island.pending.isEmpty)
}
