import Foundation
import Testing
@testable import SideACore

private let on = KeepAwake.Settings(enabled: true)
private let lid = KeepAwake.Settings(enabled: true, lidClosed: true)
private let ac = KeepAwake.Power(onAC: true, battery: 80)

@Test func holdsWhileAgentsWorkAndForTheGracePeriodAfter() {
    var state = KeepAwake()
    #expect(!state.holdsAssertion(on, now: 0))
    state.observe(working: 3, now: 1_000)
    #expect(state.holdsAssertion(on, now: 1_000))
    #expect(!state.holdsAssertion(KeepAwake.Settings(enabled: false), now: 1_000))
    #expect(state.reason == "Side A: 3 agents working")
    state.observe(working: 0, now: 1_030)
    #expect(state.holdsAssertion(on, now: 1_030))
    #expect(state.holdsAssertion(on, now: 1_000 + KeepAwake.grace - 1))
    #expect(!state.holdsAssertion(on, now: 1_000 + KeepAwake.grace))
    #expect(state.reason == "Side A: agents paused")
    state.observe(working: 1, now: 2_000)
    #expect(state.reason == "Side A: 1 agent working")
    state.observe(working: -2, now: 2_010)
    #expect(state.working == 0 && state.inGrace(now: 2_010))
}

@Test func sleepIsDisabledOnlyWithTheLidOptionOnPowerOrAllowedBattery() {
    var state = KeepAwake()
    state.observe(working: 2, now: 0)
    #expect(!state.disablesSleep(on, power: ac, now: 0))
    #expect(state.disablesSleep(lid, power: ac, now: 0))
    #expect(state.disablesSleep(lid, power: KeepAwake.Power(onAC: true, battery: nil), now: 0))
    #expect(state.disablesSleep(lid, power: KeepAwake.Power(onAC: true, battery: 5), now: 0))
    let battery = KeepAwake.Power(onAC: false, battery: 60)
    #expect(!state.disablesSleep(lid, power: battery, now: 0))
    let anyPower = KeepAwake.Settings(enabled: true, lidClosed: true, onBattery: true)
    #expect(state.disablesSleep(anyPower, power: battery, now: 0))
    #expect(state.disablesSleep(anyPower, power: KeepAwake.Power(onAC: false, battery: KeepAwake.lowBattery), now: 0))
    #expect(!state.disablesSleep(anyPower, power: KeepAwake.Power(onAC: false, battery: KeepAwake.lowBattery - 1), now: 0))
    #expect(!state.disablesSleep(anyPower, power: KeepAwake.Power(onAC: false, battery: nil), now: 0))
    #expect(!state.disablesSleep(KeepAwake.Settings(enabled: false, lidClosed: true, onBattery: true), power: ac, now: 0))
    state.observe(working: 0, now: 60)
    #expect(state.disablesSleep(lid, power: ac, now: 60))
    #expect(!state.disablesSleep(lid, power: ac, now: KeepAwake.grace))
}

@Test func statusLineShowsOnlyWhileHolding() {
    var state = KeepAwake()
    #expect(state.line(on, sleepDisabled: false, now: 0) == nil)
    state.observe(working: 3, now: 0)
    #expect(state.line(on, sleepDisabled: false, now: 0) == "Keeping awake · 3 agents working")
    #expect(state.line(lid, sleepDisabled: true, now: 0) == "Keeping awake · 3 agents working · lid closed OK")
    #expect(state.accessibilityLine(lid, sleepDisabled: true, now: 0) == "Keeping the Mac awake while 3 agents work, also with the lid closed")
    state.observe(working: 0, now: 10)
    #expect(state.line(on, sleepDisabled: false, now: 10) == "Keeping awake · agents paused")
    #expect(state.line(on, sleepDisabled: false, now: 500) == nil)
    #expect(state.accessibilityLine(on, sleepDisabled: false, now: 500) == nil)
}

private func temporaryFolder(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test func closedLidSleepsOnlyAfterStayingAwakeAndClosedWithoutAnExternalDisplay() {
    #expect(ClosedLid.sleepNow(lidClosed: true, externalDisplay: false, elapsed: 30, awake: 30))
    #expect(ClosedLid.sleepNow(lidClosed: true, externalDisplay: false, elapsed: 32, awake: 30))
    #expect(!ClosedLid.sleepNow(lidClosed: false, externalDisplay: false, elapsed: 30, awake: 30))
    #expect(!ClosedLid.sleepNow(lidClosed: true, externalDisplay: true, elapsed: 30, awake: 30))
    #expect(!ClosedLid.sleepNow(lidClosed: true, externalDisplay: false, elapsed: 3_600, awake: 30))
    #expect(!ClosedLid.sleepNow(lidClosed: true, externalDisplay: false, elapsed: 10, awake: 10))
}

private struct Projects {
    let folder: URL
    let registry: URL
    let projects: URL
    let now = Date()

    init() throws {
        folder = try temporaryFolder("keepawake")
        registry = folder.appendingPathComponent("sessions")
        projects = folder.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    }

    func session(_ pid: Int, _ status: String, cwd: String = "/Users/me/app", folder name: String? = nil, written: TimeInterval? = nil,
                 subagent: TimeInterval? = nil) throws {
        let id = "s\(pid)"
        let entry: [String: Any] = ["pid": pid, "sessionId": id, "cwd": cwd, "status": status]
        try JSONSerialization.data(withJSONObject: entry).write(to: registry.appendingPathComponent("\(pid).json"))
        let project = projects.appendingPathComponent(name ?? AgentActivity.projectFolder(cwd))
        if let written { try file(project.appendingPathComponent(id + ".jsonl"), age: written) }
        if let subagent { try file(project.appendingPathComponent(id).appendingPathComponent("subagents/agent-a1.jsonl"), age: subagent) }
    }

    func file(_ url: URL, age: TimeInterval) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func working(excluding root: String? = nil, dead: Set<Int> = []) -> Int {
        AgentActivity.claudeWorking(registry: registry, projects: projects, excluding: root, now: now) { !dead.contains($0) }
    }
}

@Test func countsBusyClaudeSessionsButNotWaitingIdleStaleOrOwnOnes() throws {
    let claude = try Projects()
    defer { try? FileManager.default.removeItem(at: claude.folder) }
    try claude.session(101, "busy", written: 30)
    try claude.session(102, "busy")
    try claude.session(103, "waiting")
    try claude.session(104, "idle")
    try claude.session(105, "busy", written: AgentActivity.staleAfter + 60)
    try claude.session(106, "busy", cwd: "/Users/me/Library/Application Support/SideA")
    try claude.session(107, "busy")
    try Data("{\"pid\":".utf8).write(to: claude.registry.appendingPathComponent("108.json"))
    // A long silent command isn't stale before three hours.
    try claude.session(109, "busy", written: 2 * 3_600)
    try claude.session(110, "busy", written: 4 * 3_600)
    #expect(claude.working(excluding: "/Users/me/Library/Application Support/SideA", dead: [107]) == 3)
    #expect(AgentActivity.claudeWorking(registry: claude.folder.appendingPathComponent("missing"), projects: claude.projects, excluding: nil, now: claude.now) { _ in true } == 0)
    #expect(AgentActivity.projectFolder("/Users/me/side-a.app") == "-Users-me-side-a-app")
}

@Test func aBackgroundShellCountsAsWorkingHoweverOldItsTranscript() throws {
    let claude = try Projects()
    defer { try? FileManager.default.removeItem(at: claude.folder) }
    try claude.session(101, "shell", written: 10 * 3_600)
    try claude.session(102, "shell")
    try claude.session(103, "shell", written: 10)
    #expect(claude.working(dead: [103]) == 2)
}

@Test func subagentTranscriptsKeepABusySessionFresh() throws {
    let claude = try Projects()
    defer { try? FileManager.default.removeItem(at: claude.folder) }
    try claude.session(101, "busy", written: 5 * 3_600, subagent: 60)
    try claude.session(102, "busy", written: 5 * 3_600, subagent: 4 * 3_600)
    try claude.session(103, "busy", written: 5 * 3_600)
    #expect(claude.working() == 1)
    let transcript = claude.projects.appendingPathComponent("-Users-me-app/s101.jsonl")
    let newest = try #require(AgentActivity.lastWrite(transcript))
    #expect(abs(newest.timeIntervalSince(claude.now.addingTimeInterval(-60))) < 1)
}

@Test func findsTranscriptsInFoldersClaudeCodeShortened() throws {
    let claude = try Projects()
    defer { try? FileManager.default.removeItem(at: claude.folder) }
    let long = "/Users/me/" + String(repeating: "deep/", count: 50) + "app"
    let shortened = String(AgentActivity.projectFolder(long).prefix(200)) + "-1a2b3c"
    try claude.session(101, "busy", cwd: long, folder: shortened, written: 5 * 3_600)
    try claude.session(102, "busy", cwd: "/Users/me/café", folder: "-Users-me-caf-", written: 5 * 3_600)
    #expect(claude.working() == 0)
    #expect(AgentActivity.transcript(projects: claude.projects, cwd: long, id: "s101")?.deletingLastPathComponent().lastPathComponent == shortened)
    #expect(AgentActivity.transcript(projects: claude.projects, cwd: nil, id: "s102") != nil)
    #expect(AgentActivity.transcript(projects: claude.projects, cwd: long, id: "missing") == nil)
}

@Test func countsCodexRolloutsWrittenInTheLastMinuteAndAHalfFromTwoWeeksOfFolders() throws {
    let sessions = try temporaryFolder("codex")
    defer { try? FileManager.default.removeItem(at: sessions) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_791_850_000)
    func rollout(_ day: String, _ name: String, age: TimeInterval) throws {
        let folder = sessions.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }
    try rollout("2026/10/13", "rollout-a.jsonl", age: 10)
    try rollout("2026/10/13", "rollout-b.jsonl", age: AgentActivity.codexRecent + 5)
    try rollout("2026/10/13", "notes.jsonl", age: 1)
    try rollout("2026/10/12", "rollout-c.jsonl", age: 30)
    try rollout("2026/09/30", "rollout-d.jsonl", age: 20)
    try rollout("2026/09/29", "rollout-e.jsonl", age: 20)
    #expect(AgentActivity.codexWorking(sessions: sessions, now: now, calendar: calendar) == 3)
    #expect(AgentActivity.isAlive(Int(getpid())))
    #expect(!AgentActivity.isAlive(0) && !AgentActivity.isAlive(1))
}
