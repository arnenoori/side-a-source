import Foundation
@testable import SideACore
import Testing

@Test func readsTheEnvironmentAfterArgvInProcargs() {
    var procargs = Data([2, 0, 0, 0])
    procargs.append(Data("/usr/local/bin/claude\0\0\0claude\0WARP_FOCUS_URL=not-env\0WARP_FOCUS_URL=warp://session/ab12\0TERM=xterm\0\0".utf8))
    #expect(ProcessEnvironment.parse(procargs) == ["WARP_FOCUS_URL": "warp://session/ab12", "TERM": "xterm"])
    #expect(ProcessEnvironment.parse(Data([1, 0])).isEmpty)
    #expect(ProcessEnvironment.read(pid: getpid())?["PATH"] == ProcessInfo.processInfo.environment["PATH"])
    #expect(ProcessEnvironment.read(pid: 0) == nil)
}

@Test func claudeSlotFollowsClaudeCodesOwnRule() {
    let profile = "/Users/you/Library/Application Support/Side A/profiles/0f6c9a1e-1111-4222-8333-444455556666"
    #expect(ProcessEnvironment.claudeSlot(["CLAUDE_SECURESTORAGE_CONFIG_DIR": profile + "/", "CLAUDE_CONFIG_DIR": "/x/other"])
            == "0f6c9a1e-1111-4222-8333-444455556666")
    #expect(ProcessEnvironment.claudeSlot(["CLAUDE_CONFIG_DIR": "/x/other"]) == "other")
    // An empty secure-storage variable selects the Mac login even when a config dir is set.
    #expect(ProcessEnvironment.claudeSlot(["CLAUDE_SECURESTORAGE_CONFIG_DIR": "", "CLAUDE_CONFIG_DIR": "/x/other"]) == "mac")
    #expect(ProcessEnvironment.claudeSlot([:]) == "mac")
}

@Test func codexHomeNamesTheProfileItWritesTo() {
    let root = "/Users/you/Library/Application Support/Side A", home = "/Users/you"
    #expect(ProcessEnvironment.codexHome([:], root: root, home: home) == .mac)
    #expect(ProcessEnvironment.codexHome(["CODEX_HOME": "/Users/you/.codex/"], root: root, home: home) == .mac)
    #expect(ProcessEnvironment.codexHome(["CODEX_HOME": root + "/profiles/ab-12"], root: root, home: home) == .profile("ab-12"))
    #expect(ProcessEnvironment.codexHome(["CODEX_HOME": root + "/profiles/ab-12/sub"], root: root, home: home) == .other(root + "/profiles/ab-12/sub"))
    #expect(ProcessEnvironment.codexHome(["CODEX_HOME": "/tmp/codex"], root: root, home: home) == .other("/tmp/codex"))
}

@Test func readsArgvFromProcargs() {
    var procargs = Data([2, 0, 0, 0])
    procargs.append(Data("/bin/bash\0\0\0/bin/bash\0/x/releases-weekly.sh\0HOME=/Users/you\0\0".utf8))
    #expect(ProcessEnvironment.arguments(procargs) == ["/bin/bash", "/x/releases-weekly.sh"])
    #expect(ProcessEnvironment.arguments(Data([1, 0])).isEmpty)
    #expect(ProcessEnvironment.arguments(pid: getpid()).count == CommandLine.arguments.count)
}

@Test func originNamesTheScriptAShellOrInterpreterRuns() {
    #expect(ProcessEnvironment.origin(["/bin/bash", "/x/notes/releases-weekly.sh"]) == "releases-weekly.sh")
    #expect(ProcessEnvironment.origin(["/bin/sh", "-c", "FOO=1 /usr/local/bin/sweep.sh --all"]) == "sweep.sh")
    #expect(ProcessEnvironment.origin(["zsh", "-lc", "nightly"]) == "nightly")
    #expect(ProcessEnvironment.origin(["/opt/homebrew/bin/node", "--enable-source-maps", "/app/dist/agent.js"]) == "agent.js")
    #expect(ProcessEnvironment.origin(["/usr/bin/python3.12", "-u", "bot.py"]) == "bot.py")
    #expect(ProcessEnvironment.origin(["-zsh"]) == "zsh")
    #expect(ProcessEnvironment.origin(["/usr/sbin/cron"]) == "cron")
    #expect(ProcessEnvironment.origin([]) == nil)
}
