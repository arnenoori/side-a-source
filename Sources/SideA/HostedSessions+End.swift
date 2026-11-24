import Foundation
import os
import SideACore
import SideAProtocol

extension HostedSessions {
    /// The phone's End: the agent gets the hangup a closed terminal sends, and its pane then goes the way of any
    /// session that ends (last screen kept, Side A's clean worktree removed). Claude and Codex exit on it. The
    /// pane's shell exits whatever the agent does, so one that outlived it would run on unseen: its process
    /// group is noted first, then sent SIGTERM after 3 s and SIGKILL after 2 more.
    func end(_ name: String) async throws {
        guard sessions.contains(where: { $0.name == name }) else { throw HostedError.notHosted }
        cancelVerifier(name)
        let listed = await run(["display-message", "-p", "-t", pane(name), "#{pane_pid}"])
        guard let pid = listed.output.split(separator: "\n").first.flatMap({ pid_t($0) }), pid > 1 else {
            throw HostedError.failed("Side A couldn't find that session's process.")
        }
        ending.insert(name)
        let groups = Set(Self.children(of: pid).map { getpgid($0) }).subtracting([-1, 0, 1, getpgrp()])
        kill(pid, SIGHUP)
        for (signal, wait) in [(SIGTERM, 3.0), (SIGKILL, 2.0)] {
            guard await Self.running(groups, within: wait) else { break }
            for group in groups { killpg(group, signal) }
        }
        await refresh()
    }

    nonisolated static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(0, Int(count))))
    }

    /// Whether any of these process groups still has a process `seconds` from now; false as soon as none has.
    static func running(_ groups: Set<pid_t>, within seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while true {
            let left = groups.contains { killpg($0, 0) == 0 }
            if !left || Date() >= end { return left }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
