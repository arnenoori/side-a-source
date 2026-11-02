import Foundation
import SideAProtocol

extension MacTools.Demo {
    /// What the demo's New Session and composer offer: the demo sessions' folders, and a short model list.
    static func sample(_ sessions: [RemoteSession], now: Date = .now) -> Self {
        let efforts: [Effort] = [.auto, .low, .medium, .high, .xhigh, .max]
        let claude = [ModelOption(id: "claude-opus-5-5", title: "Opus 5.5", agent: .claude, efforts: efforts, defaultEffort: .auto),
                      ModelOption(id: "claude-sonnet-5-5", title: "Sonnet 5.5", agent: .claude, efforts: efforts, defaultEffort: .auto),
                      ModelOption(id: "claude-haiku-5-5", title: "Haiku 5.5", agent: .claude, efforts: efforts, defaultEffort: .auto)]
        let codex = [ModelOption(id: "gpt-6-sol", title: "GPT-6-Sol", agent: .codex, efforts: [.low, .medium, .high, .xhigh], defaultEffort: .medium),
                     ModelOption(id: "gpt-6-luna", title: "GPT-6-Luna", agent: .codex, efforts: [.low, .medium, .high], defaultEffort: .medium)]
        var seen: Set<String> = []
        var projects: [RemoteProject] = []
        for (index, session) in sessions.enumerated() {
            guard let cwd = session.cwd, seen.insert(cwd).inserted else { continue }
            projects.append(RemoteProject(path: cwd, name: session.project, gitRoot: cwd, branch: session.branch,
                                          branches: [session.branch, "main"].compactMap { $0 },
                                          lastUsedAt: now.timeIntervalSince1970 - Double(index) * 3_600,
                                          liveSessions: sessions.filter { $0.cwd == cwd }.count))
        }
        projects.append(RemoteProject(path: "~/Documents/notes", name: "notes", lastUsedAt: now.timeIntervalSince1970 - 86_400 * 3))
        // As the Mac lists them: the built-ins, then the user's own commands and skills.
        let claudeCommands = [("/compact", "Summarize the conversation to free up context"), ("/clear", "Start over with an empty conversation"),
                              ("/review", "Review a pull request"), ("/model", "Choose the model"), ("/effort", "Choose how hard Claude thinks"),
                              ("/context", "Show what fills the context"), ("/init", "Write a CLAUDE.md for this project"),
                              ("/release-notes", "Draft the changelog from merged pull requests"), ("/frontend:review", "Review the UI against the design rules"),
                              ("/write-tests", "Add tests for the code that changed")].map { AgentOptions.Option(id: $0.0, label: $0.1) }
        let codexCommands = [("/model", "Choose the model and reasoning effort"), ("/compact", "Summarize the conversation to free up context"),
                             ("/review", "Review the current changes"), ("/status", "Show the session's settings and usage"),
                             ("/prompts:standup", "Summarize yesterday's commits"), ("$repo-lint", "Run the linters and fix what they find"),
                             ("$migrate", "Write and check a database migration")].map { AgentOptions.Option(id: $0.0, label: $0.1) }
        return Self(options: OptionsList(agents: [AgentOptions(agent: .claude, installed: true, models: claude, commands: claudeCommands),
                                                  AgentOptions(agent: .codex, installed: true, models: codex, commands: codexCommands)]),
                    projects: projects)
    }
}
