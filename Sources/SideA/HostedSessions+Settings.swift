import Foundation
import os
import SideACore
import SideAProtocol

extension HostedSessions {
    /// Changes a hosted Claude's model, effort and mode for this session only. Model and effort go through `/model`'s
    /// picker and `/effort`'s slider and are applied with `s` ("use this session only"): the typed forms (`/model X`,
    /// `/effort X`) save the pick as the user's default for every session (Claude Code 2.1.303). The mode is Shift+Tab
    /// until the footer shows it. Every key follows a reading of the screen and nothing is typed to search; a screen
    /// Side A doesn't expect is cancelled with Esc and left for the Mac. Idle sessions only, under the composer lock
    /// replies take, so nothing is typed into it meanwhile.
    func change(_ name: String, model: String?, effort: String?, mode: String?) async throws -> Settings {
        guard let agent = sessions.first(where: { $0.name == name })?.agent else { throw HostedError.notHosted }
        guard agent == .claude else { throw HostedError.refused("Side A changes settings this way only in Claude.") }
        let match = try Self.pickable(model: model, effort: effort)
        await lock(Self.composer(name))
        defer { unlock(Self.composer(name)) }
        cancelVerifier(name)
        guard let pane = target(name) else { throw HostedError.unavailable }
        return try await change(pane, model: model, match: match, effort: effort, mode: mode)
    }

    /// The same for a Claude in a pane on the user's own tmux server. The caller holds that pane's lock
    /// (`TerminalTyping.lock`), which typed replies take too.
    func change(own: TerminalFocus.TmuxPane, model: String?, effort: String?, mode: String?) async throws -> Settings {
        let match = try Self.pickable(model: model, effort: effort)
        return try await change(Pane(tmux: own.tmux, server: ["-u", "-S", own.socket], id: own.pane),
                                model: model, match: match, effort: effort, mode: mode)
    }

    /// A pane `change` types into, and how to reach its tmux server: Side A's own, or the user's.
    struct Pane: Sendable {
        let tmux: String
        let server: [String]
        var environment: [String: String] = [:]
        let id: String
    }

    nonisolated static func pickable(model: String?, effort: String?) throws -> ((String) -> Bool)? {
        let match = try model.map { model in
            guard let match = Hosting.pickerMatch(model) else { throw HostedError.refused("Claude's model list can't pick \(model) for one session.") }
            return match
        }
        if let effort, !Hosting.claudeEfforts.contains(effort) { throw HostedError.refused("Claude has no \(effort) effort.") }
        return match
    }

    func change(_ pane: Pane, model: String?, match: ((String) -> Bool)?, effort: String?, mode: String?) async throws -> Settings {
        var done = Settings()
        if let match {
            (done.model, done.effort) = (model, try await pickModel(pane, match: match, effort: effort))
        } else if let effort {
            done.effort = try await pickEffort(pane, effort)
        }
        if let mode { done.mode = try await cycleMode(pane, to: mode) }
        return done
    }

    /// The model, and the effort with it when asked, from `/model`'s list; returns the effort it shows after.
    func pickModel(_ pane: Pane, match: (String) -> Bool, effort: String?) async throws -> String? {
        var shown = try await open(pane, "/model") { Hosting.modelPicker(screen: $0) }
        func down() async throws {
            let before = shown.row
            shown = try await step(pane, "Down") { Hosting.modelPicker(screen: $0).flatMap { $0.row == before ? nil : $0 } }
        }
        // Once round the list, which wraps: an alias stands for its family's first row, the newest.
        var rows = [shown.row: shown.label]
        while rows.count < 50 {
            try await down()
            guard rows[shown.row] == nil else { break }
            rows[shown.row] = shown.label
        }
        guard let wanted = rows.keys.sorted().first(where: { rows[$0].map(match) == true }) else {
            throw await cancel(pane, "Claude's model list doesn't have that model.")
        }
        while shown.row != wanted { try await down() }
        if let effort {
            guard let target = Hosting.claudeEfforts.firstIndex(of: effort) else { throw await cancel(pane, "Claude has no \(effort) effort.") }
            var tried: Set<String> = []
            while shown.effort != effort {
                guard let now = shown.effort, let at = Hosting.claudeEfforts.firstIndex(of: now) else {
                    throw await cancel(pane, "\(shown.label) takes no effort setting.")
                }
                // A model without the level steps over it; back where it was means it can't have it.
                guard tried.insert(now).inserted else { throw await cancel(pane, "\(shown.label) doesn't take \(effort) effort.") }
                let label = shown.label
                shown = try await step(pane, at < target ? "Right" : "Left", or: "\(shown.label) doesn't take \(effort) effort.") {
                    Hosting.modelPicker(screen: $0).flatMap { $0.label == label && $0.effort != now ? $0 : nil }
                }
            }
        }
        try await apply(pane, done: "Set model to \(shown.label)", confirming: shown.label)
        return shown.effort
    }

    func pickEffort(_ pane: Pane, _ effort: String) async throws -> String {
        var now = try await open(pane, "/effort") { Hosting.effortSlider(screen: $0) }
        guard let target = Hosting.claudeEfforts.firstIndex(of: effort) else { throw await cancel(pane, "Claude has no \(effort) effort.") }
        var tried: Set<String> = []
        while now != effort {
            guard tried.insert(now).inserted, let at = Hosting.claudeEfforts.firstIndex(of: now) else {
                throw await cancel(pane, "This model doesn't take \(effort) effort.")
            }
            let from = now
            now = try await step(pane, at < target ? "Right" : "Left", or: "This model doesn't take \(effort) effort.") {
                Hosting.effortSlider(screen: $0).flatMap { $0 == from ? nil : $0 }
            }
        }
        try await apply(pane, done: "Set effort level to \(effort)", confirming: effort)
        return effort
    }

    /// Shift+Tab until the footer names the mode. A mode outside the session's cycle (bypass in a session not started
    /// with it) brings it round to where it was.
    func cycleMode(_ pane: Pane, to mode: String) async throws -> String {
        let screen = try await composerScreen(pane)
        guard var now = Hosting.claudeMode(screen: screen) else { throw HostedError.refused("Side A can't read this session's mode.") }
        let start = now
        while now != mode {
            let from = now
            _ = await run(pane, ["send-keys", "-t", pane.id, "BTab"])
            let next = await waitFor(pane) { screen in
                Hosting.dialog(.claude, screen: screen) ? "" : Hosting.claudeMode(screen: screen).flatMap { $0 == from ? nil : $0 }
            }
            guard let next, !next.isEmpty else {
                throw await cancel(pane, next == nil ? "Shift+Tab didn't change this session's mode." : "Claude asked something on the way to that mode.")
            }
            if next == start { throw HostedError.refused("This session's Shift+Tab doesn't reach that mode.") }
            now = next
        }
        return now
    }

    /// The screen while the session can take a command: no question open, the composer up.
    func composerScreen(_ pane: Pane) async throws -> String {
        let screen = await capture(pane)
        if Hosting.dialog(.claude, screen: screen) { throw HostedError.sessionWaiting }
        guard Hosting.ready(.claude, screen: screen) else { throw HostedError.refused("That session isn't ready yet.") }
        return screen
    }

    /// Types a slash command into the empty composer and presses Enter once the list highlights that very command,
    /// then waits for the screen it opens.
    func open<Shown>(_ pane: Pane, _ command: String, _ read: @escaping (String) -> Shown?) async throws -> Shown {
        guard Hosting.composer(.claude, screen: try await composerScreen(pane)) == .empty else { throw HostedError.composerBusy }
        _ = await run(pane, ["send-keys", "-t", pane.id, "-l", command])
        let typed = await waitFor(pane) { screen in
            Hosting.composer(.claude, screen: screen) == .text(command) && Hosting.slashSuggestion(screen: screen) == command ? true : nil
        }
        guard typed != nil else {
            _ = await run(pane, ["send-keys", "-t", pane.id, "C-u"])
            throw HostedError.refused("Claude didn't offer \(command) here.")
        }
        _ = await run(pane, ["send-keys", "-t", pane.id, "Enter"])
        guard let shown = await waitFor(pane, seconds: 5, read) else { throw await cancel(pane, "Claude's \(command) didn't open as expected.") }
        return shown
    }

    /// One key, then the screen `read` accepts; cancelled with `failure` when it doesn't come.
    func step<Shown>(_ pane: Pane, _ key: String, or failure: String = "Claude's screen changed unexpectedly.",
                             _ read: @escaping (String) -> Shown?) async throws -> Shown {
        _ = await run(pane, ["send-keys", "-t", pane.id, key])
        guard let shown = await waitFor(pane, read) else { throw await cancel(pane, failure) }
        return shown
    }

    /// `s`, then the warm-cache confirm when it comes for exactly this target, then the composer and Claude's
    /// "… this session only" line. A hook's confirm, or any other screen, is cancelled.
    func apply(_ pane: Pane, done: String, confirming target: String) async throws {
        // The same words may be in the conversation already: only a new line counts.
        let before = await said(pane, done).count
        _ = await run(pane, ["send-keys", "-t", pane.id, "-l", "s"])
        enum Next { case confirm(Hosting.SwitchConfirm), back }
        let next = await waitFor(pane) { screen -> Next? in
            if let confirm = Hosting.switchConfirm(screen: screen) { return .confirm(confirm) }
            return Hosting.ready(.claude, screen: screen) ? .back : nil
        }
        switch next {
        case .confirm(.yesSelected(let to))? where to.lowercased() == target.lowercased():
            _ = await run(pane, ["send-keys", "-t", pane.id, "Enter"])
        case .back?: break
        case .confirm?: throw await cancel(pane, "Claude asks to confirm this switch. Confirm it on the Mac.")
        case nil: throw await cancel(pane, "Claude's screen changed unexpectedly.")
        }
        var line: String?
        for _ in 0..<25 where line == nil {
            let lines = await said(pane, done)
            if lines.count > before { line = lines.last } else { try? await Task.sleep(for: .milliseconds(80)) }
        }
        guard let line else { throw HostedError.failed("Side A couldn't tell whether Claude took the change.") }
        if !line.contains("this session only") {
            log.error("a session-only pick in \(pane.id, privacy: .public) didn't say so: \(line, privacy: .public)")
            throw HostedError.failed("Claude didn't confirm the change was for this session only.")
        }
        // The confirm can outlast the line by a moment; the next change starts from the composer.
        _ = await waitFor(pane, seconds: 3) { Hosting.ready(.claude, screen: $0) ? true : nil }
    }

    func said(_ pane: Pane, _ words: String) async -> [String] {
        Hosting.plainLines(await run(pane, ["capture-pane", "-p", "-J", "-t", pane.id, "-S", "-300"]).output).filter { $0.contains(words) }
    }

    /// Esc closes a picker, slider or confirm without picking, once per layer ("No, go back" returns to the picker);
    /// returns the error to throw.
    func cancel(_ pane: Pane, _ message: String) async -> HostedError {
        func open(_ screen: String) -> Bool {
            Hosting.modelPicker(screen: screen) != nil || Hosting.effortSlider(screen: screen) != nil
                || Hosting.switchConfirm(screen: screen) != nil || Hosting.dialog(.claude, screen: screen)
        }
        for _ in 0..<3 {
            let screen = await capture(pane)
            guard open(screen) else { break }
            _ = await run(pane, ["send-keys", "-t", pane.id, "Escape"])
            _ = await waitFor(pane, seconds: 1) { $0 != screen ? true : nil }
        }
        return .refused(message)
    }

    func run(_ pane: Pane, _ args: [String]) async -> (status: Int32, output: String) {
        let result = await Self.process(pane.tmux, pane.server + args, environment: pane.environment, timeout: 10)
        return (result.status, result.output)
    }

    func capture(_ pane: Pane) async -> String {
        await run(pane, ["capture-pane", "-p", "-e", "-J", "-t", pane.id]).output
    }

    func waitFor<Shown>(_ pane: Pane, seconds: Double = 2, _ read: (String) -> Shown?) async -> Shown? {
        let end = ContinuousClock.now + .seconds(seconds)
        while true {
            if let shown = read(await capture(pane)) { return shown }
            if ContinuousClock.now >= end { return nil }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    /// Where typing for a session goes: its agent's pane, never whichever pane is active in it now.
    func pane(_ name: String) -> String {
        sessions.first { $0.name == name }.map(\.pane).flatMap { $0.isEmpty ? nil : $0 } ?? "=\(name):"
    }

    func capture(_ name: String) async -> String {
        guard let pane = target(name) else { return "" }
        return await capture(pane)
    }

    func target(_ name: String) -> Pane? {
        tmux.map { Pane(tmux: $0, server: server, environment: environment, id: pane(name)) }
    }

    func waitFor<Shown>(_ name: String, seconds: Double = 2, _ read: (String) -> Shown?) async -> Shown? {
        guard let pane = target(name) else { return nil }
        return await waitFor(pane, seconds: seconds, read)
    }
}
