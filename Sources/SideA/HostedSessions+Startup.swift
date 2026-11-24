import Foundation
import SideACore

/// Whether a session just started took, what a session that ended said last, and whether the one it replaces has quit.
extension HostedSessions {
    /// tmux makes the pane before the CLI checks its resume id, model or login, so a pane alone proves nothing.
    func survivedStartup(_ name: String, resuming: String? = nil, settle: Duration = .seconds(3), within: Duration = .seconds(12)) async -> Bool {
        let begun = ContinuousClock.now
        while true {
            try? await Task.sleep(for: .milliseconds(begun.duration(to: .now) < settle ? 500 : 1000))
            await refresh()
            guard sessions.contains(where: { $0.name == name }) else { return false }
            let ran = begun.duration(to: .now)
            if ran >= within { return true }
            guard ran >= settle else { continue }
            let up = await live()?.contains { $0.hosted == name && $0.sessionID != nil && (resuming == nil || $0.sessionID == resuming) }
            if up == true { return true }
        }
    }

    func lastWords(_ name: String) async -> String? {
        let file = runtime.appendingPathComponent("hosted/\(name)/last.txt")
        for _ in 0..<10 where !FileManager.default.fileExists(atPath: file.path) { try? await Task.sleep(for: .milliseconds(100)) }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("Session ended") }
        return line.map { String(Redact.secrets($0).prefix(300)) }
    }

    /// Up to 5 s for the process to go, its registry file with it.
    static func exited(_ session: LiveSession, registry: URL) async -> Bool {
        for _ in 0..<100 {
            let gone = !ProcessCheck.maySignal(pid: session.pid, started: session.started)
            if gone, !FileManager.default.fileExists(atPath: registry.path) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
