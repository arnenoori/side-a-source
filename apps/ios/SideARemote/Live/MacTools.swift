import SideARemoteShared
import Foundation
import Observation
import SideAProtocol
import SideASessionKit
import SideARemoteKit

@Observable
final class MacTools {
    nonisolated deinit {}

    private(set) var capabilities: Set<Capability>
    private(set) var hosted: [String: HostedSession] = [:]
    /// A row this phone added itself, before the Mac's list had it, is not one.
    private(set) var dropped: Set<String> = []
    private(set) var attention: [String: HostedAttention] = [:]
    private(set) var options: OptionsList?
    @ObservationIgnored private var optionsFresh = false
    private(set) var projects: [RemoteProject] = []
    private(set) var autopilot: AutopilotState?
    private(set) var outlook: UsageOutlook?

    private(set) var forkedFrom: [String: String] = [:]

    private(set) var past: [String: PastSession] = [:]
    private(set) var snoozing: [SessionKey: (snooze: SessionSnooze?, at: Date)] = [:]

    private(set) var changed: [SessionKey: SessionSettings] = [:]
    private(set) var sessionModels: [SessionKey: [ModelOption]] = [:]

    let attachments = ComposerAttachments()
    let moves = SessionMoves()
    let standby = StandbyCopies()

    @ObservationIgnored private let mode: Mode
    private var keyless = false
    private(set) var answersAs: String?

    enum Mode {
        case demo(Demo)
        case live(Live)
        case unavailable
    }

    struct Demo {
        var options: OptionsList
        var projects: [RemoteProject]
        var autopilot: AutopilotState?
        var outlook: UsageOutlook?
    }

    struct Live {
        let engine: SyncEngine
        let paired: PairedMac
        let outbox: Outbox
        let sign: (DeviceKeys.Signer, ConfirmPurpose, _ subject: String, _ reason: String) async -> String?

        init(engine: SyncEngine, paired: PairedMac, outbox: Outbox,
             sign: ((DeviceKeys.Signer, ConfirmPurpose, String, String) async -> String?)? = nil) {
            self.engine = engine; self.paired = paired; self.outbox = outbox
            self.sign = sign ?? { await paired.sign($0, purpose: $1, subject: $2, reason: $3) }
        }
    }

    /// A start that carries a prompt: the row it makes is working from the tap, not idle until the CLI takes it.
    @ObservationIgnored var onLaunch: ((HostedSession) -> Void)?

    init(_ mode: Mode = .unavailable) {
        self.mode = mode
        capabilities = []
        switch mode {
        case .demo(let demo):
            capabilities = Self.everything
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--no-uploads") { capabilities.remove(.uploads) }
            #endif
            options = demo.options; projects = demo.projects; autopilot = demo.autopilot; outlook = demo.outlook
        case .live(let live):
            let macID = live.paired.endpoint.macID
            keyless = !DeviceKeys.has(.confirm, for: macID) || !DeviceKeys.has(.unlock, for: macID)
        case .unavailable:
            break
        }
        attachments.tools = self
    }

    var isLive: Bool { live != nil }
    var isDemo: Bool { if case .demo = mode { true } else { false } }
    private var live: Live? { if case .live(let live) = mode { live } else { nil } }
    private var paired: PairedMac? { live?.paired }

    func connection() throws -> Live {
        switch mode {
        case .live(let live): live
        case .demo: throw ToolError.demo
        case .unavailable: throw ToolError.unavailable
        }
    }

    static let everything: Set<Capability> = [.hosted, .terminal, .continueOnPhone, .uploads, .options, .history, .search, .restart, .ports,
                                              .quit, .mac, .cleanup, .autopilot, .incidents, .interrupt, .interruptNextStep, .replyNote,
                                              .replyTerminal, .replyInbox, .hostedTrust, .hostedShow, .accountsUse,
                                              .autopilotToggle, .autopilotAnswers, .autopilotContinues, .rotation, .repliesQueue, .files, .fileRead,
                                              .snooze, .pullRequests, .failures, .repliesPromote, .restartAgent, .moves, .movesWhen, .standby]

    func can(_ capability: Capability) -> Bool { capabilities.contains(capability) }

    /// Hosted sessions, Codex's server and the inbox hooks depend on what's installed there rather than its version, so a
    /// Mac without them isn't old.
    static let expected: Set<Capability> = [.history, .search, .quit, .mac, .cleanup, .incidents, .autopilot, .ports, .interrupt,
                                            .interruptNextStep, .uploads, .accountsUse, .rotation]

    static func lacksExpected(_ capabilities: Set<Capability>) -> Bool { !capabilities.isEmpty && !expected.isSubset(of: capabilities) }

    var needsMacUpdate: Bool { !isDemo && Self.lacksExpected(capabilities) }

    var needsKeys: Bool { keyless && can(.confirmSigned) }

    func noteRefusal(_ error: APIError) { if error.pairAgain { keyless = true } }

    func signed<T>(_ call: () async throws -> T) async throws -> T {
        do { return try await call() } catch let failure as RemoteFailure {
            noteRefusal(failure.error)
            throw failure
        }
    }

    private func guarded<T>(_ purpose: ConfirmPurpose = .action, subject: String, level: ConfirmLevel = .unlock, reason: String,
                            mustSign: Bool = false, _ call: (String?) async throws -> T) async throws -> T {
        let live = try connection()
        if needsKeys {
            if mustSign { throw ToolError.pairAgain }
            do { return try await signed { try await call(nil) } } catch let failure as RemoteFailure where [.confirmRequired, .confirmInvalid].contains(failure.error.code) {
                throw ToolError.pairAgain
            }
        }
        func signature(_ signer: DeviceKeys.Signer) async throws -> String? {
            let header = await live.sign(signer, purpose, subject, reason)
            if header == nil, mustSign { throw signer == .confirm ? ToolError.cancelled : ToolError.locked }
            return header
        }
        let faceID = level == .biometric && (mustSign || can(.confirmActions))
        let first = try await signature(faceID ? .confirm : .unlock)
        if faceID, first == nil { throw ToolError.cancelled }
        do {
            return try await signed { try await call(first) }
        } catch let failure as RemoteFailure where !faceID && failure.error.confirmLevel == .biometric && !failure.error.pairAgain {
            guard let stronger = try await signature(.confirm) else { throw ToolError.cancelled }
            return try await signed { try await call(stronger) }
        }
    }

    private var listed: Set<String> = []

    func apply(_ state: RemoteState) {
        let capabilities = state.hello?.capabilities ?? []
        if self.capabilities != capabilities { self.capabilities = capabilities }
        if let id = state.hello?.mac.id, let paired, id != paired.endpoint.macID, answersAs != id {
            answersAs = id
            keyless = true
        }
        let gone = listed.filter { state.hosted[$0] == nil }
        if !gone.isEmpty { dropped.formUnion(gone) }
        listed = Set(state.hosted.keys)
        if !dropped.isDisjoint(with: listed) { dropped.subtract(listed) }
        if hosted != state.hosted { hosted = state.hosted }
        if attention != state.attention { attention = state.attention }
        if let latest = state.autopilot, autopilot != latest { autopilot = latest }
        for (id, settings) in changed {
            guard let row = state.sessions[id] else { continue }
            let left = settings.pending(over: row.settings)
            if left != settings { changed[id] = left }
        }
        noteMoves(state)
    }

    func unlisted(in sessions: [RemoteSession]) -> [HostedSession] {
        let names = Set(sessions.compactMap(\.hosted))
        let ids = Set(sessions.map(\.id))
        return hosted.values.filter { $0.alive && !names.contains($0.name) && !($0.sessionID.map(ids.contains) ?? false) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func attention(for session: RemoteSession) -> HostedAttention? {
        (session.hosted ?? hosted(for: session)?.name).flatMap { attention[$0] }
    }

    func showDemoRotation(_ state: AutopilotState, outlook: UsageOutlook?) {
        guard isDemo else { return }
        autopilot = state
        self.outlook = outlook
    }

    #if DEBUG
    func show(_ notice: HostedAttention) {
        attention[notice.name] = notice
        if hosted[notice.name] == nil {
            hosted[notice.name] = HostedSession(name: notice.name, agent: .codex, cwd: "~/Coding/side-a", project: "side-a", createdAt: Date.now.timeIntervalSince1970)
        }
    }
    #endif

    func hosted(for session: RemoteSession) -> HostedSession? {
        session.hosted.flatMap { hosted[$0] } ?? hosted.values.first { $0.sessionID == session.id }
    }

    func client() async throws -> RemoteClient {
        await (try connection()).engine.client
    }

    func loadOptions(force: Bool = false) async {
        guard !isDemo, can(.options), force || options == nil || !optionsFresh else { return }
        guard let client = try? await client(), let list = try? await client.reaching({ try await client.options() }) else { return }
        options = list
        optionsFresh = true
    }

    func restore(options: OptionsList?, projects: [RemoteProject]?) {
        if self.options == nil, let options { self.options = options }
        if self.projects.isEmpty, let projects { self.projects = projects }
    }

    func models(for agent: AgentProvider) -> [ModelOption] {
        options?.agents.first { $0.agent == agent }?.models ?? []
    }

    func agent(_ agent: AgentProvider) -> AgentOptions? { options?.agents.first { $0.agent == agent } }

    func loadProjects() async throws {
        guard !isDemo else { return }
        let client = try await client()
        projects = try await client.reaching { try await client.projects() }.projects
    }

    /// The key is the caller's, made once per sheet, so a second tap on Start, or a resend while the Mac is out of reach,
    /// is a replay, not a second session.
    func start(_ start: StartHosted, key: String, waiting: @escaping () -> Void = {}) async throws -> HostedSession {
        #if DEBUG
        if isDemo, ProcessInfo.processInfo.arguments.contains("--demo-start") {
            let name = "sa-demo-\(key.prefix(4))"
            let session = HostedSession(name: name, agent: start.agent, cwd: start.cwd, project: URL(fileURLWithPath: start.cwd).lastPathComponent,
                                        createdAt: Date.now.timeIntervalSince1970)
            hosted[name] = session
            if start.prompt?.isEmpty == false { onLaunch?(session) }
            return session
        }
        #endif
        let session: HostedSession = try await guarded(.settings, subject: ConfirmMessage.subject(start: start), level: ConfirmPolicy.start(start), reason: "Start this session") { confirm in
            let client = try await client()
            return try await client.reaching(for: Self.startWaits, missed: waiting) {
                try await client.post("/v1/hosted", json: start, idempotencyKey: key, confirm: confirm)
            }
        }
        hosted[session.name] = session
        if start.prompt?.isEmpty == false { onLaunch?(session) }
        return session
    }

    /// Inside the signature's two minutes, with room for a request that runs out its own timeout on the way.
    static let startWaits: Double = 75

    func fork(_ session: RemoteSession) async throws -> HostedSession {
        guard let conversation = session.conversationID, let cwd = session.cwd else { throw ToolError.gone }
        let hosted = try await start(StartHosted(cwd: cwd, agent: session.agent, resume: conversation, fork: true), key: UUID().uuidString.lowercased())
        forkedFrom[hosted.name] = session.title
        return hosted
    }

    func continueOnPhone(_ session: SessionKey) async throws -> HostedSession {
        let hosted = try await guarded(subject: ConfirmMessage.subject(action: .continue, target: session), reason: "Continue this session on \(ThisDevice.kind)") { confirm in
            try await client().continueOnPhone(session, confirm: confirm)
        }
        self.hosted[hosted.name] = hosted
        return hosted
    }

    func handoff(_ session: SessionKey) async throws -> Handoff { try await client().handoff(session) }

    func restart(_ session: SessionKey, _ handoff: Handoff, key: String) async throws -> HostedSession {
        let restart = RestartRequest(handoff: handoff, accountID: handoff.accountID, model: handoff.model)
        let hosted = try await guarded(subject: ConfirmMessage.subject(action: .restart, target: session, body: restart), reason: "Restart this session") { confirm in
            try await client().restart(session, restart, idempotencyKey: key, confirm: confirm)
        }
        onLaunch?(hosted)
        return hosted
    }

    func otherAgent(for session: RemoteSession) -> AgentOptions? {
        guard can(.restartAgent), can(.hosted), session.cwd != nil, session.conversationID != nil, !session.headless else { return nil }
        guard let options = agent(session.agent == .claude ? .codex : .claude), options.installed, options.signedIn == true,
              !options.models.isEmpty else { return nil }
        return options
    }

    /// Never through the outbox: a handoff that waited could start long after the person moved on, so it goes now or not at all.
    func handOff(_ session: RemoteSession, draft: HandoffDraft, message: String, photos: [String] = [], key: String) async throws -> HostedSession {
        let handoff: Handoff
        if let reviewed = draft.handoff { handoff = reviewed } else { handoff = try await self.handoff(session.id) }
        let restart = RestartRequest(handoff: handoff, accountID: draft.accountID, model: draft.modelID, agent: draft.agent,
                                     effort: draft.effort?.rawValue, permissionMode: PermissionMode.handedOff(mode(of: session), to: draft.agent).mode,
                                     message: message, attachments: can(.restartAgentImages) ? photos : nil)
        let hosted = try await guarded(subject: ConfirmMessage.subject(action: .restart, target: session.id, body: restart),
                                       level: ConfirmPolicy.restart(restart, sessionMode: mode(of: session)), reason: "Hand off to \(draft.agent.title)") { confirm in
            let client = try await client()
            return try await client.reaching(for: Self.startWaits) {
                try await client.restart(session.id, restart, idempotencyKey: key, confirm: confirm)
            }
        }
        onLaunch?(hosted)
        return hosted
    }

    func earlierPage(_ conversation: String, before: Cursor?) async throws -> TranscriptPage {
        if isDemo { return demoEarlierPage(conversation) }
        let client = try await client()
        return try await client.reaching { try await client.transcript(conversation, before.map { .before($0) } ?? .latest, limit: 40) }
    }

    func handoffPrompt(_ id: String) async throws -> String {
        if isDemo { return demoHandoffPrompt() }
        let client = try await client()
        return try await client.reaching { try await client.handoffPrompt(id) }.text
    }

    func quit(_ session: SessionKey) async throws {
        try await guarded(subject: ConfirmMessage.subject(action: .quit, target: session), reason: "Quit this session") { try await client().quit(session, confirm: $0) }
    }
    func quitIdle(olderThanMinutes: Int = 30) async throws -> [SessionKey] {
        try await guarded(subject: ConfirmMessage.subject(action: .quitIdle, body: QuitIdleRequest(olderThanMinutes: olderThanMinutes)), reason: "Quit idle sessions") {
            try await client().quitIdle(olderThanMinutes: olderThanMinutes, confirm: $0).quit
        }
    }

    /// A dialog that's already gone (409 `cannot_deliver`) just clears the card.
    func trust(_ name: String) async throws {
        guard let hosted = hosted[name] else { throw ToolError.gone }
        let confirm = try await faceID(.trust, subject: ConfirmMessage.subject(trust: name, cwd: hosted.cwd), reason: "Trust \(hosted.project) and start")
        do {
            self.hosted[name] = try await signed { try await client().trust(hosted, confirm: confirm) }
        } catch let failure as RemoteFailure where failure.error.code == .cannotDeliver {}
        attention[name] = nil
    }

    func follow(_ ref: SubagentRef, into store: TranscriptStore) async {
        guard isLive else { return }
        var failures = 0
        var rows: [TranscriptMessage] = []
        var generation = "", cursor: Cursor?
        var changedAt = ContinuousClock.now
        while !Task.isCancelled {
            var more = false
            do {
                // The newest rows once, then only what came after them: a poll that finds nothing new costs a few hundred bytes.
                let page = try await client().transcript(ref.parent, cursor.map { .after($0) } ?? .latest, limit: 200, agent: ref.agentID)
                failures = 0
                let before = rows
                if cursor == nil || page.reset || page.generation != generation {
                    rows = page.messages
                    generation = page.generation
                } else {
                    for message in page.replaced + page.messages {
                        if let index = rows.firstIndex(where: { $0.seq == message.seq }) { rows[index] = message } else { rows.append(message) }
                    }
                    rows.sort { $0.seq < $1.seq }
                }
                cursor = page.after
                more = page.hasMoreAfter
                if rows != before {
                    changedAt = .now
                    store.set(rows, hasEarlier: false, for: ref.key)
                }
            } catch {
                failures += 1
            }
            if more { continue }
            let still = ContinuousClock.now - changedAt > .seconds(60)
            try? await Task.sleep(for: .seconds(failures > 0 ? min(60, 3 << min(failures, 5)) : still ? 15 : 3))
        }
    }

    func showOnMac(_ name: String) async throws {
        guard !isDemo else { return }
        hosted[name] = try await client().showOnMac(name)
        openedOnMac.insert(name)
    }

    /// Asked for from here: the Mac lists the tab only once it has attached.
    private var openedOnMac: Set<String> = []

    func onMac(_ name: String) -> Bool { hosted[name]?.macAttached == true || openedOnMac.contains(name) }

    func settings(of session: RemoteSession) -> SessionSettings {
        let row = session.settings, mine = changed[session.id]
        return SessionSettings(model: mine?.model ?? row?.model ?? session.model,
                               effort: mine?.effort ?? row?.effort ?? session.effort.map(Effort.init(rawValue:)),
                               mode: mine?.mode ?? row?.mode, fast: mine?.fast ?? row?.fast)
    }

    func mode(of session: RemoteSession) -> PermissionMode? { settings(of: session).mode }

    func models(for session: RemoteSession) -> [ModelOption] {
        var models = sessionModels[session.id] ?? models(for: session.agent)
        if let current = settings(of: session).model, !models.contains(where: { $0.id == current || $0.title == current }) {
            models.insert(ModelOption(id: current, title: ModelName.short(current), agent: session.agent), at: 0)
        }
        return models
    }

    func loadModels(for session: RemoteSession) async {
        guard session.takesModelSettings else { return }
        guard isLive, let client = try? await client() else { return }
        if let list = try? await client.reaching({ try await client.models(session.agent, session: session.id) }) { sessionModels[session.id] = list.models }
    }

    func change(_ session: RemoteSession, _ change: SettingsChange, title: String) async throws -> SettingsResult {
        if isDemo {
            let result = SettingsResult(settings: SessionSettings(model: change.model, effort: change.effort, mode: change.mode, fast: change.fast),
                                        nextTurn: session.agent == .codex)
            changed[session.id] = (changed[session.id] ?? SessionSettings()).merging(result.settings)
            return result
        }
        let result = try await guarded(.settings, subject: ConfirmMessage.subject(sessionID: session.id, settings: change),
                                       level: change.raises ? .biometric : .unlock, reason: "Switch to \(title)", mustSign: true) { confirm in
            try await client().settings(session.id, change, confirm: confirm)
        }
        let done = result.settings
        let mine = SessionSettings(model: change.model.map { done.model ?? $0 }, effort: change.effort.map { done.effort ?? $0 },
                                   mode: change.mode.map { done.mode ?? $0 }, fast: change.fast.map { done.fast ?? $0 })
        changed[session.id] = (changed[session.id] ?? SessionSettings()).merging(mine)
        return result
    }

    func files(_ session: SessionKey, matching query: String) async -> [String] {
        if isDemo { return DemoData.files.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
        guard can(.files) else { return [] }
        return (try? await signed { try await client().files(session, matching: query) })?.files ?? []
    }

    func file(_ session: SessionKey, path: String) async throws -> URL {
        guard can(.fileRead) else { throw ToolError.oldMac }
        let data = try await client().file(session, path: path)
        let files = FileManager.default.temporaryDirectory.appendingPathComponent("files", isDirectory: true)
        let old = (try? FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in old where ((try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) < .now.addingTimeInterval(-3600) {
            try? FileManager.default.removeItem(at: folder)
        }
        let name = (path as NSString).lastPathComponent
        let folder = files.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "file" : name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func removeQueued(_ reply: QueuedReply, in session: SessionKey) async throws {
        if isDemo { return }
        try await signed { try await client().removeQueued(session, reply.id) }
    }

    func reword(_ reply: QueuedReply, to text: String, in session: SessionKey) async throws {
        if isDemo { return }
        var body = RemoteReply(text: text, mode: .followUp)
        body.replaces = reply.id
        let _: ReplyResult = try await guarded(subject: ConfirmMessage.subject(action: .reply, target: session, body: body), reason: "Change this message") {
            try await client().post("/v1/sessions/\(session)/reply", json: body, confirm: $0)
        }
    }

    func compact(_ session: SessionKey) async throws {
        if isDemo { return }
        try await guarded(subject: ConfirmMessage.subject(action: .compact, target: session), reason: "Compact this session") { try await client().compact(session, confirm: $0) }
    }

    func review(_ session: SessionKey) async throws {
        if isDemo { return }
        try await guarded(subject: ConfirmMessage.subject(action: .review, target: session, body: ReviewRequest()), reason: "Review this session's changes") {
            try await client().review(session, confirm: $0)
        }
    }

    func turnDiff(_ session: SessionKey, turn: String, demo messages: [TranscriptMessage]) async throws -> TurnDiff {
        if isDemo {
            var files = messages.flatMap(\.tools).flatMap(\.diffs)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--cut-diff") {
                files = files.map { FileDiff(path: $0.path, oldPath: $0.oldPath, change: $0.change, additions: $0.additions,
                                             deletions: $0.deletions, hunks: $0.hunks, truncated: true) }
            }
            #endif
            return TurnDiff(sessionID: session, turnID: turn, files: files, note: "Edits made with Claude's file tools; shell changes aren't shown.")
        }
        return try await client().turnDiff(session, turn: turn)
    }

    func terminal(_ name: String) async -> TerminalModel {
        guard let live else { return TerminalModel(name: name, session: nil) }
        let paired = live.paired
        let confirm = needsKeys ? nil : DeviceKeys.terminal(macID: paired.endpoint.macID, deviceID: paired.deviceID)
        let session = TerminalSession(client: await live.engine.client, name: name, viewer: TerminalModel.viewer(for: name, mac: paired.endpoint.macID),
                                      outbox: live.outbox,
                                      confirm: confirm)
        let model = TerminalModel(name: name, session: session)
        model.kind = paired.endpoint.kind
        return model
    }

    func screen(hosted: String?) async -> ScreenModel {
        guard let live else { return ScreenModel(session: nil, hosted: hosted, screenOn: false, needsKeys: false) }
        let kind = live.paired.endpoint.kind
        let confirm = needsKeys ? nil : DeviceKeys.screen(macID: live.paired.endpoint.macID, deviceID: live.paired.deviceID, kind: kind)
        return ScreenModel(session: ScreenSession(client: await live.engine.client, confirm: confirm), hosted: hosted,
                           screenOn: can(.screenOn), needsKeys: needsKeys, kind: kind)
    }

    func serverKeyHash() async -> String? { await live?.engine.endpoint.serverKeyHash }

    func preview(_ session: SessionKey, port: Int) async throws -> URL {
        let preview = try await guarded(subject: ConfirmMessage.subject(action: .preview, target: "\(session):\(port)"), reason: "Preview this server") {
            try await client().preview(session, port: port, confirm: $0)
        }
        guard let url = URL(string: preview.url) else { throw ToolError.badURL }
        return url
    }

    func endPreview(_ session: SessionKey, port: Int) async { try? await client().endPreview(session, port: port) }
    func stopServer(_ session: SessionKey, port: Int) async throws {
        try await guarded(subject: ConfirmMessage.subject(action: .stopServer, target: "\(session):\(port)"), reason: "Stop this server") {
            try await client().stopServer(session, port: port, confirm: $0)
        }
    }

    func setKeepAwake(_ on: Bool) async throws -> MacState {
        let settings = MacSettings(keepAwake: on)
        return try await guarded(subject: ConfirmMessage.subject(action: .macSettings, body: settings), reason: "Change Keep Awake") { try await client().setMac(settings, confirm: $0) }
    }
    func cleanup() async throws -> CleanupReport { try await client().cleanup() }
    func archive(olderThanDays days: Int) async throws -> Int {
        try await guarded(subject: ConfirmMessage.subject(action: .archive, body: ArchiveRequest(olderThanDays: days)), reason: "Archive conversations") {
            try await client().archive(olderThanDays: days, confirm: $0).count
        }
    }
    func restoreArchived() async throws -> Int {
        try await guarded(subject: ConfirmMessage.subject(action: .restore), reason: "Restore archived conversations") { try await client().restoreArchived(confirm: $0).count }
    }
    func removeWorktree(_ id: String) async throws {
        try await guarded(subject: ConfirmMessage.subject(action: .removeWorktree, target: id), reason: "Remove this worktree") { try await client().removeWorktree(id, confirm: $0) }
    }
    func loadAutopilot() async throws {
        guard !isDemo, can(.autopilot) else { return }
        autopilot = try await client().autopilot()
    }

    func moveNow() async throws {
        autopilot = try await guarded(subject: ConfirmMessage.subject(action: .moveNow), reason: "Move sessions now") { try await client().moveNow(confirm: $0) }
    }

    func setAutopilot(_ enabled: Bool) async throws {
        let change = AutopilotChange(enabled: enabled)
        if isDemo {
            autopilot = autopilot?.changing(enabled: enabled) ?? AutopilotState(enabled: enabled)
            return
        }
        let confirm = try await faceID(.autopilot, subject: ConfirmMessage.subject(autopilot: change),
                                       reason: enabled ? "Turn on Autopilot" : "Turn off Autopilot")
        autopilot = try await signed { try await client().setAutopilot(change, confirm: confirm) }
    }

    func setAnswersRecommended(_ enabled: Bool) async throws {
        let change = AutopilotChange(enabled: enabled)
        if isDemo {
            autopilot = autopilot?.changing(answersRecommended: enabled) ?? AutopilotState(enabled: true, answersRecommended: enabled)
            return
        }
        let confirm = try await faceID(.autopilot, subject: ConfirmMessage.subject(autopilotAnswers: change),
                                       reason: enabled ? "Answer with recommended after 1 minute" : "Stop answering with recommended")
        autopilot = try await signed { try await client().setAutopilotAnswers(change, confirm: confirm) }
    }

    func setContinuesStopped(_ enabled: Bool) async throws {
        let change = AutopilotChange(enabled: enabled)
        if isDemo {
            autopilot = (autopilot ?? AutopilotState(enabled: true)).continuing(enabled)
            return
        }
        let confirm = try await faceID(.autopilot, subject: ConfirmMessage.subject(autopilotContinues: change),
                                       reason: enabled ? "Continue sessions once a limit lifts" : "Stop continuing sessions")
        autopilot = try await signed { try await client().setAutopilotContinues(change, confirm: confirm) }
    }

    func loadOutlook() async {
        guard isLive, can(.rotation), let latest = try? await client().outlook() else { return }
        if outlook != latest { outlook = latest }
    }

    func setSwapAt(_ percent: Int) async throws {
        if isDemo { autopilot = autopilot?.changing(swapAt: percent); return }
        let confirm = try await faceID(.rotation, subject: ConfirmMessage.subject(swapAt: percent), reason: "Move at \(percent)%")
        autopilot = try await signed { try await client().setSwapAt(percent, confirm: confirm) }
    }

    func setFollowFable(_ enabled: Bool) async throws {
        if isDemo { autopilot = autopilot?.changing(followFable: enabled); return }
        let confirm = try await faceID(.rotation, subject: ConfirmMessage.subject(followFable: enabled),
                                       reason: enabled ? "Follow Fable" : "Stop following Fable")
        autopilot = try await signed { try await client().setFollowFable(enabled, confirm: confirm) }
    }

    func setPriority(_ account: RemoteAccount, _ level: PriorityLevel) async throws {
        let engine = try connection().engine
        let confirm = try await faceID(.rotation, subject: ConfirmMessage.subject(account: account.id, priority: level),
                                       reason: "Use \(account.name) \(RotationText.priority(level).lowercased())")
        try await signed { try await engine.setPriority(account.id, level, confirm: confirm) }
    }

    func setAuto(_ account: RemoteAccount, _ enabled: Bool) async throws {
        let engine = try connection().engine
        let confirm = try await faceID(.rotation, subject: ConfirmMessage.subject(account: account.id, auto: enabled),
                                       reason: enabled ? "Let Autopilot use \(account.name)" : "Keep Autopilot off \(account.name)")
        try await signed { try await engine.setAuto(account.id, enabled, confirm: confirm) }
    }

    func useAccount(_ account: RemoteAccount) async throws {
        let engine = try connection().engine
        let confirm = try await faceID(.account, subject: ConfirmMessage.subject(useAccount: account.id), reason: "Use \(account.name)")
        try await signed { try await engine.useAccount(account.id, confirm: confirm) }
    }

    func faceID(_ purpose: ConfirmPurpose, subject: String, reason: String) async throws -> String {
        let live = try connection()
        guard !needsKeys else { throw ToolError.pairAgain }
        guard let confirm = await live.sign(.confirm, purpose, subject, reason) else { throw ToolError.cancelled }
        return confirm
    }

    func history(archived: Bool, cursor: Cursor?) async throws -> HistoryPage { try await client().history(archived: archived, cursor: cursor) }
    func search(_ query: String, cursor: Cursor?) async throws -> SearchResults { try await client().search(query, cursor: cursor, limit: 30) }
    func change(_ conversation: String, _ change: HistoryChange) async throws -> PastSession {
        if isDemo {
            let updated = (past[conversation] ?? PastSession(id: conversation, agent: .claude, title: "", project: "")).applying(change)
            past[conversation] = updated
            return updated
        }
        let updated = try await client().change(conversation, change)
        past[conversation] = updated
        return updated
    }

    func title(for session: RemoteSession) -> String {
        session.conversationID.flatMap { past[$0]?.customTitle } ?? session.title
    }

    func isPinned(_ session: RemoteSession) -> Bool { session.conversationID.flatMap { past[$0]?.pinned } ?? false }

    func snooze(of session: RemoteSession, now: Date = .now) -> SessionSnooze? {
        guard session.openRequests.isEmpty, session.status != .waiting, session.failure == nil else { return nil }
        let mine = snoozing[session.id].flatMap { isDemo || now.timeIntervalSince($0.at) < 15 ? $0 : nil }
        let snooze = mine.map(\.snooze) ?? session.snooze
        return snooze?.until.map { $0 > now.timeIntervalSince1970 } ?? true ? snooze : nil
    }

    /// Nil `choice` wakes it.
    func snooze(_ session: RemoteSession, _ choice: SessionSnooze.Choice?, until: Date?) async throws {
        let before = snoozing[session.id]
        snoozing[session.id] = (choice.map { SessionSnooze(choice: $0, until: until?.timeIntervalSince1970, at: Date.now.timeIntervalSince1970) }, .now)
        guard !isDemo else { return }
        do {
            let row = try await client().snooze(session.id, SnoozeRequest(choice: choice, until: until?.timeIntervalSince1970))
            snoozing[session.id] = (row.snooze, .now)
        } catch {
            snoozing[session.id] = before
            throw error
        }
    }

    func loadPast() async {
        guard !isDemo, can(.history), past.isEmpty, let page = try? await history(archived: false, cursor: nil) else { return }
        for row in page.sessions where row.isPinned || row.customTitle != nil { past[row.id] = row }
    }

    func upload(_ data: Data, mime: String) async throws -> Upload {
        try await connection().engine.upload(data, mime: mime)
    }

    func transcribe(_ audio: Data, _ ask: TranscribeAsk) async throws -> TranscribeResult {
        try await client().transcribe(audio, ask)
    }

    private static var fleet: HostOS { PairedMac.all().map(\.endpoint.kind).shared }

    static func message(_ error: Error) -> String {
        switch error {
        case let failure as RemoteFailure: failure.error.message
        case ToolError.demo: "The demo doesn't change anything."
        case ToolError.unavailable: "Side A can't open its storage on this \(ThisDevice.kind). Reinstall it to make changes."
        case ToolError.badURL: "\(fleet.sentenceThe()) sent an address the phone can't open."
        case ToolError.gone: "\(fleet.sentenceThe()) no longer lists this session."
        case ToolError.cancelled: "Cancelled."
        case ToolError.locked: "Unlock your \(ThisDevice.kind) to do this."
        case ToolError.pairAgain: "Pair this \(ThisDevice.kind) again to do this from it."
        case ToolError.oldMac: "Update Side A on \(fleet.your()) to open its files here."
        default: (error as NSError).localizedDescription
        }
    }
}

extension AutopilotState {
    func changing(enabled: Bool? = nil, answersRecommended: Bool? = nil, swapAt: Int? = nil, followFable: Bool? = nil) -> AutopilotState {
        var changed = AutopilotState(enabled: enabled ?? self.enabled, pending: pending, decisions: decisions,
                       answersRecommended: answersRecommended ?? self.answersRecommended, held: held, next: next, waiting: waiting,
                       swapAt: swapAt ?? self.swapAt, followFable: followFable ?? self.followFable, fableMode: fableMode)
        changed.continuesStopped = continuesStopped
        return changed
    }
}

enum ToolError: Error {
    case demo, badURL
    case gone
    case unavailable
    case cancelled
    case locked
    case pairAgain
    case oldMac
}
