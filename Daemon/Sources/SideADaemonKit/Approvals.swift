import Foundation
import SideACore
import SideAProtocol

/// Permission requests from Claude Code on this computer, held for the phone. A hook (`bridge/island_hook.py`, the script the Mac's
/// island runs) connects to `HookSocket`, sends the request and waits; the phone sees it as `RemoteRequest` in the snapshot and on
/// the events socket, and its Allow or Deny becomes the line the hook prints. The rules are the Mac's: what the request is, how risky
/// it is, what the phone must prove (`RemoteAnswers`, `AllowGate`) and how it answers (`IslandAnswer`) all come from `SideACore`.
///
/// A request leaves in exactly one way, and the phone is told how: answered on a phone, answered in the terminal (the session left
/// "waiting", or its process went), handed back after two minutes (headless runs), or the hook went away (the session quit).
actor Approvals {
    struct Settings: Sendable {
        /// Where the hook's socket is; the bridge writes the same path into the hook's launcher (`<root>/runtime/island.sock`).
        var socket: String
        /// The account a session runs on, from the slot its hook reports (the name of its `CLAUDE_CONFIG_DIR`).
        var accountName: @Sendable (_ slot: String?) async -> String? = { _ in nil }
        var maxOpen = 100
        var alive: @Sendable (Int) -> Bool = { Approvals.processAlive($0) }
    }

    struct Item: Sendable, Equatable {
        let id: UUID
        let connection: UInt64
        let request: IslandRequest
        let title: String
        let account: String?
        let arrived: Date
        let handBackAt: Date?
        var key: RequestID { id.uuidString.lowercased() }
    }

    enum By: Sendable, Equatable {
        case device(id: String, name: String)
        case terminal, handedBack, gone
    }

    enum Outcome: Sendable, Equatable {
        case done(RequestResolution)
        /// 409 `already_resolved`, with who settled it first.
        case conflict(RequestResolution)
        /// 404 `request_not_found`.
        case unknown
        /// 422 `invalid_answer` with this `details.reason`.
        case refused(String)
    }

    enum Line: Sendable { case received(UInt64, Data), closed(UInt64) }

    private let settings: Settings
    private weak var daemon: SideADaemon?
    private var socket: HookSocket?
    private var items: [Item] = []
    private var settled: [UUID: RequestResolution] = [:]
    private var settledOrder: [UUID] = []
    private var shown: [UUID: AllowGate] = [:]
    private var titles: [String: String] = [:]
    private var feed: Task<Void, Never>?
    /// Told when what is open changed, so the session rows that name it are rebuilt at once.
    var changed: (@Sendable () async -> Void)?

    init(settings: Settings) { self.settings = settings }

    func setChanged(_ changed: @escaping @Sendable () async -> Void) { self.changed = changed }

    // MARK: Lifecycle

    /// A socket that can't be opened leaves hooks failing open: Claude Code asks in its own terminal, as without Side A.
    func start(_ daemon: SideADaemon) async {
        self.daemon = daemon
        let (lines, input) = AsyncStream<Line>.makeStream()
        do {
            socket = try await HookSocket.start(path: settings.socket, received: { input.yield(.received($0, $1)) }, closed: { input.yield(.closed($0)) })
        } catch {
            FileHandle.standardError.write(Data("sidead: permission requests are off: \(error)\n".utf8))
            return
        }
        // One consumer, so a hook that quits right after it asked is never seen to have quit first.
        feed = Task { [weak self] in
            for await line in lines {
                guard let self else { return }
                switch line {
                case .received(let connection, let data): await self.received(connection, data)
                case .closed(let connection): await self.closed(connection)
                }
            }
        }
    }

    func stop() async {
        feed?.cancel()
        feed = nil
        let open = items
        items = []
        // The hooks are released, so Claude Code asks in its terminal rather than waiting on a daemon that is gone.
        for item in open { socket?.reply(item.connection, IslandAnswer.terminal.line) }
        await socket?.stop()
        socket = nil
    }

    // MARK: A request arrives

    func received(_ connection: UInt64, _ line: Data) async {
        guard let request = IslandRequest(message: line), request.agent == .claude, Self.isPermissionRequest(line), items.count < settings.maxOpen else {
            socket?.reply(connection, IslandAnswer.terminal.line)
            return
        }
        // Questions and plans take their own answers (capabilities `answers.questions` and `answers.plans`), which this host doesn't offer yet.
        switch request.action {
        case .question, .plan:
            socket?.reply(connection, IslandAnswer.terminal.line)
            return
        default: break
        }
        let title = request.sessionID.flatMap { titles[$0] } ?? request.project ?? request.agent.title
        let handBack = IslandHold.handBack(agent: request.agent, headless: request.headless, hosted: request.hosted != nil, subagent: request.subagent)
        let item = Item(id: UUID(), connection: connection, request: request, title: title, account: await settings.accountName(request.slot),
                        arrived: Date(), handBackAt: handBack.map { Date().addingTimeInterval($0) })
        items.append(item)
        let wire = wire(item)
        await daemon?.hub.record(.requestAdd(wire))
        // The push goes out on its own: a slow relay never holds up the request, nor its answer.
        if let daemon { let request = full(item); Task { await daemon.requestOpened(request) } }
        await changed?()
    }

    private static func isPermissionRequest(_ line: Data) -> Bool {
        let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        return (message?["request"] as? [String: Any])?["hook_event_name"] as? String == "PermissionRequest"
    }

    func closed(_ connection: UInt64) async {
        guard let item = items.first(where: { $0.connection == connection }) else { return }
        await finish(item, by: .gone, answer: nil)
    }

    // MARK: What the phone sees

    func list() -> [RemoteRequest] { items.map(wire) }

    func request(_ rid: String) -> RemoteRequest? { item(rid).map(full) }

    /// The ids of the open requests each row has, in the order they arrived.
    func open(for rows: [LiveRow]) -> [SessionKey: [String]] {
        var found: [SessionKey: [String]] = [:]
        for row in rows {
            let mine = items.filter { $0.request.pid == row.pid || ($0.request.sessionID != nil && $0.request.sessionID == row.id) }.map(\.key)
            if !mine.isEmpty { found[row.key] = mine }
        }
        return found
    }

    private func item(_ rid: String) -> Item? {
        guard let id = UUID(uuidString: rid) else { return nil }
        return items.first { $0.id == id }
    }

    private func gate(_ item: Item) -> AllowGate { AllowGate.of(item.request, projects: AllowGate.projectRoots(of: item.request.cwd)) }

    /// What the phone is shown. The gate it was shown is kept, so an answer signed for a lower one is told the request changed.
    private func wire(_ item: Item) -> RemoteRequest {
        let request = item.request
        let (action, truncated) = RemoteTranscript.cutting(request.action)
        let gate = gate(item)
        shown[item.id] = gate
        if shown.count > 512 { shown = shown.filter { id, _ in items.contains { $0.id == id } } }
        let noAlways = !request.offersAlways || gate == .biometric
        let modes = RemoteAnswers.modes(request)
        return RemoteRequest(id: item.key, sessionID: request.sessionID, agent: request.agent.provider, tool: DisplayText.escaped(request.tool), action: action,
                             headline: request.headline, detail: request.detail, reason: request.reason.map(DisplayText.escaped), risk: request.risk,
                             riskReason: request.riskReason, suggestions: noAlways ? [] : request.remoteSuggestions.map(RemoteSuggestion.init),
                             answers: RemoteAnswers.accepted(request), title: item.title, project: request.project, accountName: item.account,
                             headless: request.headless, arrivedAt: item.arrived.timeIntervalSince1970,
                             handBackAt: item.handBackAt?.timeIntervalSince1970, truncated: truncated, gate: gate, modes: modes.isEmpty ? nil : modes)
    }

    private func full(_ item: Item) -> RemoteRequest {
        let short = wire(item)
        return RemoteRequest(id: short.id, sessionID: short.sessionID, agent: short.agent, tool: short.tool, action: item.request.action.escaped,
                             headline: short.headline, detail: short.detail, reason: short.reason, risk: short.risk, riskReason: short.riskReason,
                             suggestions: short.suggestions, answers: short.answers, title: short.title, project: short.project,
                             accountName: short.accountName, headless: short.headless, arrivedAt: short.arrivedAt, handBackAt: short.handBackAt,
                             truncated: false, gate: short.gate, modes: short.modes)
    }

    /// The gate the phone last saw for a request, and the one it needs now.
    func shownGate(_ rid: String) -> AllowGate? { UUID(uuidString: rid).flatMap { shown[$0] } }

    /// What the phone must prove to give this answer, by the request's own state now; nil when it isn't open.
    func needs(_ rid: String, _ answer: RemoteAnswer, mode: PermissionMode?) -> (gate: AllowGate, needs: ConfirmProof)? {
        guard let item = item(rid) else { return nil }
        let gate = gate(item)
        return (gate, RemoteAnswers.needs(item.request, answer, mode: mode, gate: gate))
    }

    // MARK: An answer

    /// `proven` is what the phone's confirm signature showed, already checked by the route.
    func answer(_ rid: String, _ wire: RemoteAnswer, mode: PermissionMode?, device: String, name: String, proven: ConfirmProof) async -> Outcome {
        guard let id = UUID(uuidString: rid) else { return .unknown }
        guard let item = items.first(where: { $0.id == id }) else { return settled[id].map(Outcome.conflict) ?? .unknown }
        switch RemoteAnswers.resolve(item.request, wire, mode: mode, gate: gate(item), proven: proven) {
        case .failure(let refusal):
            return .refused(refusal.rawValue)
        case .success(let (answer, confirmed)):
            // A destructive request takes an Allow only when its confirmation was shown.
            guard item.request.accepts(answer, confirmed: confirmed) else { return .refused(RemoteAnswers.Refusal.needsConfirm.rawValue) }
            socket?.reply(item.connection, answer.line)
            return .done(await finish(item, by: .device(id: device, name: name), answer: answer))
        }
    }

    /// `notify` is false while the session list is being read, which is what asked: it rebuilds its rows itself right after.
    @discardableResult
    private func finish(_ item: Item, by: By, answer: IslandAnswer?, notify: Bool = true) async -> RequestResolution {
        let request = full(item)
        items.removeAll { $0.id == item.id }
        let resolution = Self.resolution(item.id, by, answer, at: Date())
        settled[item.id] = resolution
        settledOrder.append(item.id)
        if settledOrder.count > 256 { settled[settledOrder.removeFirst()] = nil }
        shown[item.id] = nil
        await daemon?.hub.record(.requestResolve(resolution))
        if let daemon { Task { await daemon.requestSettled(request, resolution) } }
        if notify { await changed?() }
        return resolution
    }

    static func resolution(_ id: UUID, _ by: By, _ answer: IslandAnswer?, at: Date) -> RequestResolution {
        let key = id.uuidString.lowercased()
        switch by {
        case .device(let device, let name):
            return RequestResolution(requestID: key, by: .device, deviceID: device, deviceName: name, answer: answer.map(Self.kind), at: at.timeIntervalSince1970)
        case .terminal: return RequestResolution(requestID: key, by: .terminal, at: at.timeIntervalSince1970)
        case .handedBack: return RequestResolution(requestID: key, by: .handedBack, at: at.timeIntervalSince1970)
        case .gone: return RequestResolution(requestID: key, by: .sessionEnded, at: at.timeIntervalSince1970)
        }
    }

    static func kind(_ answer: IslandAnswer) -> AnswerKind {
        switch answer {
        // The protocol lists allowMode on a request but records the answer as the allow it is.
        case .allow, .allowMode: .allow
        case .always: .always
        case .deny: .deny
        case .terminal: .terminal
        case .answers: .answers
        case .approvePlan: .approvePlan
        }
    }

    // MARK: Watching the sessions

    /// What the session list says now: names for new requests, and an end for requests that were answered at the terminal
    /// (Claude Code leaves the hook running when its own prompt is answered, so the registry is how that is told), whose process
    /// is gone, or that went unanswered past their hand-back time.
    func sync(_ rows: [LiveRow], now: Date = Date()) async {
        for row in rows { if let id = row.id, let title = row.title ?? row.name { titles[id] = title } }
        if titles.count > 256 { titles = titles.filter { key, _ in items.contains { $0.request.sessionID == key } } }
        let sessions = rows.map { IslandSession(pid: $0.pid, sessionID: $0.id, status: $0.status, since: Date(timeIntervalSince1970: ($0.since ?? 0) > 1e11 ? ($0.since ?? 0) / 1000 : ($0.since ?? 0))) }
        for item in items {
            if let at = item.handBackAt, at <= now {
                socket?.reply(item.connection, IslandAnswer.terminal.line)
                await finish(item, by: .handedBack, answer: nil, notify: false)
                continue
            }
            if IslandSession.verdict(item.request, arrived: item.arrived, in: sessions, alive: settings.alive, now: now) == .answered {
                socket?.reply(item.connection, IslandAnswer.terminal.line)
                await finish(item, by: .terminal, answer: nil, notify: false)
            }
        }
    }

    static func processAlive(_ pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        // EPERM: it exists, and belongs to someone else.
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}
