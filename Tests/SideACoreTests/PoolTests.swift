import Foundation
@testable import SideACore
import Testing

@Test func poolFindsTheConversationFromTheHeaderOrTheMetadata() {
    let body = Data(#"{"metadata":{"user_id":"user_ab12_account__session_5f0c2a9e-1b2c-4d5e-8f90-123456789abc"},"model":"x"}"#.utf8)
    #expect(Pool.session(headers: HTTPHeaders(), body: body) == "5f0c2a9e-1b2c-4d5e-8f90-123456789abc")
    #expect(Pool.session(headers: HTTPHeaders([("x-claude-code-session-id", "abc")]), body: body) == "abc")
    #expect(Pool.session(headers: HTTPHeaders(), body: Data("{}".utf8)) == nil)
    #expect(Pool.session(headers: HTTPHeaders(), body: Data("not json".utf8)) == nil)
}

@Test func poolReadsAnAccountsLimitsFromItsReplyHeaders() {
    let headers = HTTPHeaders([("anthropic-ratelimit-unified-5h-utilization", "0.42"), ("anthropic-ratelimit-unified-5h-reset", "1800000000"),
                               ("anthropic-ratelimit-unified-7d-utilization", "1.3")])
    let windows = Pool.limits(headers)
    #expect(windows.map(\.id) == ["five_hour", "seven_day"])
    #expect(abs(windows[0].percent - 42) < 0.001 && windows[0].resetsAt == 1_800_000_000)
    #expect(windows[1].percent == 100 && windows[1].resetsAt == nil)
    #expect(Pool.limits(HTTPHeaders()).isEmpty)
}

@Test func poolOnlyEverSendsToTheAPIHostsV1Routes() {
    let base = URL(string: "https://api.anthropic.com")!
    #expect(Pool.upstream("/v1/messages?beta=true", base: base)?.absoluteString == "https://api.anthropic.com/v1/messages?beta=true")
    #expect(Pool.upstream("/v1/messages/count_tokens", base: URL(string: "http://127.0.0.1:9")!)?.absoluteString == "http://127.0.0.1:9/v1/messages/count_tokens")
    for target in ["//evil.example/v1/messages", "/v1/../../x", "https://evil.example/v1/m", "/api/oauth/profile", "/v1\\@evil.example/", "/", "", "/v1/m#frag"] {
        #expect(Pool.upstream(target, base: base)?.host.map { $0 == "api.anthropic.com" && target.hasPrefix("/v1/") && !target.contains("..") } ?? true, "\(target)")
    }
    #expect(Pool.upstream("//evil.example/v1/messages", base: base) == nil)
    #expect(Pool.upstream("/api/oauth/profile", base: base) == nil)
    #expect(Pool.upstream("/v1/../api/oauth/profile", base: base) == nil)
    #expect(Pool.upstream("/v1/%2e%2e/api/oauth/profile", base: base) == nil)
}

@Test func poolCachesForAnHourAsClaudeCodeDoesForASubscriber() {
    let body = #"{"system":[{"type":"text","text":"x","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"say \"cache_control\":{\"type\":\"ephemeral\"}","cache_control":{"type":"ephemeral"}}]}]}"#
    let out = String(decoding: Pool.hourLongCache(Data(body.utf8)), as: UTF8.self)
    #expect(out.components(separatedBy: #""cache_control":{"type":"ephemeral","ttl":"1h"}"#).count == 3)
    #expect(out.contains(#"say \"cache_control\":{\"type\":\"ephemeral\"}"#))
    #expect(out.replacingOccurrences(of: #","ttl":"1h""#, with: "") == body)
    let set = #"{"cache_control":{"type":"ephemeral","ttl":"5m"}}"#
    #expect(Pool.hourLongCache(Data(set.utf8)) == Data(set.utf8))
}

@Test func poolServesClaudeCodeOnly() {
    #expect(Pool.fromClaudeCode(HTTPHeaders([("User-Agent", "claude-cli/2.1.314 (external, cli)")])))
    #expect(!Pool.fromClaudeCode(HTTPHeaders([("User-Agent", "Anthropic/Python 0.70.0")])))
    #expect(!Pool.fromClaudeCode(HTTPHeaders()))
}

@Test func poolRetriesAFullAccountAtItsResetAndNeverWithinAMinute() {
    #expect(Pool.retryAt(HTTPHeaders([("anthropic-ratelimit-unified-reset", "5000")]), now: 1000) == 5000)
    #expect(Pool.retryAt(HTTPHeaders([("retry-after", "10")]), now: 1000) == 1060)
    #expect(Pool.retryAt(HTTPHeaders(), now: 1000) == 1900)
}

@Test func aConversationStaysOnItsAccountUntilItCantTakeMore() {
    var router = PoolRouter()
    var full: Set<String> = []
    var next = "a"
    let route = { (session: String?, now: Double) in router.route(session: session, now: now, usable: { !full.contains($0) }, pick: { next }) }
    #expect(route("one", 0) == "a")
    next = "b"
    #expect(route("one", 60) == "a")
    #expect(route("two", 60) == "b")
    #expect(route(nil, 60) == "b")
    full = ["a"]
    #expect(route("one", 120) == "b")
    full = []
    next = "c"
    #expect(route("one", 120 + Pool.affinity) == "c")
    #expect(router.conversations == ["c": 1])
}

@Test func poolReadsCodexLimitsAndRoutes() {
    let headers = HTTPHeaders([("x-codex-primary-used-percent", "100"), ("x-codex-primary-window-minutes", "10080"), ("x-codex-primary-reset-at", "1800000000"),
                               ("x-codex-secondary-used-percent", "0"), ("x-codex-secondary-window-minutes", "0"), ("x-codex-secondary-reset-at", "")])
    #expect(Pool.codexLimits(headers).map(\.id) == ["seven_day"])
    #expect(Pool.codexRetryAt(headers, now: 1_000) == 1_800_000_000)
    #expect(Pool.codexSession(HTTPHeaders([("thread-id", "t"), ("session-id", "s")])) == "s")
    #expect(Pool.fromCodex(HTTPHeaders([("originator", "codex_cli_rs")])))
    #expect(!Pool.fromCodex(HTTPHeaders([("User-Agent", "curl/8")])))
    let base = URL(string: "https://chatgpt.com/backend-api")!
    #expect(Pool.upstream("/codex/responses", base: base, prefix: "/codex/")?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
    #expect(Pool.upstream("/codex/../me", base: base, prefix: "/codex/") == nil)
    #expect(Pool.upstream("/v1/messages", base: base, prefix: "/codex/") == nil)
}

@Test func poolRoomWeighsAccountsByPlanSizeAndSaysWhoIsBackFirst() throws {
    let now = 1_000_000.0
    let big = Account(name: "Big", ready: true, allowAuto: true), small = Account(name: "Small", ready: true, allowAuto: true)
    let usage = [big.id: AccountUsage(windows: [UsageWindow(id: "seven_day", label: "Weekly", percent: 50, resetsAt: now + 3600)], capacity: 20),
                 small.id: AccountUsage(windows: [UsageWindow(id: "five_hour", label: "5-hour", percent: 100, resetsAt: now + 600),
                                                  UsageWindow(id: "seven_day", label: "Weekly", percent: 0, resetsAt: now + 3600)], capacity: 1)]
    let room = try #require(PoolRoom([big, small], usage: usage, now: now))
    #expect(room.accounts == 2 && room.limited == 1)
    #expect(abs(room.weeklyLeft - (20 * 50 + 100) / 21) < 0.001)
    #expect(abs((room.fiveHourLeft ?? 0) - 2000.0 / 21) < 0.001)
    #expect(PoolRoom([big], usage: usage, now: now)?.fiveHourLeft == nil)
    #expect(room.refill?.name == "Small" && room.refill?.at == now + 600)
    #expect(PoolRoom([big], usage: [:], now: now) == nil)
}

@Test func priorityDecidesBeforeUrgencyAndLastIsOnlyForWhenOthersAreOut() {
    let now = 1_000_000.0
    let urgent = AccountUsage(windows: [UsageWindow(id: "seven_day", label: "Weekly", percent: 10, resetsAt: now + 3600)])
    let relaxed = AccountUsage(windows: [UsageWindow(id: "seven_day", label: "Weekly", percent: 10, resetsAt: now + 500_000)])
    let full = AccountUsage(windows: [UsageWindow(id: "seven_day", label: "Weekly", percent: 100, resetsAt: now + 500_000)])
    let reserve = Account(name: "Reserve", ready: true, allowAuto: true, priority: .last)
    let normal = Account(name: "Normal", ready: true, allowAuto: true)
    let first = Account(name: "First", ready: true, allowAuto: true, priority: .first)
    #expect(Planner.best([reserve, normal], usage: [reserve.id: urgent, normal.id: relaxed], active: nil, now: now) == normal.id)
    #expect(Planner.best([reserve, normal], usage: [reserve.id: urgent, normal.id: full], active: nil, now: now) == reserve.id)
    #expect(Planner.best([first, normal], usage: [first.id: relaxed, normal.id: urgent], active: normal.id, now: now) == first.id)
}
