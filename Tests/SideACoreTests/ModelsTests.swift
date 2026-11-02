import Foundation
import Testing
@testable import SideACore

private let invalidConfigs: [(String, @Sendable (inout Configuration) -> Void)] = [
    ("duplicate identity", { let account = Account(name: "Personal"); $0.accounts = [account, account] }),
    ("unsupported version", { $0.accounts = [Account(name: "Personal")]; $0.version = 3 }),
    ("traversal", { $0.accounts = [Account(id: "../escape", name: "Wrong")] }),
    ("dangling selection", { $0.accounts = [Account(name: "Real")]; $0.selectedID = UUID().uuidString }),
]

@Test(arguments: invalidConfigs)
func anInvalidConfigurationIsRejected(_ name: String, _ change: @Sendable (inout Configuration) -> Void) {
    var config = Configuration()
    change(&config)
    #expect(throws: StorageError.self, "\(name)") { try config.validated() }
}

@Test func persistsPrivateLibraryWithRestrictivePermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("config.json")
    var config = Configuration()
    config.accounts = [Account(name: "Personal")]
    config.selectedID = config.accounts[0].id
    try PrivateFile.write(config, to: path)
    #expect(try PrivateFile.read(Configuration.self, from: path) == config)
    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func oldClaudeProfilesKeepIdentityAndConsent() throws {
    let id = UUID().uuidString.lowercased()
    let data = Data("""
    {"id":"\(id)","name":"Personal","email":"person@example.com","ready":true,"allowAuto":true}
    """.utf8)
    let account = try JSONDecoder().decode(Account.self, from: data)
    #expect(account.provider == .claude)
    #expect(account.id == id && account.ready && account.allowAuto)
    #expect(account.email == "person@example.com")
}

@Test func codexProfileRoundTripsAndUnknownProvidersFailClosed() throws {
    let account = Account(name: "Work", ready: true, provider: .codex)
    let data = try JSONEncoder().encode(account)
    #expect(try JSONDecoder().decode(Account.self, from: data) == account)
    let unknown = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "codex", with: "unknown")
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Account.self, from: Data(unknown.utf8)) }
}

@Test func legacyLibraryPromotesSchemaWithoutChangingAccounts() throws {
    var legacy = Configuration()
    legacy.version = 1
    legacy.accounts = [Account(name: "Personal", email: "person@example.com", ready: true, allowAuto: true)]
    legacy.selectedID = legacy.accounts[0].id
    legacy.smartMode = true
    let migrated = try legacy.validated()
    #expect(migrated.version == 2)
    #expect(migrated.accounts == legacy.accounts)
    #expect(migrated.selectedID == legacy.selectedID && migrated.smartMode)
}

@Test func plannerBurnsExpiringQuotaFirstAndPrimesIdleWindows() {
    let now = 1_000_000.0, hour = 3600.0
    let soon = Account(name: "Soon", ready: true, allowAuto: true)
    let later = Account(name: "Later", ready: true, allowAuto: true)
    let full = Account(name: "Full", ready: true, allowAuto: true)
    func usage(_ five: Double?, _ fiveReset: Double?, _ week: Double, _ weekReset: Double) -> AccountUsage {
        AccountUsage(windows: [five.map { UsageWindow(id: "five_hour", label: "5-hour", percent: $0, resetsAt: fiveReset) },
                               UsageWindow(id: "seven_day", label: "Weekly", percent: week, resetsAt: weekReset)].compactMap { $0 })
    }
    var table = [soon.id: usage(10, now + 2 * hour, 40, now + 24 * hour),    // 60% left, 1 day to use it
                 later.id: usage(0, nil, 10, now + 6 * 24 * hour),            // 90% left, 6 days
                 full.id: usage(99, now + hour, 50, now + 24 * hour)]         // 5-hour limit hit
    let accounts = [later, soon, full]
    #expect(Planner.best(accounts, usage: table, active: full.id, now: now) == soon.id)
    // Hysteresis keeps a usable active account unless the pick is clearly more urgent.
    #expect(Planner.best(accounts, usage: table, active: later.id, now: now) == soon.id)
    table[soon.id] = usage(10, now + 2 * hour, 40, now + 6 * 24 * hour)
    #expect(Planner.best(accounts, usage: table, active: later.id, now: now) == later.id)
    // Never move to an account that is already close to its 5-hour limit.
    table[soon.id] = usage(93, now + 2 * hour, 40, now + 24 * hour)
    #expect(Planner.best([soon, full], usage: table, active: full.id, now: now) == nil)
    #expect(Planner.best([soon, full], usage: table, active: soon.id, now: now) == soon.id)
    // From brandedDaniel's fork: a target nearly out of weekly quota would be left again minutes
    // later, so an account with room on every limit wins; one is still used when it is all there is.
    table[soon.id] = usage(10, now + 2 * hour, 93, now + 2 * hour)
    #expect(Planner.best(accounts, usage: table, active: full.id, now: now) == later.id)
    #expect(Planner.best([soon, full], usage: table, active: full.id, now: now) == soon.id)
    table[soon.id] = usage(10, now + 2 * hour, 40, now + 6 * 24 * hour)
    // An expired window counts as not started.
    #expect(Planner.shouldPrime(later, usage: table[later.id], now: now))
    #expect(Planner.shouldPrime(soon, usage: usage(80, now - 1, 40, now + hour), now: now))
    #expect(!Planner.shouldPrime(soon, usage: table[soon.id], now: now))
    #expect(!Planner.shouldPrime(Account(name: "Off", ready: true), usage: table[later.id], now: now))
    // Review: a Codex plan with no 5-hour window was primed every 30 minutes forever.
    #expect(!Planner.shouldPrime(Account(name: "Codex", ready: true, allowAuto: true, provider: .codex), usage: usage(nil, nil, 10, now + hour), now: now))
    // Claude's plans may omit an idle window, Ultra's included; a Last account's waits until it's needed.
    var ultra = usage(nil, nil, 10, now + hour); ultra.capacity = 20
    #expect(Planner.shouldPrime(Account(name: "Claude", ready: true, allowAuto: true), usage: ultra, now: now))
    #expect(!Planner.shouldPrime(Account(name: "Reserve", ready: true, allowAuto: true, priority: .last), usage: ultra, now: now))
    let top = Account(name: "Top", ready: true, allowAuto: true, priority: .first), low = Account(name: "Low", ready: true, allowAuto: true, priority: .last)
    #expect(Planner.priorityMoveWaits(from: low, to: top, usage: table[soon.id], movedAt: now - 60, now: now))
    #expect(!Planner.priorityMoveWaits(from: low, to: top, usage: table[soon.id], movedAt: now - 2 * hour, now: now))
    #expect(!Planner.priorityMoveWaits(from: top, to: low, usage: table[soon.id], movedAt: now - 60, now: now))
    // A Max 20x account's remaining weekly quota outweighs a Pro account's.
    var big = table[later.id]!; big.capacity = 20
    #expect(Planner.urgency(big, now: now) > Planner.urgency(table[soon.id]!, now: now))
    // Forecast needs at least five minutes of rising samples.
    #expect(Planner.minutesToLimit([(0, 50), (600, 60)]) == 37)
    #expect(Planner.minutesToLimit([(0, 50), (120, 60)]) == nil)
    // The estimate counts down between readings, and stale readings give none.
    #expect(Planner.minutesToLimit([(0, 50), (600, 60)], now: 600 + 7 * 60) == 30)
    #expect(Planner.minutesToLimit([(0, 50), (600, 60)], now: 600 + 11 * 60) == nil)
    let blocked = [soon.id: usage(99, now + hour, 40, now + 24 * hour), full.id: usage(10, now + hour, 99, now + 3 * hour)]
    #expect(Planner.nextAvailable([soon, full], usage: blocked, now: now)?.0.id == soon.id)
    // A 5-hour window above the switch target blocks until it resets, even below the hard limit.
    let nearly = [soon.id: usage(93, now + 600, 40, now + 24 * hour), full.id: usage(10, now + hour, 99, now + 3 * hour)]
    #expect(Planner.nextAvailable([soon, full], usage: nearly, now: now)?.1 == now + 600)
}

@Test func scheduleIgnoresLightOvernightAgentTraffic() {
    // A real 14-day histogram: overnight agents run at up to 13% of the peak.
    let hours = [1095, 1542, 1584, 1586, 2286, 457, 289, 287, 16888, 20207, 18177, 15070, 14568, 18778,
                 21247, 20781, 18890, 13652, 12336, 9746, 6467, 6917, 4080, 3143]
    let schedule = WorkSchedule(Array(repeating: ActivitySpan(date: "d", hours: hours), count: 14))!
    #expect(schedule.start == 480 && schedule.end == 1320)
}

@Test func fablePlanningSkipsSpentFableCapsAndPlansWithoutFable() {
    let now = Date().timeIntervalSince1970
    func usage(weekly: Double, fable: Double?, capacity: Double) -> AccountUsage {
        AccountUsage(windows: [UsageWindow(id: "five_hour", label: "5-hour", percent: 10, resetsAt: now + 3600),
                               UsageWindow(id: "seven_day", label: "Weekly", percent: weekly, resetsAt: now + 86_400)]
                     + (fable.map { [UsageWindow(id: "model:fable", label: "Weekly Fable", percent: $0, resetsAt: now + 86_400)] } ?? []),
                     capacity: capacity)
    }
    let spent = Account(name: "Spent", ready: true, allowAuto: true), room = Account(name: "Room", ready: true, allowAuto: true)
    let pro = Account(name: "Pro", ready: true, allowAuto: true), almost = Account(name: "Almost", ready: true, allowAuto: true)
    let all = [spent.id: usage(weekly: 40, fable: 100, capacity: 20), room.id: usage(weekly: 60, fable: 20, capacity: 5),
               pro.id: usage(weekly: 0, fable: nil, capacity: 1), almost.id: usage(weekly: 99, fable: 0, capacity: 20)]
    let accounts = [spent, room, pro, almost]
    #expect(Planner.best(accounts, usage: all, active: spent.id, now: now) == spent.id)
    // Weekly room caps Fable room: an account 99% through its week has almost no Fable left.
    #expect(all[almost.id]!.forFable!.weekly!.percent == 98)
    // A Max plan with no Fable cap listed yet still has its Fable share; a Pro plan has none.
    #expect(usage(weekly: 10, fable: nil, capacity: 20).forFable?.weekly?.percent == 0)
    #expect(all[pro.id]!.forFable == nil)
    #expect(Planner.best(accounts, usage: all.compactMapValues(\.forFable), active: spent.id, now: now) == room.id)
}

@Test func weekForecastFollowsAWeekdayRhythmNotAStraightLine() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    // Four weeks of weekday 9:00-17:00 work, nothing on weekends. 2026-09-07 is a Monday.
    let monday = try Date("2026-09-07T00:00:00Z", strategy: .iso8601).timeIntervalSince1970
    let activity = (0..<28).map { day -> ActivitySpan in
        let date = Date(timeIntervalSince1970: monday + Double(day) * 86_400)
        let weekend = [1, 7].contains(calendar.component(.weekday, from: date))
        return ActivitySpan(date: Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day().format(date),
                            hours: (0..<24).map { !weekend && (9..<17).contains($0) ? 10 : 0 })
    }
    let rhythm = try #require(WeekRhythm(activity, calendar: calendar))
    let reset = monday + 35 * 86_400  // the next Monday 00:00
    // Friday 17:00: the work week is over, so half the limit used means about half by the reset,
    // where a straight line would have projected 70%.
    let friday = reset - 7 * 86_400 + 4 * 86_400 + 17 * 3600
    let calm = try #require(WeekForecast(UsageWindow(id: "seven_day", label: "Weekly", percent: 50, resetsAt: reset), rhythm: rhythm, now: friday))
    #expect(calm.projected < 55 && calm.expectedNow > 0.9 && calm.runsOut == nil)
    // Wednesday 12:00 at 80% after 19 of 40 working hours: the last 20% lasts about 5 more working hours.
    let wednesday = reset - 7 * 86_400 + 2 * 86_400 + 12 * 3600
    let busy = try #require(WeekForecast(UsageWindow(id: "seven_day", label: "Weekly", percent: 80, resetsAt: reset), rhythm: rhythm, now: wednesday))
    let out = Date(timeIntervalSince1970: try #require(busy.runsOut))
    #expect(calendar.component(.weekday, from: out) == 4 && (16..<17).contains(calendar.component(.hour, from: out)))
}

@Test func aSessionsLimitErrorFillsThatLimitUntilANewerReading() {
    let now = 1_000_000.0
    let reading = AccountUsage(windows: [UsageWindow(id: "five_hour", label: "5-hour", percent: 70, resetsAt: now + 3600),
                                         UsageWindow(id: "seven_day", label: "Weekly", percent: 80, resetsAt: now - 60)], capacity: 5)
    // A known reset is kept; an expired one gives way to the longest the limit could last.
    let five = reading.hitting("five_hour", at: now)
    #expect(five.fiveHour == UsageWindow(id: "five_hour", label: "5-hour", percent: 100, resetsAt: now + 3600))
    #expect(reading.hitting("seven_day", at: now).weekly?.resetsAt == now + 7 * 86_400)
    #expect(!Planner.hasHeadroom(five, now: now))
    // A model cap the reading did not list yet is added, and Fable planning sees it spent.
    let fable = reading.hitting("model:fable", at: now)
    #expect(fable.modelLimits.map(\.label) == ["Weekly Fable"])
    #expect(fable.forFable.map { Planner.hasHeadroom($0, now: now) } == false)
}

@Test func fableSessionsTradeWithALoginOnlyOpusSessionsUse() {
    let now = 1_000_000.0
    func window(_ id: String, _ percent: Double) -> UsageWindow { UsageWindow(id: id, label: id, percent: percent, resetsAt: now + 3600) }
    let spent = Account(name: "Spent", email: "a@x.y", ready: true, allowAuto: true)
    let opus = Account(name: "Opus", email: "b@x.y", ready: true, allowAuto: true)
    let idle = Account(name: "Idle", email: "c@x.y", ready: true, allowAuto: true)
    let usage = [spent.id: AccountUsage(windows: [window("five_hour", 10), window("seven_day", 30), window("model:fable", 100)], capacity: 20),
                 opus.id: AccountUsage(windows: [window("five_hour", 20), window("seven_day", 20), window("model:fable", 10)], capacity: 20)]
    let slots = ["mac": spent.id, "p1": opus.id]
    let pick = Planner.fableShare(for: "mac", slots: slots, models: ["mac": ["claude-fable-5-1"], "p1": ["claude-opus-5-5", "claude-opus-5-5"]],
                                  accounts: [spent, opus, idle], usage: usage, excluded: [], now: now)
    #expect(pick?.slot == "p1" && pick?.account == opus.id)
    // A partner whose session model is unknown, or one running Fable itself, never takes a spent login.
    #expect(Planner.fableShare(for: "mac", slots: slots, models: ["mac": ["claude-fable-5-1"], "p1": ["claude-opus-5-5", nil]],
                               accounts: [spent, opus], usage: usage, excluded: [], now: now) == nil)
    #expect(Planner.fableShare(for: "mac", slots: slots, models: ["mac": ["claude-fable-5-1"], "p1": ["claude-fable-5-1"]],
                               accounts: [spent, opus], usage: usage, excluded: [], now: now) == nil)
    // The Opus sessions must have room on the login they'd get.
    var full = usage; full[spent.id] = AccountUsage(windows: [window("five_hour", 100), window("seven_day", 30), window("model:fable", 100)])
    #expect(Planner.fableShare(for: "mac", slots: slots, models: ["mac": ["claude-fable-5-1"], "p1": ["claude-opus-5-5"]],
                               accounts: [spent, opus], usage: full, excluded: [], now: now) == nil)
    #expect(Planner.needsFable(nil) == nil && Planner.needsFable(["claude-opus-5-5", nil]) == nil && Planner.needsFable(["claude-sonnet-5-5"]) == false)
}

@Test func tradesWaitForAPauseUnlessTheAccountIsOutOfRoom() {
    let now = 1_000_000.0
    let room = AccountUsage(windows: [UsageWindow(id: "five_hour", label: "5-hour", percent: 60, resetsAt: now + 3600)])
    let full = AccountUsage(windows: [UsageWindow(id: "five_hour", label: "5-hour", percent: 99, resetsAt: now + 3600)])
    #expect(Planner.waitsForPause(room, quiet: 30, now: now))
    #expect(!Planner.waitsForPause(room, quiet: 600, now: now))
    #expect(!Planner.waitsForPause(full, quiet: 30, now: now))
    #expect(!Planner.waitsForPause(room, quiet: nil, now: now))
}

@Test func usageReadingsStayWithinTheCap() throws {
    let over = UsageWindow(id: "five_hour", label: "5-hour", percent: 101.4, resetsAt: 2_000)
    #expect(over.percent == 100)
    #expect(over.text(at: 1_000) == "100%")
    #expect(UsageWindow(id: "five_hour", label: "5-hour", percent: -3, resetsAt: nil).percent == 0)
    #expect(UsageWindow(id: "five_hour", label: "5-hour", percent: .nan, resetsAt: nil).percent == 0)
    let saved = Data(#"{"id":"seven_day","label":"Weekly","percent":130,"resetsAt":2000}"#.utf8)
    #expect(try JSONDecoder().decode(UsageWindow.self, from: saved).percent == 100)
    // Once the window resets it holds nothing, however full the last reading was.
    #expect(over.used(at: 2_000) == 0)
    #expect(over.text(at: 2_500) == "0%")
}

@Test func aLiveReadingFromAnotherWeekBelongsElsewhere() {
    let now = 1_000_000.0
    let known = AccountUsage(windows: [UsageWindow(id: "seven_day", label: "Weekly", percent: 40, resetsAt: now + 200_000)])
    let week = { (reset: Double) in [UsageWindow(id: "seven_day", label: "Weekly", percent: 90, resetsAt: reset)] }
    #expect(Planner.belongsElsewhere(week(now + 50_000), known: known, now: now))
    #expect(!Planner.belongsElsewhere(week(now + 200_600), known: known, now: now))
    // Once the account's own week has reset, a new week's reading is its own.
    #expect(!Planner.belongsElsewhere(week(now + 600_000), known: known, now: now + 250_000))
    #expect(!Planner.belongsElsewhere(week(now + 50_000), known: nil, now: now))
}

/// A removal is remembered per provider and email, survives a save, and libraries from before it read as none.
@Test func aRemovedLoginIsRememberedUntilTakenBack() throws {
    var config = try JSONDecoder().decode(Configuration.self, from: Data(#"{"version":2,"accounts":[],"smartMode":true,"menuBarOnly":true}"#.utf8))
    #expect(config.removedLogins == nil)
    config.noteRemoved(Account(name: "Work", email: "Work@Example.com"))
    config.noteRemoved(Account(name: "Work", email: "work@example.com"))
    config.noteRemoved(Account(name: "Blank"))
    #expect(config.removedLogins == ["claude:work@example.com"])
    #expect(config.wasRemoved("WORK@example.com", .claude) && !config.wasRemoved("work@example.com", .codex))
    let saved = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
    #expect(saved.wasRemoved("work@example.com", .claude))
    config.forgetRemoval("work@EXAMPLE.com", .claude)
    #expect(config.removedLogins == nil && !config.wasRemoved("work@example.com", .claude))
}
