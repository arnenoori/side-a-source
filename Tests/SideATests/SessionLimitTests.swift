import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

@MainActor @Suite struct SessionLimitTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    @Test func aLimitedRowSaysWhenItGoesOn() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 10)))
        let today = now.addingTimeInterval(3 * 3600)
        let time = today.formatted(date: .omitted, time: .shortened)
        let limit = SessionLimit(window: "five_hour", accountID: "a", until: today.timeIntervalSince1970)
        #expect(SessionStore.limitText(limit, continues: true, now: now, calendar: calendar) == "Limited · continues \(time)")
        #expect(SessionStore.limitText(limit, continues: false, now: now, calendar: calendar) == "Limited until \(time)")
        let worst = SessionLimit(window: "five_hour", accountID: "a", until: today.timeIntervalSince1970, worstCase: true)
        #expect(SessionStore.limitText(worst, continues: true, now: now, calendar: calendar) == "Limited · continues by \(time)")
        #expect(SessionStore.limitText(worst, continues: false, now: now, calendar: calendar) == "Limited until \(time) at the latest")
    }

    @Test func aResetOnAnotherDayNamesTheDay() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 10)))
        let later = now.addingTimeInterval(3 * 86_400)
        let limit = SessionLimit(window: "seven_day", accountID: "a", until: later.timeIntervalSince1970)
        let day = later.formatted(.dateTime.weekday(.abbreviated))
        #expect(SessionStore.limitText(limit, continues: true, now: now, calendar: calendar).hasPrefix("Limited · continues \(day) "))
        #expect(SessionStore.limitText(SessionLimit(window: "five_hour", accountID: "a"), continues: true) == "Limited · continues at reset")
        #expect(SessionStore.limitText(SessionLimit(window: "five_hour", accountID: "a"), continues: false) == "Limited")
    }

    @Test func aSessionCanBeHeldBackFromContinuing() {
        let store = AccountStore(demo: true)
        #expect(store.continues("s"))
        store.sessions.setContinues("s", false)
        #expect(!store.sessions.continues("s"))
        store.sessions.setContinues("s", true)
        #expect(store.continues("s"))
        store.setContinueStopped(false)
        #expect(!store.continues("s"))
    }

    @Test func editFromHereIsForWhatTheUserSaidToClaude() throws {
        func session(_ agent: String, cwd: String? = "/code/app") throws -> SessionInfo {
            let fields: [String: Any?] = ["id": "s", "agent": agent, "cwd": cwd]
            return try JSONDecoder().decode(SessionInfo.self, from: JSONSerialization.data(withJSONObject: fields.compactMapValues { $0 }))
        }
        func message(_ role: String, uuid: String = "u1") -> SessionMessage {
            SessionMessage(role: role, text: "Now add search", tools: [], uuid: uuid, ts: nil, inherited: false, model: nil)
        }
        #expect(SessionStore.rewinds(try session("claude"), message("user")))
        #expect(!SessionStore.rewinds(try session("claude"), message("assistant")))
        #expect(!SessionStore.rewinds(try session("codex"), message("user")))
        #expect(!SessionStore.rewinds(try session("claude", cwd: nil), message("user")))
        #expect(!SessionStore.rewinds(try session("claude"), message("user", uuid: "")))
        #expect(SessionStore.command(try session("codex"), fork: true).hasSuffix("&& codex fork s"))
        #expect(SessionStore.command(try session("codex"), fork: false).hasSuffix("&& codex resume s"))
    }
}

@MainActor @Test func aCodexStopWaitsForItsOwnAccountNotAClaudeOne() {
    let accounts = [Account(id: "c", name: "Work", provider: .claude), Account(id: "x", name: "Codex Pro", provider: .codex)]
    let limits = [SessionLimit(window: "five_hour", accountID: "x", until: 2_000), SessionLimit(window: "seven_day", accountID: "c", until: 9_000)]
    #expect(AccountStore.earliest(limits, accounts: accounts) == WaitingSummary(account: "Codex Pro", at: 2_000))
    #expect(AccountStore.earliest([SessionLimit(window: "five_hour", accountID: "x")], accounts: accounts) == nil)
}
