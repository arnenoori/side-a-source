import Foundation
@testable import SideA
import SideACore
import Testing

@MainActor private func finishedIsland() throws -> Island {
    let island = AccountStore(demo: true).island
    island.keepsFinished = { true }
    let message = try JSONSerialization.data(withJSONObject: ["v": 1, "agent": "claude", "slot": "mac", "wait": false, "request": [
        "hook_event_name": "Stop", "session_id": "s-hover", "cwd": "/tmp/app", "last_assistant_message": "done",
    ]])
    island.finished(try #require(IslandFinish(message: message)))
    #expect(island.ready.count == 1 && !island.expanded)
    return island
}

@MainActor @Test func theFoldedNotchOpensOnlyOnceThePointerRests() throws {
    let island = try finishedIsland()
    let now = Date()
    island.hover(true, now: now)
    island.tick(now: now.addingTimeInterval(0.1))
    #expect(!island.expanded)
    island.tick(now: now.addingTimeInterval(IslandTimers.hoverIntent))
    #expect(island.expanded)
}

@MainActor @Test func aPointerThatLeavesBeforeTheIntentDelayDoesNotOpenIt() throws {
    let island = try finishedIsland()
    let now = Date()
    island.hover(true, now: now)
    island.hover(false, now: now.addingTimeInterval(0.1))
    island.tick(now: now.addingTimeInterval(1))
    #expect(!island.expanded)
}

@MainActor @Test func theReadyListWaitsBeforeFoldingAndStaysIfThePointerComesBack() throws {
    let island = try finishedIsland()
    let now = Date()
    island.expand()
    island.hover(true, now: now)
    island.hover(false, now: now)
    island.tick(now: now.addingTimeInterval(0.2))
    #expect(island.expanded)
    island.hover(true, now: now.addingTimeInterval(0.25))
    island.tick(now: now.addingTimeInterval(1))
    #expect(island.expanded)
    island.hover(false, now: now.addingTimeInterval(2))
    island.tick(now: now.addingTimeInterval(2 + IslandTimers.collapseGrace))
    #expect(!island.expanded)
}

@Test func anEventWaitsOutTheHoverAndKeepsAtLeastTwoSecondsAfter() {
    var timers = IslandTimers()
    let now = Date()
    timers.showEvent(for: 5, now: now, hovered: false)
    timers.entered(expands: false, now: now.addingTimeInterval(4))
    #expect(timers.due(now: now.addingTimeInterval(30)).isEmpty)
    timers.left(collapses: false, now: now.addingTimeInterval(30))
    #expect(timers.due(now: now.addingTimeInterval(31.9)).isEmpty)
    #expect(timers.due(now: now.addingTimeInterval(32)) == [.dismissEvent])

    timers.showEvent(for: 8, now: now, hovered: false)
    timers.entered(expands: false, now: now.addingTimeInterval(1))
    timers.left(collapses: false, now: now.addingTimeInterval(10))
    #expect(timers.due(now: now.addingTimeInterval(16.9)).isEmpty)
    #expect(timers.due(now: now.addingTimeInterval(17)) == [.dismissEvent])
}

@Test func anEventShownUnderThePointerStartsOnlyOnceItLeaves() {
    var timers = IslandTimers()
    let now = Date()
    timers.entered(expands: false, now: now)
    timers.showEvent(for: 5, now: now, hovered: true)
    #expect(timers.next == nil)
    timers.left(collapses: false, now: now.addingTimeInterval(60))
    #expect(timers.next == now.addingTimeInterval(65))
    timers.clearEvent()
    #expect(timers.next == nil)
}
