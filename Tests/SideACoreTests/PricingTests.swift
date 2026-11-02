import Foundation
import Testing
@testable import SideACore

@Test func apiValueUsesEachModelsListPrices() {
    let million = TokenRow(model: "claude-opus-5-5", input: 1_000_000, output: 1_000_000, cacheWrite: 0, cacheRead: 1_000_000)
    #expect(APIPrice.of("claude-opus-5-5")?.dollars(million) == 24.2)
    #expect(APIPrice.of("claude-opus-4-1-20250805")?.input == 15)
    #expect(APIPrice.of("claude-opus-4-7")?.input == 5)
    #expect(APIPrice.of("claude-sonnet-4-5-20250929")?.input == 3)
    #expect(APIPrice.of("claude-haiku-5-5")?.output == 0.5)
    #expect(APIPrice.of("claude-fable-5-1")?.output == 50)
    #expect(APIPrice.of("claude-opus-5-5[1m]", in: [:])?.input == 4)
    #expect(APIPrice.of("claude-sonnet-5-5-20261001", in: [:])?.input == 2)
    #expect(APIPrice.of("gpt-6.1-sol") == nil)
    var codex = million; codex.model = "gpt-6.1-sol"
    #expect(APIPrice.dollars([million, codex]) == 24.2)
}

@Test func outagesCountOnlyWhenTheyReachClaudeCodeOrTheAPI() {
    let console = #"{"components":[{"name":"Claude Console (platform.claude.com)","status":"degraded_performance"},{"name":"Claude Code","status":"operational"}],"incidents":[{"id":"a","name":"Elevated errors on platform.claude.com","status":"monitoring","impact":"major","components":[{"name":"Claude Console (platform.claude.com)"}]}]}"#
    #expect(Outage.parse(Data(console.utf8)) == nil)
    let api = #"{"components":[],"incidents":[{"id":"b","name":"Elevated errors on Opus","status":"investigating","impact":"major","created_at":"2026-10-18T09:30:00.000Z","shortlink":"https://stspg.io/b","components":[{"name":"Claude API (api.anthropic.com)"},{"name":"Claude Code"}]}]}"#
    #expect(Outage.parse(Data(api.utf8)) == Outage(id: "b", name: "Elevated errors on Opus", major: true, status: "investigating",
                                                   startedAt: 1_792_315_800, url: "https://stspg.io/b"))
    let resolved = api.replacingOccurrences(of: "investigating", with: "resolved")
    #expect(Outage.parse(Data(resolved.utf8)) == nil)
    let degraded = #"{"components":[{"name":"Claude Code","status":"partial_outage"}],"incidents":[]}"#
    #expect(Outage.parse(Data(degraded.utf8))?.name == "Claude Code: partial outage")
    let nested = #"{"incidents":[{"id":"c","name":"Errors in Claude Code","status":"identified","impact":"minor","incident_updates":[{"affected_components":[{"name":"Claude Code"}]}]}]}"#
    #expect(Outage.parse(Data(nested.utf8))?.id == "c")
}

@Test func publishedPricesWinAndCoverModelsTheTableDoesnt() {
    let list = #"{"claude-mythos-5-1":{"input_cost_per_token":1e-05,"output_cost_per_token":5e-05,"cache_creation_input_token_cost":1.25e-05,"cache_read_input_token_cost":2.5e-07},"claude-opus-5-5":{"input_cost_per_token":3e-06,"output_cost_per_token":1.5e-05},"bedrock/claude-opus-5-5":{"input_cost_per_token":9},"gpt-6":{"input_cost_per_token":1e-06,"output_cost_per_token":1e-06}}"#
    let parsed = APIPrice.parsePublished(Data(list.utf8))
    #expect(Set(parsed.keys) == ["claude-mythos-5-1", "claude-opus-5-5"])
    #expect(abs((parsed["claude-opus-5-5"]?.cacheRead ?? 0) - 0.3) < 1e-9)
    #expect(APIPrice.of("claude-mythos-5-1-20261001", in: parsed)?.output == 50)
    #expect(APIPrice.of("claude-opus-5-5[1m]", in: parsed)?.input == 3)
    #expect(APIPrice.of("claude-sonnet-5-5", in: parsed)?.input == 2)
}
