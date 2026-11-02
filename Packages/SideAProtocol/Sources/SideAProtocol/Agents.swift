import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "Codex" }
    public var cliName: String { self == .claude ? "Claude Code" : "Codex CLI" }
    public var setupURL: URL {
        URL(string: self == .claude ? "https://code.claude.com/docs/en/setup" : "https://developers.openai.com/codex/cli")!
    }
}
