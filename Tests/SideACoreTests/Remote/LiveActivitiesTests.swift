import Foundation
@testable import SideACore
import SideAProtocol
import Testing

private let phone = [LiveActivities.Device(id: "p", wanted: true, canStart: true)]
private func state(_ working: Int, _ waiting: Int, top: String? = nil) -> ActivityContentState {
    ActivityContentState(working: working, waiting: waiting, topRequest: top)
}

@Test func anActivityStartsWhenWorkBeginsUpdatesOnChangesAndEndsAfterAQuarterHourIdle() {
    var live = LiveActivities()
    #expect(live.changed(state(0, 0), devices: phone, now: 0).isEmpty)
    #expect(live.changed(state(1, 0), devices: phone, now: 10) == [.start(device: "p")])
    // Not reported yet: no second start within the minute.
    #expect(live.changed(state(2, 0), devices: phone, now: 20).isEmpty)
    _ = live.reported("p", activities: ["a1"], now: 30)
    #expect(live.changed(state(1, 1, top: "r1"), devices: phone, now: 40) == [.update(device: "p", activity: "a1", priority: 10)])
    // r1 settled and r2 took its place: high priority, so r1's Allow and Deny don't linger.
    #expect(live.changed(state(1, 1, top: "r2"), devices: phone, now: 50) == [.update(device: "p", activity: "a1", priority: 10)])
    #expect(live.changed(state(1, 1, top: "r2"), devices: phone, now: 60).isEmpty)
    // Only the working count moved: that can wait.
    #expect(live.changed(state(2, 1, top: "r2"), devices: phone, now: 70) == [.update(device: "p", activity: "a1", priority: 5)])
    // The last request settled.
    #expect(live.changed(state(0, 0), devices: phone, now: 100) == [.update(device: "p", activity: "a1", priority: 10)])
    #expect(live.changed(state(0, 0), devices: phone, now: 100 + 899).isEmpty)
    #expect(live.changed(state(0, 0), devices: phone, now: 100 + 900) == [.end(device: "p", activity: "a1")])
    #expect(!live.active)
}

@Test func anOldActivityIsReplacedAndASwipedOneStaysGoneUntilTheNextBusySpell() {
    var live = LiveActivities()
    _ = live.changed(state(1, 0), devices: phone, now: 0)
    _ = live.reported("p", activities: ["a1"], now: 1)
    #expect(live.changed(state(2, 0), devices: phone, now: LiveActivities.lifetime) == [.end(device: "p", activity: "a1"), .start(device: "p")])
    #expect(live.reported("p", activities: ["a1", "a2"], now: LiveActivities.lifetime + 1).isEmpty)
    #expect(live.changed(state(2, 1), devices: phone, now: LiveActivities.lifetime + 1) == [.update(device: "p", activity: "a2", priority: 10)])
    // Swiped away: the phone stops listing it.
    _ = live.reported("p", activities: [], now: LiveActivities.lifetime + 2)
    #expect(live.changed(state(3, 0), devices: phone, now: LiveActivities.lifetime + 3).isEmpty)
    _ = live.changed(state(0, 0), devices: phone, now: LiveActivities.lifetime + 4)
    #expect(live.changed(state(1, 0), devices: phone, now: LiveActivities.lifetime + 5) == [.start(device: "p")])
    // Turned off, or no push-to-start token: nothing.
    var off = LiveActivities()
    #expect(off.changed(state(1, 0), devices: [.init(id: "p", wanted: false, canStart: true), .init(id: "q", wanted: true, canStart: false)], now: 0).isEmpty)
}

private let off = [LiveActivities.Device(id: "p", wanted: false, canStart: true)]

@Test func turningLiveActivitiesOffEndsTheCardOnThePhone() {
    var live = LiveActivities()
    _ = live.changed(state(1, 1, top: "r1"), devices: phone, now: 0)
    _ = live.reported("p", activities: ["a1"], now: 1)
    #expect(live.changed(state(1, 1, top: "r1"), devices: off, now: 2) == [.end(device: "p", activity: "a1")])
    #expect(!live.active)
    // Off stays off, and turning it back on starts again.
    #expect(live.changed(state(1, 1, top: "r2"), devices: off, now: 3).isEmpty)
    #expect(live.changed(state(1, 1, top: "r2"), devices: phone, now: 4) == [.start(device: "p")])
}

@Test func aStartReportedAfterTurningOffStillEnds() {
    var live = LiveActivities()
    _ = live.changed(state(1, 0), devices: phone, now: 0)
    #expect(live.changed(state(1, 0), devices: off, now: 1).isEmpty)
    #expect(live.reported("p", activities: ["a1"], now: 2).isEmpty)
    #expect(live.changed(state(1, 0), devices: off, now: 3) == [.end(device: "p", activity: "a1")])
}

@Test func aStartThatIsNeverReportedStopsRetrying() {
    var live = LiveActivities()
    var starts = 0
    for minute in 0..<30 {
        starts += live.changed(state(1, 0), devices: phone, now: Double(minute) * LiveActivities.startWait).count
    }
    #expect(starts == LiveActivities.maxStarts)
    #expect(!live.active)
    // The next busy spell tries again.
    _ = live.changed(state(0, 0), devices: phone, now: 4000)
    #expect(live.changed(state(1, 0), devices: phone, now: 4001) == [.start(device: "p")])
    // An idle Mac stops waiting for a start, so the ticker can stop.
    #expect(live.active)
    _ = live.changed(state(0, 0), devices: phone, now: 4001 + LiveActivities.startWait)
    #expect(!live.active)
}

@Test func onlyOneOfSeveralReportedActivitiesIsKeptAndTheRestEnd() {
    var live = LiveActivities()
    _ = live.changed(state(1, 0), devices: phone, now: 0)
    #expect(live.reported("p", activities: ["a2", "a1", "a3"], now: 1) == [.end(device: "p", activity: "a2"), .end(device: "p", activity: "a3")])
    #expect(live.changed(state(2, 0), devices: phone, now: 2) == [.update(device: "p", activity: "a1", priority: 5)])
    // Still listed while they end: not ended twice. A latecomer is.
    #expect(live.reported("p", activities: ["a1", "a2", "a3"], now: 3).isEmpty)
    #expect(live.reported("p", activities: ["a1", "a4"], now: 4) == [.end(device: "p", activity: "a4")])
}
