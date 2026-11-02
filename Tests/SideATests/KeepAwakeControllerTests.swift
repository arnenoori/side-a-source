import Foundation
@testable import SideA
import SideACore
import Testing

@MainActor
final class FakeSleep: SleepSystem {
    var working = 0
    var powerState = KeepAwake.Power(onAC: true, battery: 90)
    var held: String?
    var disabled = false
    var owned = false
    var status: HelperStatus = .ready
    var afterRegister: HelperStatus = .needsApproval
    var reachable = true
    var calls: [String] = []
    var lid = false
    var external = false
    var slept = 0

    func workingAgents() -> Int { working }
    func power() -> KeepAwake.Power { powerState }
    func hold(_ reason: String) -> Bool { held = reason; return true }
    func release() { held = nil; calls.append("release") }
    var helper: HelperStatus { status }
    func registerHelper() -> HelperStatus {
        calls.append("register")
        status = afterRegister
        return status
    }
    func unregisterHelper() async {
        calls.append("unregister")
        giveBack()
        status = .off
    }
    func openLoginItems() { calls.append("open login items") }
    func requestLidSleep(_ value: Bool, completion: @escaping @MainActor @Sendable (Bool?) -> Void) {
        calls.append("ask \(value ? 1 : 0)")
        guard reachable, status == .ready else { return completion(nil) }
        if value, !disabled { disabled = true; owned = true }
        if !value { giveBack() }
        completion(disabled)
    }
    func restoreBeforeQuit() {
        calls.append("restore before quit")
        giveBack()
    }
    private func giveBack() {
        if owned { disabled = false; owned = false }
    }
    func lidClosed() -> Bool { lid }
    func externalDisplay() -> Bool { external }
    func sleepNow() { slept += 1 }

    var asks: [String] { calls.filter { $0.hasPrefix("ask") } }
}

@MainActor
private func controller(_ fake: FakeSleep, enabled: Bool = true, lidClosed: Bool = false) -> KeepAwakeController {
    let defaults = temporaryDefaults()
    defaults.set(enabled, forKey: KeepAwakeController.enabledKey)
    defaults.set(lidClosed, forKey: KeepAwakeController.lidClosedKey)
    return KeepAwakeController(system: fake, defaults: defaults)
}

@MainActor @Test func holdsTheAssertionWhileWorkingAndReleasesAfterGrace() {
    let fake = FakeSleep()
    let keepAwake = controller(fake)
    fake.working = 2
    keepAwake.check(now: 1_000)
    #expect(fake.held == "Side A: 2 agents working" && keepAwake.holding)
    fake.working = 0
    keepAwake.check(now: 1_060)
    #expect(fake.held == "Side A: agents paused")
    keepAwake.check(now: 1_000 + KeepAwake.grace)
    #expect(fake.held == nil && !keepAwake.holding && fake.asks.isEmpty)
}

@MainActor @Test func offNeverHoldsAndNeverTouchesSleep() {
    let fake = FakeSleep()
    fake.working = 4
    let keepAwake = controller(fake, enabled: false)
    keepAwake.check(now: 0)
    #expect(fake.held == nil && fake.calls.isEmpty && keepAwake.line == nil)
}

@MainActor @Test func lidClosedAsksTheHelperWhileWorkingAndGivesSleepBackAfterGrace() {
    let fake = FakeSleep()
    let keepAwake = controller(fake, lidClosed: true)
    fake.working = 1
    keepAwake.check(now: 0)
    #expect(fake.disabled && keepAwake.sleepDisabled && keepAwake.line == "Keeping awake · 1 agent working · lid closed OK")
    keepAwake.check(now: 10)
    fake.working = 0
    keepAwake.check(now: 60)
    #expect(fake.disabled)
    keepAwake.check(now: 10 + KeepAwake.grace)
    keepAwake.check(now: 20 + KeepAwake.grace)
    #expect(!fake.disabled && !keepAwake.sleepDisabled)
    #expect(fake.asks == ["ask 1", "ask 1", "ask 1", "ask 0"])
}

@MainActor @Test func nothingIsAskedUntilTheHelperIsApproved() {
    let fake = FakeSleep()
    fake.status = .needsApproval
    fake.working = 1
    let keepAwake = controller(fake, lidClosed: true)
    keepAwake.check(now: 0)
    #expect(fake.asks.isEmpty && !fake.disabled && fake.held != nil && keepAwake.line == "Keeping awake · 1 agent working")
    fake.status = .ready
    keepAwake.refreshHelper()
    #expect(keepAwake.helper == .ready && fake.disabled)
}

@MainActor @Test func turningTheLidOptionOnRegistersTheHelperAndWaitsForApproval() async {
    let fake = FakeSleep()
    fake.status = .off
    fake.working = 1
    let keepAwake = controller(fake)
    await keepAwake.setLidClosed(true)
    #expect(fake.calls.first == "register" && keepAwake.settings.lidClosed && keepAwake.helper == .needsApproval)
    #expect(keepAwake.error == nil && fake.asks.isEmpty)
    keepAwake.openLoginItems()
    #expect(fake.calls.contains("open login items"))
}

@MainActor @Test func aHelperMacOSWontRegisterLeavesTheOptionOff() async {
    for status in [HelperStatus.unavailable, .off] {
        let fake = FakeSleep()
        fake.status = .off
        fake.afterRegister = status
        let keepAwake = controller(fake)
        await keepAwake.setLidClosed(true)
        #expect(!keepAwake.settings.lidClosed && keepAwake.error != nil)
    }
}

@MainActor @Test func turningTheLidOptionOffGivesSleepBackAndUnregisters() async {
    let fake = FakeSleep()
    fake.working = 1
    let keepAwake = controller(fake, lidClosed: true)
    keepAwake.check(now: 0)
    #expect(fake.disabled)
    await keepAwake.setLidClosed(false)
    #expect(Array(fake.calls.filter { $0 == "ask 0" || $0 == "unregister" }) == ["ask 0", "unregister"])
    #expect(!fake.disabled && !keepAwake.settings.lidClosed && keepAwake.helper == .off && !keepAwake.busy)
}

@MainActor @Test func batteryGivesSleepBackUnlessAllowedAndAlwaysBelowTwentyPercent() {
    let fake = FakeSleep()
    let keepAwake = controller(fake, lidClosed: true)
    fake.working = 1
    fake.powerState = KeepAwake.Power(onAC: false, battery: 80)
    keepAwake.check(now: 0)
    #expect(!fake.disabled && fake.held != nil && fake.asks.isEmpty)
    keepAwake.setOnBattery(true)
    #expect(fake.disabled)
    fake.powerState = KeepAwake.Power(onAC: false, battery: 19)
    keepAwake.check(now: 30)
    #expect(!fake.disabled && fake.held != nil)
}

@MainActor @Test func anUnreachableHelperIsReported() {
    let fake = FakeSleep()
    fake.reachable = false
    fake.working = 1
    let keepAwake = controller(fake, lidClosed: true)
    keepAwake.check(now: 0)
    #expect(!keepAwake.sleepDisabled && keepAwake.error != nil && keepAwake.line == "Keeping awake · 1 agent working")
}

@MainActor @Test func theUsersOwnDisabledSleepStaysOff() {
    let fake = FakeSleep()
    fake.disabled = true
    fake.lid = true
    fake.working = 1
    let keepAwake = controller(fake, lidClosed: true)
    keepAwake.check(now: 0)
    fake.working = 0
    keepAwake.check(now: KeepAwake.grace + 1)
    keepAwake.stop()
    #expect(!keepAwake.lidSleepPending && fake.slept == 0)
}

@MainActor @Test func quittingGivesEverythingBack() {
    let fake = FakeSleep()
    fake.working = 3
    let keepAwake = controller(fake, lidClosed: true)
    keepAwake.check(now: 0)
    #expect(fake.disabled && fake.held != nil)
    keepAwake.stop()
    #expect(!fake.disabled && fake.held == nil && !keepAwake.holding && fake.calls.contains("restore before quit"))
    let idle = FakeSleep()
    let never = controller(idle, lidClosed: true)
    never.check(now: 0)
    never.stop()
    #expect(!idle.calls.contains("restore before quit"))
}

@MainActor @Test func anUpdateRelaunchLeavesSleepToTheHelpersHandover() {
    let fake = FakeSleep()
    fake.working = 1
    let old = controller(fake, lidClosed: true)
    old.check(now: 0)
    old.handOff()
    old.stop()
    #expect(fake.disabled && fake.held == nil && !fake.calls.contains("restore before quit"))
    let new = controller(fake, lidClosed: true)
    new.start()
    #expect(fake.disabled && new.sleepDisabled)
    new.stop()
    #expect(!fake.disabled)
}

@MainActor @Test func aClosedLidOnBatteryReleasesTheAssertionAndSleepsAfterSettling() {
    let fake = FakeSleep()
    fake.working = 1
    fake.lid = true
    let keepAwake = controller(fake, lidClosed: true)
    keepAwake.check(now: 0)
    #expect(fake.disabled && fake.held != nil)
    fake.powerState = KeepAwake.Power(onAC: false, battery: 80)
    keepAwake.check(now: 30)
    #expect(!fake.disabled && fake.held == nil && keepAwake.lidSleepPending)
    keepAwake.check(now: 60)
    #expect(fake.held == nil)
    keepAwake.closedLidCheck(elapsed: 3_600, awake: ClosedLid.settle)
    #expect(fake.slept == 0)
    keepAwake.closedLidCheck(elapsed: ClosedLid.settle, awake: ClosedLid.settle)
    #expect(fake.slept == 1)
    fake.powerState = KeepAwake.Power(onAC: true, battery: 80)
    keepAwake.check(now: 90)
    #expect(fake.disabled && fake.held != nil && !keepAwake.lidSleepPending)
    keepAwake.closedLidCheck(elapsed: ClosedLid.settle, awake: ClosedLid.settle)
    #expect(fake.slept == 1)
}

@MainActor @Test func openingTheLidOrAnExternalDisplayKeepsTheMacAwake() async {
    let fake = FakeSleep()
    fake.working = 1
    fake.lid = true
    let keepAwake = controller(fake, lidClosed: true)
    keepAwake.check(now: 0)
    await keepAwake.setLidClosed(false)
    #expect(keepAwake.lidSleepPending && fake.held == nil)
    fake.lid = false
    keepAwake.check(now: 30)
    #expect(!keepAwake.lidSleepPending && fake.held != nil)
    keepAwake.closedLidCheck(elapsed: ClosedLid.settle, awake: ClosedLid.settle)
    #expect(fake.slept == 0)

    let desk = FakeSleep()
    desk.working = 1
    desk.lid = true
    desk.external = true
    let docked = controller(desk, lidClosed: true)
    docked.check(now: 0)
    desk.powerState = KeepAwake.Power(onAC: false, battery: 80)
    docked.check(now: 30)
    #expect(!desk.disabled && !docked.lidSleepPending && desk.held != nil)
    docked.closedLidCheck(elapsed: ClosedLid.settle, awake: ClosedLid.settle)
    #expect(desk.slept == 0)
}

@MainActor @Test func removeSideAGivesSleepBackAndUnregistersTheHelper() async {
    let fake = FakeSleep()
    fake.working = 1
    let keepAwake = controller(fake, lidClosed: true)
    keepAwake.check(now: 0)
    await keepAwake.uninstall()
    #expect(!fake.disabled && fake.held == nil && fake.calls.contains("unregister") && keepAwake.helper == .off)
    let untouched = FakeSleep()
    untouched.status = .off
    await controller(untouched).uninstall()
    #expect(!untouched.calls.contains("unregister"))
}

@MainActor @Test func theDemoChangesNothingOnTheMac() async {
    let defaults = temporaryDefaults()
    let keepAwake = KeepAwakeController(system: nil, defaults: defaults)
    keepAwake.start()
    keepAwake.setEnabled(true)
    await keepAwake.setLidClosed(true)
    keepAwake.check(now: 0)
    #expect(keepAwake.settings.enabled && !keepAwake.settings.lidClosed && keepAwake.error != nil)
    #expect(!defaults.bool(forKey: KeepAwakeController.enabledKey) && keepAwake.line == nil)
}

@Test func helperStatusFollowsServiceManagement() {
    #expect(HelperStatus(.enabled) == .ready)
    #expect(HelperStatus(.requiresApproval) == .needsApproval)
    #expect(HelperStatus(.notRegistered) == .off)
    #expect(HelperStatus(.notFound) == .unavailable)
}
