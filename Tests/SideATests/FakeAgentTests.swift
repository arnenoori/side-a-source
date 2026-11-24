import Foundation
@testable import SideA
import SideACore
import Testing

enum FakeAgent {
    static func script(_ agent: Hosting.Agent, out: URL, work: Double) throws -> String {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/FakeAgents/fake-\(agent == .claude ? "claude" : "codex").py")
        return try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "__OUT__", with: out.path).replacingOccurrences(of: "__WORK__", with: String(work))
    }
}

/// Type → Enter, then Stop → take-back, through a real tmux pane: the reply is submitted once, a second one sent while
/// the turn works is queued, and after Esc puts it back in the prompt the take-back finds exactly it there and clears it.
@MainActor
@Test(.enabled(if: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }))
func hostedFakeClaudeTakesAReplyAndGivesBackWhatAStopLeftQueued() async throws {
    let fixture = try HostedFixture()
    try FakeAgent.script(.claude, out: fixture.submitted, work: 60)
        .write(to: fixture.base.appendingPathComponent("bin/claude"), atomically: true, encoding: .utf8)
    let hosted = HostedSessions(root: fixture.root, environment: fixture.environment, bridge: fixture.bridge)
    await hosted.install()
    do {
        try #require(hosted.available)
        let name = try await hosted.start(.init(agent: .claude, cwd: fixture.project.path, mode: .new(model: nil)))
        #expect(await eventually { Hosting.ready(.claude, screen: await hosted.capture(name)) })

        try await hosted.reply(name, text: "Run the tests")
        #expect(await eventually(5) { fixture.lines() == ["'Run the tests'"] }, "\(fixture.lines())")
        #expect(await eventually(5) { await hosted.capture(name).contains("esc to interrupt") })

        try await hosted.reply(name, text: "then fix what fails", working: true)
        #expect(await eventually(5) { Hosting.plainLines(await hosted.capture(name)).contains("  ⎿ then fix what fails") })

        try await hosted.interrupt(name, working: true)
        #expect(await hosted.takeBack(name, sent: ["then fix what fails"]) == .cleared(from: 0))
        #expect(Hosting.composer(.claude, screen: await hosted.capture(name)) == .empty)
        // Submitted once, never the queued one; the Stop was one Esc.
        #expect(fixture.lines() == ["'Run the tests'", "ESC"])
    } catch {
        Issue.record(error)
    }
    await fixture.cleanUp()
}
