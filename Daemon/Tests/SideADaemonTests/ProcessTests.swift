import Foundation
import Testing
@testable import SideADaemonKit

@Test func aProgramsOutputExitStatusAndInputComeBack() async throws {
    let echoed = await Run.process("/bin/echo", ["hello", "world"])
    #expect(echoed.status == 0 && echoed.output == "hello world\n")
    let failed = await Run.process("/bin/sh", ["-c", "echo oops >&2; exit 3"])
    #expect(failed.status == 3 && failed.errors == "oops\n")
    let copied = await Run.process("/bin/cat", [], input: Data("from stdin".utf8))
    #expect(copied.output == "from stdin")
    let silent = await Run.process("/bin/cat", [])
    #expect(silent.status == 0 && silent.output.isEmpty)
    let missing = await Run.process("/no/such/program", [])
    #expect(missing.status == 127)
}

@Test func aProgramThatOutlivesItsLauncherDoesNotHoldTheCallUp() async throws {
    // The launcher exits at once, leaving a child that still has the output open, as `tmux new-session -d` does.
    let started = Date()
    let result = await Run.process("/bin/sh", ["-c", "sleep 5 &"], timeout: 20)
    #expect(result.status == 0 && Date().timeIntervalSince(started) < 4)
}

#if os(Linux)
@Test func aProcessThatEndedAndWasNeverReapedIsNotRunning() throws {
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/true"), nil]
    defer { for pointer in argv { free(pointer) } }
    try #require(posix_spawn(&pid, "/bin/true", nil, nil, argv, environ) == 0)
    // Ended and left for its parent to reap, as tmux 3.4 can leave a pane's agent: kill(pid, 0) still reaches it.
    var info = siginfo_t()
    try #require(waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0)
    #expect(kill(pid, 0) == 0 && Run.exited(Int(pid)) && !Run.running(Int(pid)))
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    #expect(Run.running(Int(getpid())) && !Run.exited(Int(getpid())))
}
#endif

@Test func aProgramThatRunsTooLongIsStopped() async throws {
    let result = await Run.process("/bin/sleep", ["30"], timeout: 0.3)
    #expect(result.timedOut && result.status != 0)
}
