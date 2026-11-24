import Foundation
@testable import SideACore
import Testing

// Captured screens trimmed to what the readers look at: Claude Code 2.1.30x draws its composer as `❯` and a no-break
// space between two rules; Codex 0.16x as `› ` with continuation rows indented two spaces.
private let rule = String(repeating: "─", count: 40)
private let claudeFooter = "  \u{1B}[2m⏵⏵ auto mode on (shift+tab to cycle)\u{1B}[0m"

private func claude(_ rows: String...) -> String {
    ([rule] + rows + [rule, claudeFooter]).joined(separator: "\n")
}

private func codex(_ rows: String...) -> String {
    ([""] + rows + ["", "  GPT-6-Astra high · ~/code/app"]).joined(separator: "\n")
}

private let long = "please refactor the parser so it handles nested quotes"

@Test func claudesPromptRunsFromItsGlyphRowToTheRule() {
    #expect(Hosting.prompt(.claude, screen: claude("❯\u{00A0}first line", "  second line")) == "first line\nsecond line")
    #expect(Hosting.prompt(.claude, screen: claude("❯\u{00A0}a", "", "  b")) == "a\n\nb")
    #expect(Hosting.prompt(.claude, screen: claude("❯\u{00A0}one row")) == "one row")
    #expect(Hosting.prompt(.claude, screen: claude("❯\u{00A0}a", "b")) == nil)
    #expect(Hosting.prompt(.claude, screen: [rule, "❯\u{00A0}a", "  b"].joined(separator: "\n")) == nil)
    #expect(Hosting.prompt(.claude, screen: claude("❯\u{00A0}\u{1B}[2mTry \"fix the tests\"\u{1B}[0m")) == nil)
}

@Test func codexsPromptIsItsGlyphRowAndTheIndentedRowsUnderIt() {
    #expect(Hosting.prompt(.codex, screen: codex("› first line", "  second line")) == "first line\nsecond line")
    #expect(Hosting.prompt(.codex, screen: codex("› only")) == "only")
    #expect(Hosting.prompt(.codex, screen: codex("› 1. Trust and continue", "  2. Quit")) == nil)
}

@Test func aMultiLineReplyWithAShortFirstLineIsKnownByItsWholePrompt() {
    let sent = "ok\n" + long
    #expect(Hosting.owned(sent: sent, agent: .claude, screen: claude("❯\u{00A0}ok", "  " + long)) == "ok")
    #expect(Hosting.owned(sent: sent, agent: .codex, screen: codex("› ok", "  " + long)) == "ok")
    #expect(Hosting.owned(sent: sent, agent: .claude, screen: claude("❯\u{00A0}ok", "  something else, typed at the Mac")) == nil)
    #expect(Hosting.owned(sent: "ok", agent: .claude, screen: claude("❯\u{00A0}ok")) == "ok")
    #expect(Hosting.owned(sent: "ok\nno", agent: .claude, screen: claude("❯\u{00A0}ok", "  no")) == "ok")
    #expect(Hosting.owned(sent: "ok\nno", agent: .claude, screen: claude("❯\u{00A0}ok", "  no thanks")) == nil)
    #expect(Hosting.owned(sent: "a\nb\nc", agent: .claude, screen: claude("❯\u{00A0}[Pasted text #2 +3 lines]")) == "[Pasted text #2 +3 lines]")
    #expect(Hosting.owned(sent: sent, agent: .claude, screen: claude("❯\u{00A0}\u{1B}[2mTry \"fix the tests\"\u{1B}[0m")) == nil)
}

#if canImport(Network)
@Test func aPoolRequestIsResentOnlyWhenItCantHaveBeenWritten() {
    let table: [(URLError.Code, unsent: Bool, cutOff: Bool)] = [
        (.notConnectedToInternet, true, false), (.cannotFindHost, true, false), (.dnsLookupFailed, true, false),
        (.cannotConnectToHost, true, false), (.dataNotAllowed, true, false), (.internationalRoamingOff, true, false),
        (.secureConnectionFailed, true, false), (.cannotLoadFromNetwork, true, false),
        (.networkConnectionLost, false, true), (.timedOut, false, true),
        (.badServerResponse, false, false), (.cancelled, false, false),
    ]
    for (code, unsent, cutOff) in table {
        #expect(PoolProxy.unsent(URLError(code)) == unsent && PoolProxy.cutOff(URLError(code)) == cutOff)
        #expect(PoolProxy.networkAway(URLError(code)) == (unsent || cutOff))
    }
    #expect(!PoolProxy.unsent(CancellationError()) && !PoolProxy.cutOff(CancellationError()))
}
#endif
