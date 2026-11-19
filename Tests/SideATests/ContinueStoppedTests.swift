import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

@MainActor private func store(status: String) throws -> AccountStore {
    let store = AccountStore(demo: true, root: FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))"))
    store.island.installed[.claude] = true
    let object: [String: Any] = ["pid": 931, "id": "s-stopped", "status": status, "agent": "claude", "cwd": "/tmp/app", "started": 1_700_000_000]
    store.sessions.live.append(try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: object)))
    store.remote.inbox.staged = [931]
    try FileManager.default.createDirectory(at: store.autopilotLog.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return store
}

@MainActor private func log(_ store: AccountStore) -> String {
    (try? String(contentsOf: store.autopilotLog.url, encoding: .utf8)) ?? ""
}

/// A session stopped on a limit when its login was traded is sent "Please continue" once, through its inbox.
@MainActor @Test func aStoppedSessionIsAskedToContinueOnce() async throws {
    let store = try store(status: "idle")
    let now = Date().timeIntervalSince1970
    store.stopped { $0.move(["s-stopped"], at: now - StoppedSessions.settle) }
    await store.continueStopped(now: now)
    #expect(log(store).components(separatedBy: "Continued app").count == 2)
    #expect(store.stoppedSessions.isEmpty)

    store.stopped { $0.move(["s-stopped"], at: now) }
    await store.continueStopped(now: now + StoppedSessions.settle)
    #expect(log(store).components(separatedBy: "Continued app").count == 2)
}

/// A recorded trade notes which of the account's sessions sat on a limit; the others were never stopped.
@MainActor @Test func aTradeNotesOnlyTheSessionsALimitStopped() async throws {
    let store = try store(status: "idle")
    let key = WireBuilders.key(try #require(store.sessions.live.first))
    let moved = [RotationRecord.Session(id: key, project: "app")]
    store.recordRotation(RotationRecord(at: 100, kind: .moved, from: "Personal", to: "Studio", reason: "", sessions: moved))
    #expect(store.stoppedSessions.isEmpty)
    store.limitHits["personal"] = (limit: "five_hour", at: 90, sessions: ["s-stopped"])
    store.recordRotation(RotationRecord(at: 100, kind: .stuck, from: "Personal", reason: "", sessions: moved))
    #expect(store.stoppedSessions.isEmpty)
    store.recordRotation(RotationRecord(at: 100, kind: .moved, from: "Personal", to: "Studio", reason: "", sessions: moved))
    #expect(!store.stoppedSessions.isEmpty)
}

@MainActor @Test func nothingIsSentWhileOffOrMidTurn() async throws {
    let now = Date().timeIntervalSince1970
    let off = try store(status: "idle")
    off.setContinueStopped(false)
    off.stopped { $0.move(["s-stopped"], at: now - StoppedSessions.settle) }
    await off.continueStopped(now: now)
    #expect(!log(off).contains("Continued") && !off.stoppedSessions.isEmpty)
    off.setContinueStopped(true)
    #expect(off.config.continueStopped == nil)

    let busy = try store(status: "busy")
    busy.stopped { $0.move(["s-stopped"], at: now - StoppedSessions.settle) }
    await busy.continueStopped(now: now)
    #expect(!log(busy).contains("Continued") && busy.stoppedSessions.isEmpty)
}

/// With no hook waiting, the message is typed into the session's own terminal tab; a reply from the phone goes the same way.
@MainActor @Test func aSessionWithNoHookIsTypedIntoInItsTerminal() async throws {
    let store = try store(status: "idle")
    store.remote.inbox.staged = []
    let live = try #require(store.sessions.live.first)
    let commands = SessionCommands(store: store)
    #expect(!commands.abilities(live, status: .idle).contains(.replyTyped))
    await #expect(throws: SessionCommands.Failure.self) { try await commands.reply("s-stopped", .init(text: "hello")) }

    store.remote.typer.staged = [931: .ghostty]
    #expect(commands.abilities(live, status: .idle).contains(.replyTyped) && !commands.abilities(live, status: .working).contains(.replyTyped))
    #expect(try await commands.reply("s-stopped", .init(text: "hello")).delivery == .typed)
    let now = Date().timeIntervalSince1970
    store.stopped { $0.refuse("s-stopped", .codex, at: now) }
    await store.continueStopped(now: now)
    #expect(store.remote.typer.typed.map(\.text) == ["hello", StoppedSessions.prompt] && store.stoppedSessions.isEmpty)
    // The inbox, when a hook waits, comes first: it is the proven way in.
    store.remote.inbox.staged = [931]
    #expect(commands.abilities(live, status: .idle).contains(.replyInbox) && !commands.abilities(live, status: .idle).contains(.replyTyped))
}

/// A response cut off by sleep is tried again a minute on; a 429 that names no limit waits for the pool.
@MainActor @Test func aStalledSessionIsAskedOnceAnotherTryCouldWork() async throws {
    let store = try store(status: "idle")
    let now = Date().timeIntervalSince1970
    store.stalls = ["s-stopped": (error: "server_error", at: now - 30)]
    #expect(store.liftedSessions(now: now).isEmpty)
    #expect(store.liftedSessions(now: now + 30) == ["s-stopped": now - 30])
    #expect(store.liftedSessions(now: now + StoppedSessions.interrupted).isEmpty)
    store.stalls = ["s-stopped": (error: "rate_limit", at: now)]
    #expect(store.liftedSessions(now: now) == ["s-stopped": now])
    await store.continueStopped(now: now)
    #expect(log(store).contains("Continued app"))
    // What the phone's Autopilot list makes of the two lines.
    #expect(Autopilot.decision("Continued app", at: 1)?.kind == .continued && Autopilot.decision("Continued app", at: 1)?.title == "Continued app")
    let failed = try #require(Autopilot.decision("Couldn't continue app: Side A can't type into this session's terminal.", at: 1))
    #expect(failed.kind == .failed && failed.title == "Couldn't continue app" && failed.reason.hasPrefix("Side A can't type"))
    #expect(TerminalTyping.atLeast("1.4.0", [1, 4]) && TerminalTyping.atLeast("2.0", [1, 4]) && !TerminalTyping.atLeast("1.3.9", [1, 4]) && !TerminalTyping.atLeast("tip", [1, 4]))
}

/// What the helper refused while Side A was closed, and what Side A knew before it quit, are still asked.
@MainActor @Test func stopsOutliveARelaunchAndTheHelpersAreTaken() async throws {
    let first = try store(status: "idle")
    let now = Date().timeIntervalSince1970
    first.stopped { $0.move(["s-stopped"], at: now) }
    let again = AccountStore(demo: true, root: first.root)
    #expect(again.stoppedSessions == first.stoppedSessions && !again.stoppedSessions.isEmpty)

    let fresh = try store(status: "busy")
    let helper = HelperRefusals(root: fresh.root)
    try helper.refuse("s-stopped", .claude, at: now)
    try helper.refuse("went-on", .claude, at: now)
    try helper.served("went-on")
    #expect(helper.read().keys.sorted() == ["s-stopped"])
    await fresh.continueStopped(now: now)
    #expect(!fresh.stoppedSessions.isEmpty && helper.read().isEmpty && !FileManager.default.fileExists(atPath: helper.url.path))
}

/// However many models a month used, the chart draws five and folds the rest into one series.
@Test func theChartKeepsItsMostUsedModelsAndFoldsTheRest() {
    let ids = ["claude-opus-5-5", "gpt-6-astra", "claude-fable-5-2", "claude-haiku-5-5", "gpt-6.1-sol", "claude-sonnet-5-5", "gpt-6-luna", "claude-opus-4-8"]
    let rows = ids.enumerated().flatMap { index, id in
        ["2026-11-01", "2026-11-02"].map { TokenRow(date: $0, model: id, input: (ids.count - index) * 100, output: 0, cacheWrite: 0, cacheRead: 0) }
    }
    let series = TokenSeries(rows)
    #expect(series.names == ["Opus 5.5", "GPT-6 Astra", "Fable 5.2", "Haiku 5.5", "GPT-6.1 Sol", "Other"])
    #expect(series.rows.count == 12 && series.rows.map(\.total).reduce(0, +) == rows.map(\.total).reduce(0, +))
    #expect(series.rows.first { $0.date == "2026-11-02" && $0.model == "Other" }?.total == 600)

    // Six models fit as they are: "Other" never stands for one model.
    let six = TokenSeries(Array(rows.filter { ids.prefix(6).contains($0.model ?? "") }))
    #expect(six.names.count == 6 && !six.names.contains("Other"))
    #expect(TokenSeries([TokenRow(date: "2026-11-01", input: 5, output: 0, cacheWrite: 0, cacheRead: 0)]).names == ["Other"])
    // A bar sits on its own local day.
    #expect(Calendar.current.dateComponents([.month, .day, .hour], from: UsageSettings.day("2026-11-01")) == DateComponents(month: 11, day: 1, hour: 0))
}
