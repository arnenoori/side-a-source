import Foundation
@testable import SideA
import Testing

@Test func aChildThatFillsStderrStillFinishes() async {
    let run = await ProcessRunner.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' e >&2; echo done"], timeout: 10)
    #expect(!run.timedOut && run.status == 0)
    #expect(run.errors.count == 300_000)
    #expect(String(decoding: run.output, as: UTF8.self) == "done\n")
}

@Test func aRunPastItsTimeoutIsStopped() async {
    let run = await ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 0.1; done"], timeout: 0.5)
    #expect(run.timedOut && run.status != 0)
    #expect(run.elapsed < 5)
}

@Test func stdinIsTheInputOrNothing() async {
    let input = Data(String(repeating: "line\n", count: 40_000).utf8)
    let echoed = await ProcessRunner.run("/bin/cat", [], input: input, timeout: 10)
    #expect(echoed.output == input)
    let empty = await ProcessRunner.run("/bin/cat", [], timeout: 10)
    #expect(!empty.timedOut && empty.status == 0 && empty.output.isEmpty)
}

@Test func aFailureComesBackWithItsStatusAndStderr() async {
    let run = await ProcessRunner.run("/bin/sh", ["-c", "echo \"$SIDEA_RUNNER_TEST${HOME:+home}\" >&2; exit 3"],
                                      environment: ["SIDEA_RUNNER_TEST": "set-"], removing: ["HOME"], timeout: 10)
    #expect(run.status == 3 && run.launchError == nil)
    #expect(String(decoding: run.errors, as: UTF8.self) == "set-\n")
}

@Test func aMissingProgramSaysWhy() async {
    let run = await ProcessRunner.run("/nonexistent/side-a-runner-test", [], timeout: 10)
    #expect(run.launchError != nil && run.status == -1 && run.output.isEmpty)
}

@Test func aChildHoldingThePipeOpenDoesNotOutlastTheTimeout() async {
    let run = await ProcessRunner.run("/bin/sh", ["-c", "echo early; sleep 6 & exit 0"], timeout: 0.5)
    #expect(run.timedOut)
    #expect(run.elapsed < 4)
}
