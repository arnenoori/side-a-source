import Foundation
import Security
import SideAKeepAwakeCore
import Testing

@Test func pmsetShowsSleepDisabledOnlyWhileSet() {
    #expect(KeepAwakeHelper.sleepDisabled(pmsetOutput: "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n"))
    #expect(!KeepAwakeHelper.sleepDisabled(pmsetOutput: "System-wide power settings:\n SleepDisabled\t\t0\n"))
    #expect(!KeepAwakeHelper.sleepDisabled(pmsetOutput: "System-wide power settings:\nCurrently in use:\n standby 1\n sleep 1 (sleep prevented by caffeinate)\n"))
    #expect(KeepAwakeHelper.command(true) == ["-a", "disablesleep", "1"] && KeepAwakeHelper.command(false) == ["-a", "disablesleep", "0"])
}

private func compiles(_ requirement: String) -> Bool {
    var compiled: SecRequirement?
    return SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess && compiled != nil
}

@Test func onlySideASignedByTheHelpersOwnTeamMayCall() throws {
    let client = try #require(KeepAwakeHelper.clientRequirement(team: "ABCDE12345"))
    #expect(client == #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345" and (identifier "com.arnenoori.sidea" or identifier "com.arnenoori.sidea.dev")"#)
    let helper = try #require(KeepAwakeHelper.helperRequirement(team: "ABCDE12345"))
    #expect(helper == #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and identifier "com.sidea.keepawake""#)
    #expect(compiles(client) && compiles(helper))
    for team in [nil, "", "abcde12345", "ABCDE1234", "ABCDE123456", #"ABCDE"1234"#, "ABCDE 1234"] as [String?] {
        #expect(KeepAwakeHelper.clientRequirement(team: team) == nil, "\(team ?? "nil")")
        #expect(KeepAwakeHelper.helperRequirement(team: team) == nil)
    }
}

@Test func theBundledDaemonRunsTheHelperForSideAOnly() throws {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../scripts/" + KeepAwakeHelper.plistName)
    let plist = try #require(NSDictionary(contentsOf: source) as? [String: Any])
    #expect(Set(plist.keys) == ["Label", "BundleProgram", "MachServices", "AssociatedBundleIdentifiers", "RunAtLoad", "KeepAlive"])
    #expect(plist["Label"] as? String == KeepAwakeHelper.label)
    #expect(plist["BundleProgram"] as? String == "Contents/MacOS/SideAKeepAwake")
    #expect(plist["MachServices"] as? [String: Bool] == [KeepAwakeHelper.label: true])
    #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["com.arnenoori.sidea"])
    #expect(plist["RunAtLoad"] as? Bool == true)
    let keepAlive = plist["KeepAlive"] as? [String: [String: Bool]]
    #expect(keepAlive == ["PathState": [KeepAwakeHelper.stateFile: true]], "relaunched while it owns sleep, even after a crash")
}

@Test func sleepGoesOffOnlyWhileAConnectedSideAAsks() {
    var state = LidSleepState(owned: false, now: 0)
    #expect(state.tick(now: 0) == nil)
    state.connect(1)
    #expect(state.request(1, disabled: true, systemDisabled: false) == .disable)
    state.applied(.disable, success: true)
    #expect(state.owned)
    #expect(state.request(1, disabled: true, systemDisabled: true) == nil)
    #expect(state.request(1, disabled: false, systemDisabled: true) == .restore)
    state.applied(.restore, success: true)
    #expect(!state.owned && state.tick(now: 10) == nil)
}

@Test func theUsersOwnDisabledSleepIsLeftAlone() {
    var state = LidSleepState(owned: false, now: 0)
    state.connect(1)
    #expect(state.request(1, disabled: true, systemDisabled: true) == nil)
    #expect(!state.owned)
    #expect(state.request(1, disabled: false, systemDisabled: true) == nil)
    state.disconnect(1, now: 5)
    #expect(state.tick(now: 1_000) == nil && state.restoreAt == nil)
}

@Test func aDisconnectRestoresAfterTheHandoverUnlessANewSideAAsks() {
    var crashed = LidSleepState(owned: false, now: 0)
    crashed.connect(1)
    #expect(!crashed.shouldExit(now: LidSleepState.idleExit + 1))
    _ = crashed.request(1, disabled: true, systemDisabled: false)
    crashed.applied(.disable, success: true)
    crashed.disconnect(1, now: 100)
    #expect(crashed.restoreAt == 100 + LidSleepState.handover)
    #expect(crashed.tick(now: 100 + LidSleepState.handover - 1) == nil)
    #expect(crashed.tick(now: 100 + LidSleepState.handover) == .restore)
    #expect(!crashed.shouldExit(now: 1_000))
    crashed.applied(.restore, success: true)
    #expect(crashed.shouldExit(now: 100 + LidSleepState.idleExit) && crashed.restoreAt == nil)

    var updated = LidSleepState(owned: false, now: 0)
    updated.connect(1)
    _ = updated.request(1, disabled: true, systemDisabled: false)
    updated.applied(.disable, success: true)
    updated.disconnect(1, now: 100)
    updated.connect(2)
    #expect(updated.request(2, disabled: true, systemDisabled: true) == nil)
    #expect(updated.restoreAt == nil && updated.owned)
    #expect(updated.tick(now: 1_000) == nil)
}

@Test func anotherAskingSideAKeepsSleepOff() {
    var state = LidSleepState(owned: false, now: 0)
    state.connect(1)
    state.connect(2)
    _ = state.request(1, disabled: true, systemDisabled: false)
    state.applied(.disable, success: true)
    _ = state.request(2, disabled: true, systemDisabled: true)
    state.disconnect(1, now: 10)
    #expect(state.restoreAt == nil && state.tick(now: 1_000) == nil)
    #expect(state.request(2, disabled: false, systemDisabled: true) == .restore)
}

@Test func launchRestoresWhatAnEarlierHelperLeftOffAndRetriesFailures() {
    var state = LidSleepState(owned: true, now: 0)
    #expect(state.tick(now: 0) == .restore)
    state.applied(.restore, success: false)
    #expect(state.owned && state.tick(now: 2) == .restore && !state.shouldExit(now: 100))
    state.applied(.restore, success: true)
    #expect(!state.owned && state.tick(now: 4) == nil)
    #expect(!state.shouldExit(now: LidSleepState.idleExit - 1) && state.shouldExit(now: LidSleepState.idleExit))
}

@Test func aFailedDisableIsNotOwned() {
    var state = LidSleepState(owned: false, now: 0)
    state.connect(1)
    #expect(state.request(1, disabled: true, systemDisabled: false) == .disable)
    state.applied(.disable, success: false)
    #expect(!state.owned)
    #expect(state.request(1, disabled: true, systemDisabled: false) == .disable)
}
