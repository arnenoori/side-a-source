import Foundation
import SideACore

/// Wire twins, built only here, from the app's own state. The phone never sees a hook payload, a Keychain slot,
/// a pid it could act on, or a raw permission rule.
@MainActor
enum WireBuilders {
    /// Claude's status page only: Side A doesn't watch OpenAI's.
    @MainActor static func incidents(_ store: AccountStore) -> [Incident] {
        guard let outage = store.outage else { return [] }
        return [Incident(id: outage.id, provider: .claude, title: outage.name, status: .init(rawValue: outage.status ?? "investigating"),
                         url: outage.url ?? "https://status.claude.com", startedAt: outage.startedAt)]
    }

    /// A conversation from the index, with Side A's own pin, title and archive. Search's highlight marks are dropped.
    @MainActor static func past(_ info: SessionInfo, sessions: SessionStore) -> PastSession {
        let custom = sessions.names[info.id]
        let snippet = info.snippets?.first
        return PastSession(id: info.id, agent: info.isCodex ? .codex : .claude, title: custom ?? info.name, project: info.project, cwd: info.cwd,
                           branch: info.branch, firstAt: info.firstTs, lastAt: info.lastTs,
                           snippet: snippet.map { $0.text.replacingOccurrences(of: "\u{02}", with: "").replacingOccurrences(of: "\u{03}", with: "") },
                           snippetUUID: snippet?.uuid, parentID: info.forkedFrom, pinned: sessions.isPinned(info.id),
                           archived: sessions.isArchived(info.id), customTitle: custom)
    }

    static let maxString = RemoteTranscript.maxString

    /// What was asked, kept with its answer in the approvals log.
    static func summary(_ item: Island.Pending) -> RequestSummary {
        RequestSummary(tool: item.request.tool, headline: item.request.headline, sessionTitle: item.title, agent: item.request.agent.provider)
    }

    static func request(_ item: Island.Pending) -> RemoteRequest {
        let request = item.request
        let (action, truncated) = cut(request.action.escaped)
        let gate = AllowGate.of(request, projects: Island.projects(request.cwd))
        ShownGates.shared[item.id] = gate
        // Always is never offered where it would skip Face ID.
        let noAlways = !request.offersAlways || gate == .biometric
        return RemoteRequest(id: item.id.uuidString.lowercased(), sessionID: request.sessionID, agent: request.agent.provider, tool: DisplayText.escaped(request.tool),
                             action: action, headline: request.headline, detail: request.detail, reason: request.reason.map(DisplayText.escaped), risk: request.risk,
                             riskReason: request.riskReason,
                             suggestions: noAlways ? [] : request.suggestions.map { RemoteSuggestion(id: RemoteAnswers.suggestionID($0), title: $0.title) },
                             answers: RemoteAnswers.accepted(request), title: item.title, project: request.project, accountName: item.account,
                             headless: request.headless, arrivedAt: item.arrived.timeIntervalSince1970,
                             handBackAt: item.handBackAt?.timeIntervalSince1970, truncated: truncated,
                             gate: gate, modes: RemoteAnswers.modes(request).isEmpty ? nil : RemoteAnswers.modes(request))
    }

    /// Uncut, for `GET /v1/requests/{rid}`.
    static func fullRequest(_ item: Island.Pending) -> RemoteRequest {
        let short = request(item)
        return RemoteRequest(id: short.id, sessionID: short.sessionID, agent: short.agent, tool: short.tool, action: item.request.action.escaped,
                             headline: short.headline, detail: short.detail, reason: short.reason, risk: short.risk, riskReason: short.riskReason,
                             suggestions: short.suggestions, answers: short.answers, title: short.title, project: short.project,
                             accountName: short.accountName, headless: short.headless, arrivedAt: short.arrivedAt, handBackAt: short.handBackAt,
                             truncated: false, gate: short.gate, modes: short.modes)
    }

    static func cut(_ action: IslandAction) -> (IslandAction, Bool) { RemoteTranscript.cutting(action) }

    static func finished(_ row: Island.Ready, island: Island) -> FinishedSession? {
        guard let session = row.finish.sessionID else { return nil }
        return FinishedSession(sessionID: session, turnID: row.id.uuidString.lowercased(), title: row.title, summary: String(row.finish.summary.prefix(maxString)),
                               at: row.at.timeIntervalSince1970, canFollowUp: island.canReply(row))
    }

    /// The key a phone uses for a live session: its conversation id when known, else its process and start time.
    static func key(_ session: LiveSession) -> SessionKey {
        session.sessionID ?? "pid-\(session.pid)-\(Int(session.started ?? 0))"
    }

    static func status(_ session: LiveSession) -> SessionStatus {
        switch session.status {
        case "busy", "shell": .working
        case "waiting": .waiting
        case "idle": .idle
        default: SessionStatus(rawValue: session.status)
        }
    }

    /// What every row of one listing shares, read once for all of them: the open requests by session and by process,
    /// and each conversation's limit.
    struct Rows {
        let finished: Set<String>
        let limits: [String: SessionLimit]
        private let pending: [Island.Pending]
        private let bySession: [String: [Int]]
        private let byProcess: [Int: [Int]]

        @MainActor init(_ store: AccountStore, finished: Set<String>) {
            self.finished = finished
            limits = store.sessionLimits(now: Date().timeIntervalSince1970)
            pending = store.island.pending
            var bySession: [String: [Int]] = [:], byProcess: [Int: [Int]] = [:]
            for (index, item) in pending.enumerated() {
                if let id = item.request.sessionID { bySession[id, default: []].append(index) }
                if let pid = item.request.pid { byProcess[pid, default: []].append(index) }
            }
            self.bySession = bySession; self.byProcess = byProcess
        }

        /// In arrival order, as the island holds them.
        func open(_ live: LiveSession) -> [Island.Pending] {
            let indices = Set((live.sessionID.flatMap { bySession[$0] } ?? []) + (byProcess[live.pid] ?? []))
            return indices.sorted().map { pending[$0] }
        }
    }

    static func session(_ live: LiveSession, store: AccountStore, finished: Set<String>) -> RemoteSession {
        session(live, store: store, rows: Rows(store, finished: finished))
    }

    static func session(_ live: LiveSession, store: AccountStore, rows: Rows) -> RemoteSession {
        let sessions = store.sessions
        let finished = rows.finished
        let key = key(live)
        let open = rows.open(live)
        let commands = SessionCommands(store: store)
        let status = commands.status(live, finished: finished)
        let accountID = sessions.accountID(of: live)
        let agent = live.provider
        // Codex's app server: settings for the next turns, context and cost.
        let daemon = store.remote.codex.row(live)
        return RemoteSession(id: key, conversationID: live.sessionID, agent: agent,
                             title: live.sessionID.flatMap { sessions.names[$0] } ?? live.title ?? live.name ?? sessions.project(of: live.cwd), cwd: live.cwd, project: sessions.project(of: live.cwd),
                             worktree: live.cwd.map { worktree($0) } ?? false,
                             accountID: accountID, accountName: accountID.flatMap { id in store.config.accounts.first { $0.id == id }?.name },
                             model: daemon?.settings?.model ?? live.model, effort: daemon?.settings?.effort?.rawValue ?? live.effort, status: status,
                             waitingFor: live.waitingFor, statusAt: live.since.map { $0 > 1e11 ? $0 / 1000 : $0 },
                             step: live.activity, context: live.context,
                             flag: commands.flag(live), cost: daemon?.cost ?? live.cost,
                             openRequests: open.map { $0.id.uuidString.lowercased() },
                             mail: sessions.mail[live.pid].map { MailState(kind: .init(rawValue: $0), at: sessions.mailAt[live.pid] ?? Date().timeIntervalSince1970) },
                             hosted: live.hosted, abilities: commands.abilities(live, status: status),
                             ports: live.ports.map { $0.map { ListeningPort(port: $0.port, process: $0.command ?? "", previewURL: store.remote.previews.url(session: WireBuilders.key(live), port: $0.port)) } },
                             memoryBytes: live.memory.map { $0 << 20 }, contextPercent: daemon?.contextPercent ?? live.contextPercent,
                             abilityReasons: commands.reasons(live, status: status), settings: daemon?.settings ?? settings(live),
                             turnID: daemon?.turnID ?? live.turnID, plan: daemon?.plan, backgroundTasks: live.runningTasks,
                             limit: live.sessionID.flatMap { rows.limits[$0] })
    }

    /// What the session runs with, as the bridge read it; nil when it read nothing.
    static func settings(_ live: LiveSession) -> SessionSettings? {
        guard live.model != nil || live.effort != nil || live.mode != nil || live.fast != nil else { return nil }
        return SessionSettings(model: live.model, effort: live.effort.map(Effort.init(rawValue:)),
                               mode: live.mode.map(PermissionMode.init(rawValue:)), fast: live.fast)
    }

    /// A worktree's `.git` is a file. Asked for every session on every change, so each folder's answer is kept a little.
    static func worktree(_ cwd: String, now: Date = Date()) -> Bool {
        if let known = worktrees[cwd], now.timeIntervalSince(known.at) < worktreeTTL { return known.is }
        if worktrees.count > 512 { worktrees = [:] }
        var directory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: cwd + "/.git", isDirectory: &directory) && !directory.boolValue
        worktrees[cwd] = (found, now)
        return found
    }

    static let worktreeTTL: TimeInterval = 10
    private static var worktrees: [String: (is: Bool, at: Date)] = [:]

    static func hosted(_ session: HostedSessions.Session, hosted: HostedSessions, store: AccountStore, viewers: Int) -> HostedSession? {
        guard let agent = session.agent else { return nil }
        let live = store.sessions.live.first { $0.hosted == session.name }
        return HostedSession(name: session.name, agent: agent == .codex ? .codex : .claude, cwd: session.cwd,
                             // A worktree's project is the repo it came from.
                             project: URL(fileURLWithPath: HostedSessions.repository(of: session.cwd) ?? session.cwd).lastPathComponent,
                             worktree: session.worktree.isEmpty ? nil : SideAProtocol.Worktree(path: session.worktree, branch: "sidea/\(session.name)"),
                             sessionID: live.map(key) ?? (session.sessionID.isEmpty ? nil : session.sessionID),
                             createdAt: session.created, macAttached: hosted.macClients[session.name] != nil, viewers: viewers, alive: true,
                             exitStatus: nil)
    }

    /// Phone viewers as the last tmux refresh counted them, which `HostedSessions.watch` keeps within seconds.
    static func hostedSessions(_ store: AccountStore) -> [HostedSession] {
        let hosted = store.hosted
        return hosted.sessions.compactMap { Self.hosted($0, hosted: hosted, store: store, viewers: hosted.phoneViewers[$0.name] ?? 0) }
    }

    static func accounts(_ store: AccountStore) -> [RemoteAccount] {
        let live = store.sessions.live
        let now = Date().timeIntervalSince1970
        return store.config.accounts.map { account in
            let usage = store.usage[account.id]
            return RemoteAccount(id: account.id, name: account.name, email: account.email, provider: account.provider, ready: account.ready,
                                 active: store.isActive(account), usage: usage, readAt: store.readAt[account.id]?.timeIntervalSince1970,
                                 sessions: live.filter { store.sessions.accountID(of: $0) == account.id }.count,
                                 priority: PriorityLevel(rawValue: (account.priority ?? .normal).rawValue), allowAuto: account.allowAuto,
                                 limited: usage.map { Planner.isLimited($0, now: now, full: store.config.moveAt) } ?? false, fableOut: usage.map { Planner.isFableOut($0, now: now, full: store.config.moveAt) } ?? false,
                                 backAt: usage.flatMap { Planner.backAt($0, now: now, full: store.config.moveAt) }, issue: store.accountIssue(account, now: now))
        }
    }

    /// Settings' "Worth at API prices": the last 7 and 30 days of this Mac's Claude Code tokens, all accounts together.
    static func worth(_ rows: [TokenRow]) -> Worth? {
        guard !rows.isEmpty else { return nil }
        let week = rows.filter { ($0.date ?? "") >= MenuPlayer.day(-6) }
        return Worth(days7: APIPrice.dollars(week), days30: APIPrice.dollars(rows))
    }
}
