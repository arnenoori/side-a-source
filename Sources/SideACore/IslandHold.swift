import Foundation

/// When a request goes back to the terminal unanswered.
public enum IslandHold {
    /// Codex shows its own prompt only after the hook returns, so a terminal session gets it back after two minutes.
    public static let terminal: TimeInterval = 120
    /// Under the hook's own 24 h timeout, so Side A answers first. Nobody sits at a hosted session's terminal.
    public static let hosted: TimeInterval = 86_400 - 120

    /// A Claude subagent's request goes back too: one running in the background has no prompt, and Claude Code
    /// denies it when the hook doesn't answer.
    public static func handBack(agent: IslandAgent, headless: Bool, hosted: Bool, subagent: Bool = false) -> TimeInterval? {
        if headless { return terminal }
        if hosted { return agent == .codex ? Self.hosted : nil }
        return agent == .codex || subagent ? terminal : nil
    }
}
