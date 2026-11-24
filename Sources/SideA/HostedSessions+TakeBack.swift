import Foundation
import SideACore

/// A Stop's take-back of the phone's replies from a hosted pane's prompt.
extension HostedSessions {
    /// After Esc, Claude Code puts the messages it held unread back into its prompt, where nothing sends them; a Stop
    /// isn't a send, so they come off it. Only when the whole prompt is the phone's replies, the newest of `texts`
    /// (the oldest may have been read just before Esc), and no one at the Mac typed since: anything else stays put.
    /// A long step can take seconds to stop and redraw, hence up to `takeBackWait`.
    func takeBack(_ name: String, sent texts: [String]) async -> ReplyReceipts.TakeBack {
        guard !texts.isEmpty, let agent = sessions.first(where: { $0.name == name })?.agent else { return .absent }
        await lock(Self.composer(name))
        defer { unlock(Self.composer(name)) }
        let activity = await macActivity(name)
        for _ in 0..<Int(Self.takeBackWait / Self.takeBackEvery) {
            try? await Task.sleep(for: Self.takeBackEvery)
            let screen = await capture(name)
            if Hosting.dialog(agent, screen: screen) { return .left }
            guard case .text = Hosting.composer(agent, screen: screen) else { continue }
            guard let shown = Hosting.prompt(agent, screen: screen), let taken = Self.taken(texts, shown: shown),
                  await macActivity(name) <= activity else { return .left }
            // A placeholder deletes as one, so the screen's own count is the most it needs.
            let count = taken.placeholder ? shown.count : max(shown.count, texts[taken.from...].joined(separator: "\n").count)
            return await clear(name, agent: agent, shown: shown, count: count, activity: activity) ? .cleared(from: taken.from) : .left
        }
        return .absent
    }

    nonisolated static let takeBackWait: Duration = .seconds(8)
    nonisolated static let takeBackEvery: Duration = .milliseconds(250)

    /// Esc can give a long or multi-line reply back as Claude's paste placeholder (`[Pasted text #2 +3 lines]`), not its words.
    nonisolated static func taken(_ texts: [String], shown: String) -> (from: Int, placeholder: Bool)? {
        let prompt = ReplyText.squashPasted(shown)
        if let from = texts.indices.first(where: { ReplyText.squashPasted(texts[$0...].joined(separator: "\n")) == prompt }) { return (from, false) }
        guard let token = ReplyText.placeholder(inSquashed: prompt) else { return nil }
        let before = String(prompt[..<token.lowerBound]), after = String(prompt[token.upperBound...])
        for from in texts.indices {
            let run = Array(texts[from...])
            for (at, text) in run.enumerated() where ReplyText.long(text) {
                if ReplyText.squashPasted(run[..<at].joined(separator: "\n")) == before, ReplyText.squashPasted(run[(at + 1)...].joined(separator: "\n")) == after {
                    return (from, true)
                }
            }
        }
        return nil
    }

    /// Backspaces in rounds until the prompt is empty: the screen shows each row without its indent, so one count can fall
    /// short. Another round only while what's left is the same prompt cut shorter from its end (one that took only blank
    /// rows and indents counts) and no one at the Mac typed; anything else, or too many rounds or keys, stops it.
    private func clear(_ name: String, agent: Hosting.Agent, shown: String, count: Int, activity: Double) async -> Bool {
        let matched = ReplyText.squashPasted(shown)
        var keys = count + 4, left = shown.count, budget = 2 * count + 64
        for _ in 0..<6 where keys > 0 && keys <= budget {
            budget -= keys
            let pressed = await run(["send-keys", "-t", pane(name), "-N", String(keys), "BSpace"]).status
            if pressed != 0 { RemoteLog.shared("hosted: a Stop's backspaces failed (tmux exit \(pressed))") }
            if await waitFor(name, seconds: left == shown.count ? 2 : 1, { Hosting.composer(agent, screen: $0) == .empty ? true : nil }) != nil { return true }
            let screen = await capture(name)
            if Hosting.composer(agent, screen: screen) == .empty { return true }
            guard !Hosting.dialog(agent, screen: screen), case .text = Hosting.composer(agent, screen: screen), let rest = Hosting.prompt(agent, screen: screen),
                  rest.count < left, matched.hasPrefix(ReplyText.squashPasted(rest)), await macActivity(name) <= activity else { return false }
            left = rest.count
            keys = min(rest.count + 4, budget)
        }
        return false
    }
}
