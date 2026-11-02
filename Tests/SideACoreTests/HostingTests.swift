import Foundation
@testable import SideACore
import Testing

// Screens as `capture-pane -p -e` returned them from Claude Code 2.1.302 and Codex 0.156.1.
private let rule = String(repeating: "─", count: 40)
private let claudeFooter = "  \u{1B}[2m⏵⏵ auto mode on (shift+tab to cycle)\u{1B}[0m"

private func claude(_ composer: String, above: [String] = []) -> String {
    (above + [rule, composer, rule, claudeFooter]).joined(separator: "\n")
}

private func codex(_ composer: String, above: [String] = []) -> String {
    (above + ["", composer, "", "  GPT-6-Astra high · ~/code/app"]).joined(separator: "\n")
}

@Test func agentArgumentsForNewResumeAndFork() {
    #expect(Hosting.arguments(.claude, .new(model: nil)).isEmpty)
    #expect(Hosting.arguments(.claude, .new(model: "opus")) == ["--model", "opus"])
    #expect(Hosting.arguments(.claude, .resume("S")) == ["--resume", "S"])
    #expect(Hosting.arguments(.claude, .fork("S")) == ["--resume", "S", "--fork-session"])
    #expect(Hosting.arguments(.codex, .new(model: "gpt"), images: ["/a.png", "/b.jpg"]) == ["-m", "gpt", "-i", "/a.png,/b.jpg"])
    #expect(Hosting.arguments(.codex, .resume("S")) == ["resume", "S"])
    #expect(Hosting.arguments(.codex, .fork("S")) == ["fork", "S"])
}

@Test func permissionModesStartAsEachAgentsOwnFlags() {
    #expect(Hosting.permissionArguments(.claude, mode: "default") == ["--permission-mode", "default"])
    #expect(Hosting.permissionArguments(.claude, mode: "bypassPermissions") == ["--permission-mode", "bypassPermissions"])
    #expect(Hosting.permissionArguments(.claude, mode: "never") == nil)
    #expect(Hosting.permissionArguments(.codex, mode: "default") == [])
    #expect(Hosting.permissionArguments(.codex, mode: "never") == ["-a", "never"])
    #expect(Hosting.permissionArguments(.codex, mode: "dangerFullAccess") == ["-s", "danger-full-access"])
    #expect(Hosting.permissionArguments(.codex, mode: "plan") == nil)
    #expect(Hosting.permissionArguments(.claude, mode: "--dangerously-skip-permissions") == nil)
}

@Test func pastedTextLosesControlCharactersButKeepsLinesAndTabs() {
    #expect(Hosting.clean("a\r\nb\rc\td\u{1B}[201~e\u{7F}\u{07}\u{9B}f") == "a\nb\nc\td[201~ef")
    #expect(Hosting.clean("ünï 🙂;") == "ünï 🙂;")
    #expect(Hosting.clean(String(repeating: "é", count: Hosting.replyLimit)).utf8.count == Hosting.replyLimit)
}

@Test func onlyAllowlistedKeysCanBeSent() {
    #expect(Hosting.keyArguments("3") == ["-l", "3"])
    #expect(Hosting.keyArguments(" ") == ["-l", " "])
    #expect(Hosting.keyArguments("Escape") == ["Escape"])
    #expect(Hosting.keyArguments("C-c") == ["C-c"])
    for refused in ["0", "x", "C-d", "Enter;", "٣", "kill-server", ""] { #expect(Hosting.keyArguments(refused) == nil) }
}

@Test func claudesComposerIsTheNoBreakSpaceRowAndItsPlaceholderIsEmpty() {
    let echoed = ["❯ Reply with only the word pong; nothing else.", "⏺ pong"]
    #expect(Hosting.composer(.claude, screen: claude("\u{1B}[39m❯\u{00A0}\u{1B}[2mTry \"refactor <filepath>\"\u{1B}[0m", above: echoed)) == .empty)
    #expect(Hosting.composer(.claude, screen: claude("❯\u{00A0}                ", above: echoed)) == .empty)
    #expect(Hosting.composer(.claude, screen: claude("❯\u{00A0}hello there      ", above: echoed)) == .text("hello there"))
    #expect(Hosting.composer(.claude, screen: claude("❯\u{00A0}[Pasted text #1 +30 lines]")) == .text("[Pasted text #1 +30 lines]"))
    // An echoed prompt and a dialog row use a plain space, so neither is taken for the composer.
    #expect(Hosting.composer(.claude, screen: echoed.joined(separator: "\n")) == .none)
    #expect(Hosting.composer(.claude, screen: "  ❯ 1. Yes\n    2. Not now") == .none)
}

@Test func codexsComposerIsTheLastPromptRowThatIsNotAnOption() {
    let placeholder = codex("\u{1B}[1m›\u{1B}[0m \u{1B}[2mAsk Codex to do anything\u{1B}[0m", above: ["› Describe this image", "• Exclamation mark inside speech bubble."])
    #expect(Hosting.composer(.codex, screen: placeholder) == .empty)
    #expect(Hosting.composer(.codex, screen: codex("\u{1B}[1m›\u{1B}[0m typed")) == .text("typed"))
    #expect(Hosting.composer(.codex, screen: codex("› [Image #1]  abc")) == .text("[Image #1]  abc"))
    #expect(Hosting.composer(.codex, screen: "› 1. Trust and continue\n  2. Quit") == .none)
}

/// 2.1.303's footer, with the statusline above it: manual mode has no shift+tab hint at all.
@Test func claudesFooterNamesItsModeAndManualModeIsReady() {
    func screen(_ footer: String, above: [String] = []) -> String {
        (above + [rule, "❯\u{00A0}", rule, "  scratch/l4e/proj | Opus 5.5 | ctx: 6%", footer]).joined(separator: "\n")
    }
    let manual = screen("  \u{1B}[38;5;211m⏸ manual mode on\u{1B}[38;5;246m · ← 1 agent\u{1B}[39m")
    #expect(Hosting.ready(.claude, screen: manual))
    #expect(Hosting.claudeMode(screen: manual) == "default")
    #expect(Hosting.claudeMode(screen: screen("  ⏵⏵ accept edits on (shift+tab to cycle) · ← 1 agent")) == "acceptEdits")
    #expect(Hosting.claudeMode(screen: screen("  ⏸ plan mode on (shift+tab to cycle)")) == "plan")
    #expect(Hosting.claudeMode(screen: screen("  ⏵⏵ auto mode on (shift+tab to cycle)")) == "auto")
    #expect(Hosting.claudeMode(screen: screen("  ⏵⏵ bypass permissions on (shift+tab to cycle)")) == "bypassPermissions")
    // Only the footer counts, never the conversation above the composer.
    #expect(Hosting.claudeMode(screen: screen("  ? for shortcuts", above: ["⏺ Turn plan mode on with Shift+Tab: ⏸ plan mode on"])) == nil)
    #expect(Hosting.claudeMode(screen: "  ⏸ plan mode on") == nil)
}

@Test func dialogsAndTheTrustQuestionAreRecognised() {
    let ask = claude("❯\u{00A0}", above: ["  Teach auto mode about your environment?", "  ❯ 1. Yes", "    2. Not now"])
    #expect(Hosting.dialog(.claude, screen: ask))
    #expect(!Hosting.ready(.claude, screen: ask))
    #expect(!Hosting.dialog(.claude, screen: claude("❯\u{00A0}", above: ["❯ 1. is what I typed earlier"]).replacingOccurrences(of: "❯ 1.", with: "❯ one")))
    #expect(Hosting.ready(.claude, screen: claude("❯\u{00A0}")))
    // Claude now selects "No, exit" first, so Enter alone would quit.
    let claudeTrust = " Quick safety check: Is this a project you created or one you trust?\n\n ❯ No, exit\n   Yes, I trust this folder\n\n Enter to confirm · Esc to cancel"
    #expect(Hosting.trust(.claude, screen: claudeTrust) == .otherSelected)
    #expect(Hosting.trust(.claude, screen: claudeTrust.replacingOccurrences(of: " ❯ No, exit\n   Yes", with: "   No, exit\n ❯ Yes")) == .trustSelected)
    #expect(Hosting.dialog(.claude, screen: claudeTrust))
    let codexTrust = "  Trust this folder?\n› 1. Trust and continue\n  2. Quit\n  enter continue · esc quit"
    #expect(Hosting.trust(.codex, screen: codexTrust) == .trustSelected)
    #expect(Hosting.dialog(.codex, screen: codexTrust))
    #expect(Hosting.trust(.codex, screen: codex("› hi")) == nil)
}

@Test func enterIsPressedAgainOnlyForExactlyWhatSideAPasted() throws {
    let sent = "Please fix the failing test in IslandTests and rerun the suite"
    let shown = "Please fix the failing test in IslandTests and rerun"
    let expected = try #require(Hosting.owned(sent: sent, composer: .text(shown)))
    #expect(expected == shown)
    #expect(Hosting.verdict(.claude, expected: expected, screen: claude("❯\u{00A0}" + shown)) == .pressEnter)
    #expect(Hosting.verdict(.claude, expected: expected, screen: claude("❯\u{00A0}\u{1B}[2mTry \"fix lint errors\"\u{1B}[0m")) == .taken)
    #expect(Hosting.verdict(.claude, expected: expected, screen: "Session ended (status 0).") == .stop)
    // Someone typed more, or replaced it: ambiguous, so the user is asked instead.
    #expect(Hosting.verdict(.claude, expected: expected, screen: claude("❯\u{00A0}" + shown + " it")) == .unsent)
    // A different paste number is someone else's paste.
    let paste = try #require(Hosting.owned(sent: "a\nb\nc", composer: .text("[Pasted text #2 +3 lines]")))
    #expect(Hosting.verdict(.claude, expected: paste, screen: claude("❯\u{00A0}[Pasted text #3 +3 lines]")) == .unsent)
    // Codex drew its update prompt under an empty composer; that is never "taken".
    let update = codex("› \u{1B}[2mAsk Codex to do anything\u{1B}[0m") + "\n  Update available · 0.156.1 → 0.163.0\n› 1. Update now (runs `brew upgrade --cask codex`)\n  2. Skip"
    #expect(Hosting.verdict(.codex, expected: "hello", screen: update) == .unsent)
    // Short text must match whole; a draft that merely starts the same way is someone else's.
    #expect(Hosting.owned(sent: "yes", composer: .text("yes please do it")) == nil)
    #expect(Hosting.owned(sent: "yes", composer: .text("yes")) == "yes")
    #expect(Hosting.owned(sent: "fix it", composer: .text("[Pasted text #2 +3 lines]")) == nil)
    #expect(Hosting.owned(sent: sent, composer: .text("Something else entirely, typed on the Mac")) == nil)
    #expect(Hosting.owned(sent: sent, composer: .empty) == nil)
    // Pasted image paths become chips ahead of the text, in both CLIs.
    #expect(Hosting.owned(sent: "What is this?", composer: .text("[Image #2] [Image #3] What is this?")) == "[Image #2] [Image #3] What is this?")
    // Before they turn into chips, the photos are their quoted paths; the reply is still Side A's, then and after.
    let typed = "'/Users/a/Side A/runtime/uploads/20261018/79f1d249.jpg' '/Users/a/Side A/runtime/uploads/20261018/5406.JPG' What's in these photos?"
    let photos = try #require(Hosting.owned(sent: "What's in these photos?", composer: .text(typed)))
    #expect(Hosting.verdict(.claude, expected: photos, screen: claude("❯\u{00A0}" + typed)) == .pressEnter)
    #expect(Hosting.verdict(.claude, expected: photos, screen: claude("❯\u{00A0}[Image #1] [Image #2] What's in these photos?")) == .pressEnter)
    #expect(Hosting.verdict(.claude, expected: photos, screen: claude("❯\u{00A0}[Image #1] What's in these photos? and more")) == .unsent)
    #expect(Hosting.owned(sent: "What is this?", composer: .text("'/Users/x/Library/Application Support/a.jpg' What is this?")) != nil)
    #expect(Hosting.owned(sent: "What is this?", composer: .text("'/Users/x/notes.txt' What is this?")) == nil)
}

// Claude Code 2.1.303's own screens, captured from a throwaway session.
private let picker = """
   Select model
   Switch between Claude models. Your pick becomes the default for new sessions. For other/previous model names,
   specify with --model.
     1.  Default (recommended)  Opus 5.5 · Best for everyday, complex tasks
   ❯ 2.  Opus 5.5 ✔             For complex work and everyday tasks
     3.  Fable 5.1              For your toughest challenges
     4.  Sonnet 5.5             Most efficient for simpler tasks
   ↓ 10. Opus 4.8               Best for everyday, complex tasks
      … +3 models
   ◉ xHigh effort ←/→ to adjust
   Enter to set as default · s to use this session only · Esc to cancel
"""

private let slider = """
   Effort
                             Faster                             Smarter
                             ────────────────────▲─────────────────────      Ultracode  off
                             low     medium     high     xhigh      max      Tab to toggle
                                    ~1.5x the estimated cost of medium (the default)
   ←/→ to adjust · Enter to confirm · s for this session only · Esc to cancel
"""

@Test func theModelPickerShowsItsHighlightedRowAndEffort() throws {
    let shown = try #require(Hosting.modelPicker(screen: picker))
    #expect(shown.row == 2 && shown.label == "Opus 5.5" && shown.effort == "xhigh")
    let moved = picker.replacingOccurrences(of: "   ❯ 2.", with: "     2.").replacingOccurrences(of: "     1.  Default", with: "   ❯ 1.  Default")
        .replacingOccurrences(of: "◉ xHigh effort", with: "◐ Medium effort (default)")
    let top = try #require(Hosting.modelPicker(screen: moved))
    #expect(top.row == 1 && top.label == "Default (recommended)" && top.effort == "medium")
    #expect(Hosting.modelPicker(screen: picker.replacingOccurrences(of: "◉ xHigh effort ←/→ to adjust", with: "Effort not supported"))?.effort == nil)
    // The slash-command list above the composer isn't the picker.
    #expect(Hosting.modelPicker(screen: "  ❯ /model      Set the AI model for Claude Code") == nil)
}

@Test func theEffortSliderPointsAtTheLevelUnderItsMarker() {
    #expect(Hosting.effortSlider(screen: slider) == "high")
    #expect(Hosting.effortSlider(screen: slider.replacingOccurrences(of: "────────────────────▲─────────", with: "──────────────────────────────▲")) == "xhigh")
    #expect(Hosting.effortSlider(screen: slider.replacingOccurrences(of: "────────────────────▲", with: "▲────────────────────")) == "low")
    #expect(Hosting.effortSlider(screen: picker) == nil)
}

@Test func aSwitchConfirmIsAnsweredOnlyWhenYesForTheTargetIsSelected() {
    let confirm = """
       Switch model?
       Your next response will be slower and use more tokens
       This conversation is cached for the current model. Switching to Opus 5.5 means the full history gets re-read on
       your next message.
       ❯ 1. Yes, switch to Opus 5.5
         2. No, go back
    """
    #expect(Hosting.switchConfirm(screen: confirm) == .yesSelected(target: "Opus 5.5"))
    #expect(Hosting.switchConfirm(screen: confirm.replacingOccurrences(of: "❯ 1. Yes", with: "  1. Yes").replacingOccurrences(of: "  2. No", with: "❯ 2. No")) == .other)
    #expect(Hosting.switchConfirm(screen: confirm.replacingOccurrences(of: "Your next response will be slower and use more tokens", with: "A PreModelSwitch hook asked you to confirm")) == .other)
    #expect(Hosting.switchConfirm(screen: picker) == nil)
}

@Test func modelIdsMatchThePickersRows() {
    func matches(_ model: String, _ label: String) -> Bool { Hosting.pickerMatch(model)?(label) ?? false }
    #expect(matches("claude-sonnet-5-5", "Sonnet 5.5") && !matches("claude-sonnet-5-5", "Sonnet 5"))
    #expect(matches("claude-opus-4-8-20260101", "Opus 4.8"))
    #expect(matches("opus", "Opus 5.5") && matches("default", "Default (recommended)"))
    #expect(Hosting.pickerMatch("opus[1m]") == nil && Hosting.pickerMatch("claude-opus-5-5[1m]") == nil && Hosting.pickerMatch("gpt-5.5") == nil)
}

@Test func theHighlightedSlashCommandIsTheOneEnterRuns() {
    let typing = """
    ❯ /model
      ⎿  Set model to Opus 5.5 for this session only
      ❯ /model                                          Set the AI model for Claude Code (currently Opus 5.5 (1M context))
        /modal-serverless-gpu                           Serverless GPU cloud platform for running ML workloads.
    \(rule)
    ❯\u{00A0}/model
    """
    #expect(Hosting.slashSuggestion(screen: typing) == "/model")
    // A prompt echoed in the conversation isn't a list.
    #expect(Hosting.slashSuggestion(screen: "❯ /model\n  ⎿  Set model to Opus 5.5 for this session only\n\(rule)\n❯\u{00A0}") == nil)
}

@Test func theTrustQuestionNamesItsFolder() {
    // 2.1.303, captured from a throwaway folder.
    let question = """
     Accessing workspace:
     /Users/you/scratch/l4e/proj
     Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source
     project, or work from your team). If not, take a moment to review what's in this folder first.
     ❯ No, exit
       Yes, I trust this folder
     Enter to confirm · Esc to cancel
    """
    #expect(Hosting.trustFolder(screen: question) == "/Users/you/scratch/l4e/proj")
    #expect(Hosting.trustFolder(screen: claude("❯\u{00A0}")) == nil)
}
