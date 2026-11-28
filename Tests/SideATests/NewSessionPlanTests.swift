import Foundation
@testable import SideA
import SideAProtocol
import Testing

@Test func theSheetsChoicesBecomeOneStartPerAgent() {
    var plan = NewSessionPlan(cwd: "/r/app", agents: [.claude], model: "opus", effort: "high", account: "work", mode: .plan, worktree: true, base: "main")
    let one = plan.starts(prompt: "  build it \n", hosting: true, attachments: ["u1"])
    #expect(one == [StartHosted(cwd: "/r/app", agent: .claude, model: "opus", effort: "high", worktree: true, accountID: "work", prompt: "build it",
                                attachments: ["u1"], permissionMode: .plan)])
    // Defaults are left for the agent to pick, and an empty prompt starts an idle session.
    plan = NewSessionPlan(cwd: "/r/app", agents: [.codex])
    #expect(plan.starts(prompt: " ", hosting: true) == [StartHosted(cwd: "/r/app", agent: .codex)])
    // Without hosting the agent is typed into a tab: no worktree, account, mode or photos to promise.
    plan = NewSessionPlan(cwd: "/r/app", agents: [.claude], model: "opus", account: "work", mode: .acceptEdits, worktree: true)
    #expect(plan.starts(prompt: "x", hosting: false, attachments: ["u1"]) == [StartHosted(cwd: "/r/app", agent: .claude, model: "opus", prompt: "x")])
    // A mode the agent doesn't have is not sent.
    plan = NewSessionPlan(cwd: "/r/app", agents: [.codex], mode: .acceptEdits)
    #expect(plan.starts(prompt: "", hosting: true)[0].permissionMode == nil)
}

@Test func twoAgentsEachGetAWorktreeAndTheirOwnLastSettings() {
    var remembered = SessionPrefs.Start()
    remembered.agents["claude"] = .init(model: "opus", effort: "high", account: "work", mode: "plan")
    remembered.agents["codex"] = .init(model: "gpt-5", effort: "", account: "", mode: "acceptEdits")
    let plan = NewSessionPlan(cwd: "/r/app", agents: [.claude, .codex], model: "ignored", account: "ignored", mode: .bypassPermissions)
    let starts = plan.starts(prompt: "same task", hosting: true, remembered: remembered)
    #expect(starts.map(\.agent) == [.claude, .codex] && starts.allSatisfy { $0.worktree && $0.prompt == "same task" && $0.accountID == nil })
    #expect(starts[0].model == "opus" && starts[0].effort == "high" && starts[0].permissionMode == .plan)
    // Codex has no accept-edits mode, so its remembered one isn't sent.
    #expect(starts[1].model == "gpt-5" && starts[1].effort == nil && starts[1].permissionMode == nil)
    // Nothing to confirm: the sheet's own mode isn't used for several.
    #expect(plan.raising(hosting: true) == nil)
}

@Test func aModeThatLiftsTheChecksIsAskedAboutAndKeysStepThroughChoices() {
    #expect(NewSessionPlan(agents: [.claude], mode: .bypassPermissions).raising(hosting: true) == .bypassPermissions)
    #expect(NewSessionPlan(agents: [.claude], mode: .auto).raising(hosting: true) == .auto)
    #expect(NewSessionPlan(agents: [.claude], mode: .acceptEdits).raising(hosting: true) == nil)
    #expect(NewSessionPlan(agents: [.claude], mode: .bypassPermissions).raising(hosting: false) == nil)
    #expect(NewSessionPlan.next(after: "", in: ["", "a", "b"]) == "a" && NewSessionPlan.next(after: "b", in: ["", "a", "b"]) == "")
    #expect(NewSessionPlan.next(after: "gone", in: ["", "a"]) == "" && NewSessionPlan.next(after: "x", in: [String]()) == "x")
    #expect(NewSessionPlan.next(after: AgentProvider.claude, in: [.claude, .codex]) == .codex)
}

@Test func anOlderRecordOfChoicesStillReads() throws {
    let old = #"{"folder":"/r/app","agent":"claude","agents":{"claude":{"model":"opus","effort":"high","account":"work"}},"folders":{}}"#
    let start = try JSONDecoder().decode(SessionPrefs.Start.self, from: Data(old.utf8))
    #expect(start.agents["claude"] == .init(model: "opus", effort: "high", account: "work", mode: ""))
}

@MainActor @Test func fanningOutMakesALaunchPerAgentAndABaseOnlyForAWorktree() async {
    let sessions = AccountStore(demo: true).sessions
    let plan = NewSessionPlan(cwd: "/r/app", agents: [.claude, .codex])
    for (index, start) in plan.starts(prompt: "both", hosting: true).enumerated() {
        sessions.launch(start, terminal: false, select: index == 0, base: "main")
    }
    #expect(sessions.desk.launches.map(\.request.agent) == [.codex, .claude] && sessions.desk.launches.allSatisfy { $0.base == "main" })
    #expect(Set(sessions.desk.launches.map(\.key)).count == 2 && sessions.desk.selectedLaunch == sessions.desk.launches.last?.id)
    sessions.launch(StartHosted(cwd: "/r/app", agent: .claude), terminal: false, select: false, images: ["/p/a.png"], base: "main")
    #expect(sessions.desk.launches.first?.base == nil && sessions.desk.launches.first?.images == ["/p/a.png"])
    sessions.desk.launches.map(\.id).forEach(sessions.dismiss)
}

@MainActor @Test func aBranchNameThatCouldBeAnOptionIsRefused() async {
    let commands = SessionCommands(store: AccountStore(demo: true))
    do {
        _ = try await commands.start(StartHosted(cwd: "/r/app", agent: .claude, worktree: true), origin: "mac", base: "--upload-pack=x")
        Issue.record("it started")
    } catch {
        #expect(error.message.contains("branch"))
    }
}

@Test func aRestartCarriesWhatWasTypedAfterTheHandoff() {
    let handoff = Handoff(goal: "Ship it", failed: "", next: "", lastMessages: "", cwd: "/r/app", project: "app")
    let plain = SessionCommands.restartPrompt(RestartRequest(handoff: handoff))
    #expect(plain == SessionCommands.prompt(handoff))
    #expect(SessionCommands.restartPrompt(RestartRequest(handoff: handoff, message: "  ")) == plain)
    #expect(SessionCommands.restartPrompt(RestartRequest(handoff: handoff, message: "and add tests")) == plain + "\n\nand add tests")
}

@Test func aRememberedModeThatLiftsTheChecksNeverStartsUnasked() {
    var remembered = SessionPrefs.Start()
    remembered.agents["claude"] = .init(mode: "bypassPermissions")
    let starts = NewSessionPlan(cwd: "/r/app", agents: [.claude, .codex]).starts(prompt: "x", hosting: true, remembered: remembered)
    #expect(starts.allSatisfy { $0.permissionMode == nil })
}

@Test func aBranchWithGitsOwnPunctuationIsABase() {
    #expect(SessionCommands.safeBranch(nil) && SessionCommands.safeBranch("feat+login") && SessionCommands.safeBranch("release/2.0@x"))
    #expect(!SessionCommands.safeBranch("-x") && !SessionCommands.safeBranch("a b") && !SessionCommands.safeBranch("") && !SessionCommands.safeBranch("a\nb"))
}
