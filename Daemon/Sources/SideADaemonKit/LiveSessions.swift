import Foundation
import SideACore
import SideAProtocol

/// One row of the bridge's `sessions live`: a Claude Code or Codex process that is running now.
struct LiveRow: Sendable, Equatable {
    var id: String?
    var pid: Int
    var agent: AgentProvider
    var name: String?
    var title: String?
    var cwd: String?
    var status: String
    var waitingFor: String?
    var since: Double?
    var started: Double?
    var hosted: String?
    var activity: String?
    var context: Int?
    var contextPercent: Double?
    var cost: Double?
    var mode: String?
    var model: String?
    var effort: String?
    var turnID: String?
    var memory: Int?
    var ports: [ListeningPort]
    var flag: SessionFlag?
    var headless: Bool

    var key: SessionKey { id ?? "pid-\(pid)-\(Int(started ?? 0))" }

    static func parse(_ data: Data) -> [LiveRow] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let rows = object["sessions"] as? [[String: Any]] else { return [] }
        return rows.compactMap(LiveRow.init)
    }

    init?(_ row: [String: Any]) {
        guard let pid = (row["pid"] as? NSNumber)?.intValue, let agent = AgentProvider(rawValue: row["agent"] as? String ?? "") else { return nil }
        func text(_ key: String) -> String? { (row[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func number(_ key: String) -> Double? { (row[key] as? NSNumber)?.doubleValue }
        self.pid = pid; self.agent = agent
        id = text("id"); name = text("name"); title = text("title"); cwd = text("cwd")
        status = text("status") ?? "idle"; waitingFor = text("waitingFor")
        since = number("since"); started = number("started"); hosted = text("hosted"); activity = text("activity")
        context = number("context").map(Int.init); contextPercent = number("contextPercent"); cost = number("cost")
        mode = text("mode"); model = text("model"); effort = text("effort"); turnID = text("turnID")
        memory = number("memory").map(Int.init)
        ports = ((row["ports"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let port = (entry["port"] as? NSNumber)?.intValue else { return nil }
            return ListeningPort(port: port, process: (entry["command"] as? String) ?? (entry["process"] as? String) ?? "")
        }
        flag = (row["flag"] as? [String: Any]).flatMap { flag in
            guard let kind = flag["kind"] as? String, let words = flag["text"] as? String else { return nil }
            return SessionFlag(kind: .init(rawValue: kind), text: words)
        }
        headless = (row["kind"] as? String).map { $0 != "interactive" } ?? false
    }
}

extension SessionBridge {
    func live() async throws -> [LiveRow] { LiveRow.parse(try await result(["live"], timeout: .seconds(20))) }
}

/// What a row means to a phone, from what a headless host can know: the registry's status, whether tmux hosts it, and the
/// agent's own words. Nothing here claims a hook or app server the daemon doesn't run.
enum LiveBuilder {
    static func status(_ row: LiveRow) -> SessionStatus {
        switch row.status {
        case "busy", "shell": .working
        case "waiting": .waiting
        case "idle": .idle
        default: .unknown
        }
    }

    static func project(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        let parts = cwd.split(separator: "/")
        if let at = parts.firstIndex(of: ".worktrees") ?? parts.firstIndex(of: "worktrees"), at > 0, parts[at - 1] == ".claude", at >= 2 { return String(parts[at - 2]) }
        return parts.last.map(String.init) ?? ""
    }

    static func abilities(_ row: LiveRow, status: SessionStatus) -> Set<SessionAbility> {
        var abilities: Set<SessionAbility> = row.id == nil ? [] : [.transcript]
        guard row.hosted != nil else { return abilities }
        abilities.insert(.end)
        if status == .idle || status == .working || status == .waiting { abilities.insert(.type) }
        if status == .working { abilities.insert(.interrupt) }
        return abilities
    }

    static func reasons(_ row: LiveRow, status: SessionStatus) -> [String: String]? {
        row.hosted == nil ? [SessionAbility.type.rawValue: "Reply from the phone needs a session Side A started. Start one from the phone, or run it under `sidead host`."] : nil
    }

    static func session(_ row: LiveRow) -> RemoteSession {
        let status = status(row)
        let project = project(row.cwd)
        var session = RemoteSession(id: row.key, conversationID: row.id, agent: row.agent, title: row.title ?? row.name ?? (project.isEmpty ? row.key : project),
                                    cwd: row.cwd, project: project, worktree: row.cwd?.contains("/.claude/worktrees/") == true || row.cwd?.contains("/.worktrees/") == true,
                                    model: row.model, effort: row.effort, status: status, waitingFor: row.waitingFor,
                                    statusAt: row.since.map { $0 > 1e11 ? $0 / 1000 : $0 }, step: row.activity, context: row.context, flag: row.flag, cost: row.cost,
                                    hosted: row.hosted, abilities: abilities(row, status: status), headless: row.headless, ports: row.ports.isEmpty ? nil : row.ports,
                                    memoryBytes: row.memory.map { $0 << 20 }, contextPercent: row.contextPercent,
                                    abilityReasons: reasons(row, status: status), turnID: row.turnID)
        if row.model != nil || row.effort != nil || row.mode != nil {
            session.settings = SessionSettings(model: row.model, effort: row.effort.map { Effort(rawValue: $0) }, mode: row.mode.map { PermissionMode(rawValue: $0) })
        }
        return session
    }

    /// A hosted pane whose agent hasn't registered yet: a row of its own, `tmux-<name>`, so the phone sees the start.
    static func starting(_ pane: HostedTmux.Pane) -> RemoteSession {
        RemoteSession(id: "tmux-\(pane.name)", agent: AgentProvider(rawValue: pane.agent) ?? .claude, title: LiveBuilder.project(pane.cwd), cwd: pane.cwd,
                      project: project(pane.cwd), status: pane.dead ? .exited : .starting, hosted: pane.name, abilities: pane.dead ? [] : [.end])
    }

    static func hosted(_ pane: HostedTmux.Pane, session: SessionKey?) -> HostedSession {
        HostedSession(name: pane.name, agent: AgentProvider(rawValue: pane.agent) ?? .claude, cwd: pane.cwd, project: project(pane.cwd),
                      worktree: pane.worktree.isEmpty ? nil : Worktree(path: pane.worktree, branch: pane.branch), sessionID: session,
                      createdAt: pane.created, macAttached: false, viewers: 0, alive: !pane.dead, exitStatus: pane.exitStatus)
    }
}
