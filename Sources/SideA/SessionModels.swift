import AppKit
import SideACore
import SwiftUI

struct Snippet: Decodable, Hashable, Sendable {
    let uuid: String
    let role: String
    let ts: Double?
    let text: String
}

struct SessionInfo: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let agent: String
    let cwd: String?
    let branch: String?
    var title: String?
    let firstPrompt: String?
    let model: String?
    let firstTs: Double?
    let lastTs: Double?
    let cost: Double?
    let tokens: Int?
    let prompts: Int?
    let messages: Int?
    let forkedFrom: String?
    let forkPoint: String?
    let prUrl: String?
    let hits: Int?
    let snippets: [Snippet]?

    var name: String { title ?? firstPrompt ?? "Untitled session" }
    var project: String { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" }
    var isCodex: Bool { agent == "codex" }
}

struct MessageSegment: Sendable {
    enum Kind: Sendable { case prose, code, table }
    let kind: Kind
    var text = AttributedString()
    var rows: [[AttributedString]] = []
}

struct SessionMessage: Decodable, Sendable {
    let role: String
    let text: String
    let tools: [String]
    let uuid: String
    let ts: Double?
    let inherited: Bool
    let model: String?
    var segments: [MessageSegment] = []
    var key = ""
    private enum CodingKeys: String, CodingKey { case role, text, tools, uuid, ts, inherited, model }
}

struct SessionDetail: Decodable, Sendable {
    var session: SessionInfo
    var messages: [SessionMessage]
    let truncated: Int
    var forks: [SessionInfo]
    var parent: SessionInfo?
    /// Set when the page opened at a search hit: the hit's message, and how many newer messages were left out.
    let focus: String?
    let later: Int?
    let inheritedBefore: Int?

    func prepared() -> SessionDetail {
        var copy = self
        // One transcript entry can yield several messages (text, then tools), so the uuid alone isn't unique.
        var seen: [String: Int] = [:]
        for index in copy.messages.indices {
            let uuid = copy.messages[index].uuid
            copy.messages[index].key = "\(uuid)#\(seen[uuid, default: 0])"
            seen[uuid, default: 0] += 1
        }
        for index in copy.messages.indices where copy.messages[index].role == "assistant" {
            copy.messages[index].segments = MessageText.segments(copy.messages[index].text).map { kind, text in
                switch kind {
                case .code: MessageSegment(kind: .code, text: AttributedString(text))
                case .table: MessageSegment(kind: .table, rows: MessageText.table(text))
                case .prose: MessageSegment(kind: .prose, text: MessageText.markdown(text))
                }
            }
        }
        return copy
    }
}

struct LiveSession: Decodable, Identifiable, Hashable, Sendable {
    let pid: Int
    let sessionID: String?
    let name: String?
    let title: String?
    let cost: Double?
    let cwd: String?
    let status: String
    let waitingFor: String?
    let since: Double?
    /// The step a working session is on, its context in tokens, and the one thing most worth a look.
    var activity: String?
    var context: Int?
    var flag: Flag?
    /// Memory in MB of the session and everything it started, and how many processes that is.
    var memory: Int?
    var processes: Int?
    /// TCP ports its processes listen on, such as a dev server it started.
    var ports: [Port]?
    /// Start time in whole seconds, to tell this process from a later one with the same pid.
    var started: Double?
    /// The tmux session on Side A's server it runs in, when hosted.
    var hosted: String?
    /// "claude" or "codex", as the bridge says; kept raw so an agent this build doesn't know can't spoil the list.
    var agent: String?
    /// Claude Code's registry `kind`: "interactive" for a terminal session; anything else is headless (`claude -p`, the SDK).
    var kind: String?
    /// What the session runs with, as its statusline, hooks and transcript last said; nil where none did.
    var model: String?
    var effort: String?
    var mode: String?
    var fast: Bool?
    /// How full its context window is, 0–100, from its statusline.
    var contextPercent: Double?
    /// The background work its last Stop left running: subagents, shells, monitors.
    var backgroundTasks: [BackgroundTask]?
    /// Its newest prompt's uuid, which names the turn a turn diff reads, and when it was last compacted.
    var turnID: String?
    var compactedAt: Double?
    /// Those still going; a task's status is Claude Code's own word.
    var runningTasks: Int? { backgroundTasks.map { $0.filter { !["completed", "failed", "killed", "stopped", "cancelled"].contains($0.status ?? "") }.count } }
    var provider: AgentProvider { agent.flatMap(AgentProvider.init(rawValue:)) ?? .claude }
    var id: Int { pid }
    /// Idle half an hour or more: likely forgotten, still holding its memory.
    var stale: Bool { status == "idle" && Date().timeIntervalSince1970 - (since ?? .infinity) >= 1800 }
    private enum CodingKeys: String, CodingKey { case pid, sessionID = "id", name, title, cost, cwd, status, waitingFor, since, activity, context, flag, memory, processes, ports, started, hosted, agent, kind,
             model, effort, mode, fast, contextPercent, backgroundTasks, turnID, compactedAt }

    struct BackgroundTask: Decodable, Hashable, Sendable {
        let id: String?
        let type: String?
        let status: String?
        let description: String?
    }

    struct Port: Decodable, Hashable, Sendable {
        let port: Int
        let pid: Int
        let command: String?
        var started: Double? = nil
    }

    struct Flag: Decodable, Hashable, Sendable {
        /// stuck, loop, failing or bloated
        let kind: String
        let text: String
    }
}

enum TerminalApp: String, CaseIterable, Identifiable {
    case ghostty, iterm, warp, terminal
    var id: String { rawValue }
    var title: String { ["ghostty": "Ghostty", "iterm": "iTerm", "warp": "Warp", "terminal": "Terminal"][rawValue]! }
    var bundleID: String {
        ["ghostty": "com.mitchellh.ghostty", "iterm": "com.googlecode.iterm2", "warp": "dev.warp.Warp-Stable", "terminal": "com.apple.Terminal"][rawValue]!
    }
    var installed: Bool { self == .terminal || NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    static var firstInstalled: TerminalApp { allCases.first { $0.installed } ?? .terminal }
}
