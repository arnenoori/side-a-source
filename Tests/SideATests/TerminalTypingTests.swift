import Foundation
@testable import SideA
import SideACore
import Testing

/// A fake Claude Code in a pane of a tmux server of its own, where the user's servers live, found the way a real
/// session's pane is: by its process.
private final class OwnTmux {
    let base = URL(fileURLWithPath: "/tmp").appendingPathComponent("sa-type-\(UUID().uuidString.prefix(8))")
    let socket = "/private/tmp/tmux-\(getuid())/sidea-type-\(UUID().uuidString.prefix(8))"
    let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    var submitted: URL { base.appendingPathComponent("submitted") }

    func start(_ arguments: String = "") async throws -> Int {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fake = base.appendingPathComponent("claude")
        try fakeClaude.replacingOccurrences(of: "sys.argv[1]", with: "'\(submitted.path)'").write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let started = await HostedSessions.process(tmux, ["-u", "-S", socket, "new-session", "-d", "-x", "100", "-y", "30", "exec \(fake.path) \(arguments)"], timeout: 10)
        try #require(started.status == 0, "tmux: \(started.errors)")
        var pid: Int?
        await eventually {
            pid = (try? String(contentsOf: URL(fileURLWithPath: submitted.path + ".pid"), encoding: .utf8)).flatMap { Int($0) }
            guard pid != nil else { return false }
            return await drawn(screen())
        }
        guard let pid else { throw TerminalTyping.Failure(message: "the fake never drew its screen") }
        return pid
    }

    private func drawn(_ screen: String) -> Bool { Hosting.ready(.claude, screen: screen) || Hosting.dialog(.claude, screen: screen) }

    func screen() async -> String { await HostedSessions.process(tmux, ["-u", "-S", socket, "capture-pane", "-p", "-e", "-J"], timeout: 5).output }
    func keys(_ text: String) async { _ = await HostedSessions.process(tmux, ["-u", "-S", socket, "send-keys", "-l", text], timeout: 5) }
    func lines() -> [String] { ((try? String(contentsOf: submitted, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    func stop() async {
        _ = await HostedSessions.process(tmux, ["-S", socket, "kill-server"], timeout: 5)
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.removeItem(atPath: socket)
    }
}

/// A session in the user's own tmux pane takes the message as typed input, past an Enter the CLI swallows, and
/// nothing is sent over a draft or a dialog.
@Test func aMessageIsTypedIntoASessionsOwnTmuxPane() async throws {
    let pane = OwnTmux()
    guard !pane.tmux.isEmpty else { return }
    do {
        let pid = try await pane.start()
        #expect(TerminalTyping.reach(pid: pid) == .tmux && TerminalTyping.inFront(pid))
        try await TerminalTyping.type("Please continue", into: pid, agent: .claude)
        #expect(pane.lines() == ["'Please continue'"])

        await pane.keys("half a thought")
        await eventually { Hosting.composer(.claude, screen: await pane.screen()) == .text("half a thought") }
        await #expect(throws: TerminalTyping.Failure(message: "The session's message field already holds a draft.")) {
            try await TerminalTyping.type("Please continue", into: pid, agent: .claude)
        }
        #expect(pane.lines() == ["'Please continue'"])
    } catch {
        await pane.stop()
        throw error
    }
    await pane.stop()

    let asking = OwnTmux()
    do {
        let pid = try await asking.start("untrusted")
        await #expect(throws: TerminalTyping.Failure(message: "The session is asking something; answer it first.")) {
            try await TerminalTyping.type("Please continue", into: pid, agent: .claude)
        }
        #expect(asking.lines().isEmpty)
    } catch {
        await asking.stop()
        throw error
    }
    await asking.stop()
}
