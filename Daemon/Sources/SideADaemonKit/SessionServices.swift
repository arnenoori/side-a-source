import Foundation
import SideACore
import SideAProtocol

/// Sessions on a headless host: what is running (the Python bridge, as on the Mac), what Side A started in tmux, a
/// transcript for each, and replies typed into the panes this daemon owns. What needs a hook or app server the daemon
/// doesn't run (notes, queued follow-ups, Codex's shared server) is not offered, and the abilities say so.
public final class SessionServices: DaemonServices {
    public struct Settings: Sendable {
        public var root: URL
        /// The folders a phone may start a session in; every folder a session already runs in is allowed too.
        public var projects: [String]
        public var agents: [Hosting.Agent: String] = [:]
        public var environment: [String: String] = ProcessInfo.processInfo.environment
        public var poll: Duration = .seconds(2)
        /// The variables a session for an account starts with; nil when the account isn't known.
        public var accountEnvironment: (@Sendable (String) async -> [String: String]?)?
        /// What sending sessions to other computers adds: the `move` ability, and the refusal to resume a conversation
        /// that is on another computer now.
        public var moves: MoveHooks?
        public init(root: URL, projects: [String]) { self.root = root; self.projects = projects }
    }

    let engine: SessionEngine

    init?(settings: Settings, location: BridgeLocation?, approvals: Approvals?) {
        guard let location else { return nil }
        engine = SessionEngine(settings: settings, bridge: SessionBridge(location: location, root: settings.root, environment: settings.environment),
                               tmux: HostedTmux(root: settings.root, environment: settings.environment, agents: settings.agents), approvals: approvals)
    }

    public convenience init?(settings: Settings, location: BridgeLocation? = BridgeLocation.find()) {
        self.init(settings: settings, location: location, approvals: nil)
    }

    public var capabilities: Set<Capability> { [.transcriptStream, .hosted, .interrupt, .confirmSigned, .confirmActions] }

    public func snapshot(into parts: StateParts) async -> StateParts { await engine.snapshot(into: parts) }

    public func start(_ daemon: SideADaemon) async { await engine.start(daemon) }
    public func stop() async { await engine.stop() }

    public var routes: [DaemonRoute] {
        let engine = engine
        return [
            DaemonRoute("GET", "v1/sessions") { context in
                let parts = await engine.snapshot(into: StateParts())
                return Wire.json(200, SessionList(sessions: parts.sessions, finished: [], seq: await context.daemon.hub.seq))
            },
            DaemonRoute("GET", "v1/sessions/{id}") { context in
                guard let session = await engine.session(context.params["id"] ?? "") else { return .noSession }
                return Wire.json(200, session)
            },
            DaemonRoute("GET", "v1/sessions/{id}/transcript") { context in await engine.transcript(context) },
            DaemonRoute("GET", "v1/sessions/{id}/messages/{seq}") { context in await engine.message(context) },
            DaemonRoute("POST", "v1/sessions/{id}/reply") { context in await engine.reply(context) },
            DaemonRoute("POST", "v1/sessions/{id}/interrupt") { context in await engine.interrupt(context) },
            DaemonRoute("GET", "v1/projects") { _ in Wire.json(200, ProjectList(projects: await engine.projects())) },
            DaemonRoute("GET", "v1/hosted") { context in
                let parts = await engine.snapshot(into: StateParts())
                return Wire.json(200, HostedList(hosted: parts.hosted, seq: await context.daemon.hub.seq))
            },
            DaemonRoute("POST", "v1/hosted") { context in await engine.startHosted(context) },
            DaemonRoute("DELETE", "v1/hosted/{name}") { context in await engine.endHosted(context) },
        ]
    }
}

extension HTTPResponse {
    static var noSession: HTTPResponse { .apiError(404, .sessionNotFound, "That session isn't running on this computer any more.") }
    static var badJSON: HTTPResponse { .apiError(400, .badJSON, "The request body isn't what this route takes.") }
    static var notReady: HTTPResponse { .apiError(503, .notReady, "Side A is still starting its session reader.", retryAfter: 2) }
}

actor SessionEngine {
    let settings: SessionServices.Settings
    private let bridge: SessionBridge
    let tmux: HostedTmux
    private let approvals: Approvals?
    private weak var daemon: SideADaemon?
    private(set) var rows: [LiveRow] = []
    private var sessions: [SessionKey: RemoteSession] = [:]
    private var hosted: [String: HostedSession] = [:]
    private var refreshedAt = Date.distantPast
    private var refreshing: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var delivering: Set<SessionKey> = []
    private var again: Set<SessionKey> = []
    private var ready = false
    private var told: Set<String> = []
    static let maxCatchUp = 200
    static let packBytes = 900 * 1024

    init(settings: SessionServices.Settings, bridge: SessionBridge, tmux: HostedTmux, approvals: Approvals? = nil) {
        self.settings = settings; self.bridge = bridge; self.tmux = tmux; self.approvals = approvals
    }

    // MARK: Lifecycle

    func start(_ daemon: SideADaemon) async {
        self.daemon = daemon
        _ = try? await bridge.once(["hosting", "install"], timeout: 30)
        _ = await tmux.prepare()
        // A request that came or went: the rows that name it change now, not at the next look.
        await approvals?.setChanged { [weak self] in await self?.refresh(force: true) }
        ready = true
        await refresh(force: true)
        await daemon.hub.observe(greeted: nil, subscribed: { [weak self] _, _, requested in
            for session in requested.keys { await self?.deliver(session) }
        })
        loop = Task { [weak self, interval = settings.poll] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.tick()
            }
        }
    }

    func stop() async {
        loop?.cancel()
        loop = nil
        await bridge.stop()
    }

    private func tick() async {
        await refresh(force: true)
        guard let daemon else { return }
        for session in await daemon.hub.subscriptions { await deliver(session) }
    }

    // MARK: The list

    /// What is running now, and an event for each row that appeared, changed or went.
    func refresh(force: Bool = false) async {
        if let refreshing { await refreshing.value; return }
        if !force, Date().timeIntervalSince(refreshedAt) < 1.5 { return }
        let task = Task { await self.read() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func read() async {
        guard ready else { return }
        let live = (try? await bridge.live())
        let panes = await tmux.list()
        guard let live else { return }
        rows = live
        // Before the rows are built: a request answered in the terminal is closed, so no row names it.
        await approvals?.sync(live)
        let open = await approvals?.open(for: live) ?? [:]
        let movable = await settings.moves?.movable() ?? false
        var next: [SessionKey: RemoteSession] = [:]
        var named: [String: SessionKey] = [:]
        for row in live {
            var session = LiveBuilder.session(row)
            session.openRequests = open[row.key] ?? []
            if movable { LiveBuilder.offerMove(&session) }
            next[session.id] = session
            if let name = row.hosted { named[name] = session.id }
        }
        for pane in panes where named[pane.name] == nil && !pane.dead {
            let starting = LiveBuilder.starting(pane)
            next[starting.id] = starting
        }
        var nextHosted: [String: HostedSession] = [:]
        for pane in panes { nextHosted[pane.name] = LiveBuilder.hosted(pane, session: named[pane.name]) }
        refreshedAt = Date()
        guard let hub = daemon?.hub else { sessions = next; hosted = nextHosted; return }
        let before = sessions, beforeHosted = hosted
        sessions = next
        hosted = nextHosted
        for (id, session) in next where before[id] != session { await hub.record(.sessionUpsert(session)) }
        for id in before.keys where next[id] == nil {
            let replacement = before[id]?.hosted.flatMap { named[$0] }
            await hub.record(.sessionRemove(id: id, replacedBy: replacement))
        }
        for (id, session) in next {
            // A turn that ran and stopped is the one thing a phone is told when it isn't looking.
            guard let old = before[id], old.status == .working, session.status == .idle else { continue }
            let turn = session.turnID ?? "\(id)-\(Int(Date().timeIntervalSince1970))"
            guard !told.contains(turn) else { continue }
            told.insert(turn)
            let finished = FinishedSession(sessionID: id, turnID: turn, title: session.title, summary: "Ready for your next message.",
                                           at: Date().timeIntervalSince1970, canFollowUp: session.hosted != nil)
            if session.hosted != nil { settings.moves?.turnEnded(session.conversationID) }
            if let daemon { await daemon.sessionFinished(finished) }
        }
        if told.count > 200 { told = Set(told.suffix(100)) }
        for (name, value) in nextHosted where beforeHosted[name] != value { await hub.record(.hostedUpsert(value)) }
        for name in beforeHosted.keys where nextHosted[name] == nil { await hub.record(.hostedRemove(name: name)) }
    }

    func snapshot(into parts: StateParts) async -> StateParts {
        await refresh()
        var parts = parts
        parts.sessions = sessions.values.sorted { $0.id < $1.id }
        parts.hosted = hosted.values.sorted { $0.name < $1.name }
        return parts
    }

    func session(_ id: SessionKey) async -> RemoteSession? {
        await refresh()
        return sessions[id] ?? sessions.values.first { $0.conversationID == id }
    }

    func projects() async -> [RemoteProject] {
        await refresh()
        var paths = settings.projects
        for session in sessions.values { if let cwd = session.cwd, !paths.contains(cwd) { paths.append(cwd) } }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }.map { path in
            RemoteProject(path: path, name: (path as NSString).lastPathComponent, liveSessions: sessions.values.filter { $0.cwd == path }.count)
        }
    }

    // MARK: Transcripts

    private func conversation(_ key: SessionKey) -> String? {
        let id = sessions[key]?.conversationID ?? (key.hasPrefix("pid-") || key.hasPrefix("tmux-") ? nil : key)
        return id.flatMap { Self.safe($0) ? $0 : nil }
    }

    static func safe(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }

    private static func failed(_ error: Error) -> HTTPResponse {
        switch error {
        case let failure as RemoteTranscript.Failure where failure.missing: .noSession
        case let failure as RemoteTranscript.Failure where failure.badCursor: .apiError(400, .badRequest, "That cursor isn't one this computer gave out.")
        case is BridgeFailure: .notReady
        default: .apiError(500, .internalError, "Side A couldn't read that session.")
        }
    }

    func transcript(_ context: RouteContext) async -> HTTPResponse {
        let query = context.request.query
        if query["before"] != nil, query["after"] != nil { return .apiError(400, .badRequest, "Send before or after, not both.") }
        await refresh()
        guard let id = conversation(context.params["id"] ?? "") else { return .noSession }
        var options = ["--format", "remote", "--limit", String(min(max(query["limit"].flatMap(Int.init) ?? 50, 1), 200))]
        for key in ["before", "after"] {
            guard let cursor = query[key] else { continue }
            guard Self.safe(cursor) else { return .apiError(400, .badRequest, "That cursor isn't one this computer gave out.") }
            options += ["--\(key)", cursor]
        }
        if let agent = query["agent"] {
            guard Self.safe(agent) else { return .noSession }
            options += ["--agent-id", agent]
        }
        do { return Wire.json(200, try RemoteTranscript.page(try await bridge.data(["show"] + options + ["--", id]))) } catch { return Self.failed(error) }
    }

    func message(_ context: RouteContext) async -> HTTPResponse {
        guard let seq = context.params["seq"].flatMap(Int.init), seq >= 0, let generation = context.request.query["generation"], Self.safe(generation) else {
            return .apiError(400, .badRequest, "Send the message's seq and generation.")
        }
        await refresh()
        guard let id = conversation(context.params["id"] ?? "") else { return .noSession }
        var options = ["--seq", String(seq), "--generation", generation]
        if let agent = context.request.query["agent"], Self.safe(agent) { options += ["--agent-id", agent] }
        do {
            guard let message = try RemoteTranscript.message(try await bridge.data(["message"] + options + ["--", id])) else {
                return .apiError(410, .cursorExpired, "This conversation changed since you loaded it. Load it again.")
            }
            return Wire.json(200, message)
        } catch { return Self.failed(error) }
    }

    /// Sends each subscribed socket what is past its cursor: the rows as append and replace events, or a reset when there
    /// is too much or the view was rebuilt. One round per session at a time.
    func deliver(_ session: SessionKey) async {
        guard !delivering.contains(session) else { again.insert(session); return }
        delivering.insert(session)
        await round(session)
        delivering.remove(session)
        if again.remove(session) != nil { await deliver(session) }
    }

    private func round(_ session: SessionKey) async {
        guard let hub = daemon?.hub, let id = conversation(session) else { return }
        let cursors = await hub.cursors(session)
        let groups = Dictionary(grouping: cursors) { $0.value }.mapValues { $0.map(\.key) }
        for (cursor, sockets) in groups {
            func page(_ options: [String]) async -> TranscriptPage? {
                guard let reply = try? await bridge.data(["show", "--format", "remote"] + options + ["--", id]) else { return nil }
                return try? RemoteTranscript.page(reply)
            }
            guard let cursor else {
                if let latest = await page(["--limit", "1"]) { await hub.advance(sockets, session: session, from: nil, to: latest.after) }
                continue
            }
            guard Self.safe(cursor.raw), let next = await page(["--after", cursor.raw, "--limit", String(Self.maxCatchUp)]) else { continue }
            if next.reset || next.hasMoreAfter || next.messages.count + next.replaced.count > Self.maxCatchUp {
                await hub.transcript([.transcriptReset(sessionID: session, generation: next.generation)], to: sockets)
                continue
            }
            guard !next.messages.isEmpty || !next.replaced.isEmpty else { continue }
            await hub.transcript(Self.events(next, session: session, from: cursor), to: sockets)
            await hub.advance(sockets, session: session, from: cursor, to: next.after)
        }
    }

    /// Only the last event carries the page's cursor; the others keep `from`, so a phone cut off part way resumes from
    /// before the page instead of past rows it never got.
    static func events(_ page: TranscriptPage, session: SessionKey, from: Cursor) -> [ServerEvent] {
        let parts = pack(page.messages).map { (append: true, messages: $0) } + pack(page.replaced).map { (append: false, messages: $0) }
        return parts.enumerated().map { index, part in
            let delta = TranscriptDelta(sessionID: session, generation: page.generation, messages: part.messages, cursor: index == parts.count - 1 ? page.after : from)
            return part.append ? .transcriptAppend(delta) : .transcriptReplace(delta)
        }
    }

    static func pack(_ messages: [TranscriptMessage]) -> [[TranscriptMessage]] {
        var groups: [[TranscriptMessage]] = []
        var current: [TranscriptMessage] = []
        var size = 0
        for message in messages {
            let bytes = (try? Wire.encoder.encode(message).count) ?? 0
            if !current.isEmpty, size + bytes > packBytes { groups.append(current); current = []; size = 0 }
            current.append(message)
            size += bytes
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    // MARK: Replies

    private func refusal(_ code: ErrorCode, _ message: String, _ status: Int = 409, hint: String? = nil) -> HTTPResponse {
        .apiError(status, code, message, details: hint.map { ["hint": $0] })
    }

    func reply(_ context: RouteContext) async -> HTTPResponse {
        guard let body = context.body(RemoteReply.self), let daemon else { return .badJSON }
        let id = context.params["id"] ?? ""
        guard let session = await session(id) else { return .noSession }
        guard body.text.utf8.count <= Hosting.replyLimit, body.attachments.isEmpty else {
            return refusal(.invalidReply, body.attachments.isEmpty ? "That reply is too long." : "Photos can't be sent to this computer yet.", 422)
        }
        let state: RemoteDelivery.State = switch session.status {
        case .waiting: .waiting
        case .working: .working
        case .idle, .starting: .idle
        default: .unknown
        }
        let agent: Hosting.Agent = session.agent == .codex ? .codex : .claude
        let decision = RemoteDelivery.decide(state, hosted: session.hosted != nil, agent: session.agent, mode: body.mode, mailHooks: false, stopHooks: false)
        let purpose: ConfirmPurpose = body.mode == .keys ? .keys : .action
        let subject: String?
        if body.mode == .keys { subject = try? ConfirmMessage.subject(sessionID: session.id, keys: body.keys ?? []) }
        else { subject = try? ConfirmMessage.subject(action: .reply, target: id, body: body) }
        guard let subject else { return .badJSON }
        let proof = ConfirmProof(ConfirmPolicy.reply(body, sessionMode: session.settings?.mode))
        if let refused = await daemon.confirm(context.request, device: context.device, purpose: purpose, subject: subject, needs: proof) { return refused }
        guard let name = session.hosted else { return refusal(.notHosted, "Only a session Side A started can be typed into from the phone.") }
        switch decision {
        case .typed:
            do { try await tmux.type(name, agent: agent, text: body.text) } catch { return Self.typing(error) }
            await refresh(force: true)
            return Wire.json(200, ReplyResult(delivery: .typed, sessionID: session.id))
        case .keys:
            do { try await tmux.press(name, keys: (body.keys ?? []).map { Self.tmuxKey($0.rawValue) }) } catch { return Self.typing(error) }
            return Wire.json(200, ReplyResult(delivery: .typed, sessionID: session.id))
        case .refused(let refused):
            let waiting = refused.code == RemoteDelivery.Refusal.waiting.code
            return refusal(waiting ? .sessionWaiting : .cannotDeliver, waiting ? "It's waiting for an answer on the screen." : "That reply can't be delivered right now.", hint: refused.hint)
        case .followUp, .queued, .note:
            return refusal(.cannotDeliver, "This computer doesn't run the hooks that carry that kind of reply.", hint: "setup")
        }
    }

    static func tmuxKey(_ key: String) -> String {
        switch key {
        case "enter": "Enter"
        case "esc": "Escape"
        case "tab": "Tab"
        case "up": "Up"
        case "down": "Down"
        case "left": "Left"
        case "right": "Right"
        case "ctrl-c": "C-c"
        default: key
        }
    }

    private static func typing(_ error: Error) -> HTTPResponse {
        switch error as? HostedTmux.Failure {
        case .waiting?: .apiError(409, .sessionWaiting, "It's waiting for an answer on the screen.")
        case .refused(let message)?: .apiError(422, .invalidReply, message)
        case .unavailable?: .apiError(503, .tmuxMissing, "Hosted sessions need tmux 3.4 or newer on this computer.", retryAfter: 60)
        case .failed(let message)?: .apiError(502, .cannotDeliver, message)
        case nil: .apiError(500, .internalError, "Side A couldn't type that.")
        }
    }

    func interrupt(_ context: RouteContext) async -> HTTPResponse {
        guard let session = await session(context.params["id"] ?? "") else { return .noSession }
        guard let name = session.hosted, session.status == .working else {
            return refusal(.cannotDeliver, "It isn't working right now, or Side A doesn't host it.")
        }
        do { try await tmux.interrupt(name) } catch { return Self.typing(error) }
        return Wire.json(200, InterruptResult(method: .escape))
    }

    // MARK: Hosting

    func startHosted(_ context: RouteContext) async -> HTTPResponse {
        guard let body = context.body(StartHosted.self), let daemon else { return .badJSON }
        if let refused = Hosting.promptRefusal(body.prompt) { return refusal(.invalidReply, refused, 422) }
        guard await tmux.available else { return .apiError(503, .tmuxMissing, "Hosted sessions need tmux 3.4 or newer on this computer.", retryAfter: 60) }
        let allowed = await projects().contains { $0.path == body.cwd }
        guard allowed else { return .apiError(404, .notFound, "That folder isn't one of this computer's projects.") }
        guard body.attachments.isEmpty, !body.worktree, !body.fork, body.openOnMac != true else {
            return .apiError(422, .badRequest, "Photos, worktrees, forks and Show on Mac aren't available on this computer yet.")
        }
        if let resume = body.resume, !Self.safe(resume) { return .noSession }
        if let resume = body.resume, let away = await settings.moves?.elsewhere(resume) { return .moved(to: away) }
        guard Hosting.safeOption(body.model), Hosting.safeOption(body.effort) else { return .apiError(422, .badRequest, "That model or effort isn't one this computer can start with.") }
        guard (body.prompt ?? "").utf8.count <= Hosting.promptArgumentLimit else { return refusal(.invalidReply, "That prompt is too long.", 422) }
        let agent: Hosting.Agent = body.agent == .codex ? .codex : .claude
        var permission: [String] = []
        if let mode = body.permissionMode {
            guard let args = Hosting.permissionArguments(agent, mode: mode.rawValue) else { return .apiError(422, .badRequest, "\(body.agent.title) can't start in that mode.") }
            permission = args
        }
        guard let subject = try? ConfirmMessage.subject(start: body) else { return .badJSON }
        if let refused = await daemon.confirm(context.request, device: context.device, purpose: .settings, subject: subject, needs: ConfirmProof(ConfirmPolicy.start(body))) { return refused }
        let mode: Hosting.Mode = body.resume.map { .resume($0, model: body.model) } ?? .new(model: body.model)
        var start = HostedTmux.Start(agent: agent, cwd: body.cwd, mode: mode)
        var arguments: [String] = []
        if agent == .codex {
            arguments += ["-c", "check_for_update_on_startup=false"]
            if let effort = body.effort { arguments += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        }
        arguments += Hosting.arguments(agent, mode)
        if agent == .claude, let effort = body.effort { arguments += ["--effort", effort] }
        start.arguments = arguments + permission
        start.prompt = body.prompt.map(Hosting.clean).flatMap { $0.isEmpty ? nil : $0 }
        if let accountID = body.accountID {
            guard let environment = await settings.accountEnvironment?(accountID) else { return .apiError(404, .notFound, "That account isn't on this computer.") }
            start.environment = environment
            start.account = accountID
        }
        start.key = context.request.headers["Idempotency-Key"].map { "phone-\(context.device)-\($0)" }
        do {
            let name = try await tmux.start(start)
            await refresh(force: true)
            guard let value = hosted[name] else { return .apiError(502, .cannotDeliver, "The session started and stopped at once.") }
            return Wire.json(201, value)
        } catch let failure as HostedTmux.Failure {
            switch failure {
            case .unavailable: return .apiError(503, .tmuxMissing, "Hosted sessions need tmux 3.4 or newer on this computer.", retryAfter: 60)
            case .refused(let message): return .apiError(422, .badRequest, message)
            case .failed(let message): return .apiError(502, .cannotDeliver, message)
            case .waiting: return .apiError(409, .sessionWaiting, "It's waiting for an answer on the screen.")
            }
        } catch { return .apiError(500, .internalError, "Side A couldn't start that session.") }
    }

    func endHosted(_ context: RouteContext) async -> HTTPResponse {
        guard let daemon else { return .badJSON }
        let name = context.params["name"] ?? ""
        await refresh()
        guard hosted[name] != nil else { return .apiError(404, .notFound, "That hosted session isn't running.") }
        if let refused = await daemon.confirm(context.request, device: context.device, purpose: .action,
                                              subject: ConfirmMessage.subject(action: .endHosted, target: name), needs: .unlock) { return refused }
        _ = await tmux.end(name)
        await refresh(force: true)
        return HTTPResponse(status: 204)
    }
}

extension SideADaemon {
    /// Nil when the request carries a signature for at least `needs`; otherwise the 401 to answer with.
    public func confirm(_ request: HTTPRequest, device: String, purpose: ConfirmPurpose, subject: String, needs: ConfirmProof) async -> HTTPResponse? {
        guard needs > .none else { return nil }
        let keys = await devices.confirmKeys[device] ?? ConfirmGate.Keys(confirm: nil, unlock: nil)
        var details = APIError.confirmDetails(level: needs.level ?? .unlock, pairAgain: keys.isEmpty)
        let what = needs == .biometric ? "Confirm with Face ID or Touch ID." : "Unlock this device to do this."
        switch ConfirmGate.verify(request.headers[ConfirmSignature.header], macID: config.hostID, deviceID: device, purpose: purpose, subject: subject, keys: keys, replay: replay) {
        case .success(let level) where level >= needs: return nil
        case .success, .failure(.missing):
            return .apiError(401, .confirmRequired, keys.isEmpty ? "Pair this device again to do this from it." : what, details: details)
        case .failure(let failure):
            details["reason"] = failure.rawValue
            return .apiError(401, .confirmInvalid, what, details: details)
        }
    }
}
