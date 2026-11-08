import Foundation
import Observation
import SideAProtocol
import SideARemoteKit

/// The Mac's tools beyond the core sync: what it can do (its capabilities), what the composer and New
/// Session offer (options, projects), and the calls that start, move, end and clean up sessions. A
/// control shows only when the Mac lists its capability. The demo answers from its own data and
/// changes nothing.
@Observable
final class MacTools {
    nonisolated deinit {}

    /// From the Mac's latest `Hello`; everything in the demo.
    private(set) var capabilities: Set<Capability>
    /// Hosted sessions by tmux name.
    private(set) var hosted: [String: HostedSession] = [:]
    /// What a hosted session's screen needs a person for (`hosted.attention`), by tmux name, until the session changes.
    private(set) var attention: [String: HostedAttention] = [:]
    private(set) var options: OptionsList?
    private(set) var projects: [RemoteProject] = []
    /// Open incidents on the providers' status pages.
    private(set) var incidents: [Incident] = []
    /// From `GET /v1/autopilot`, and each Move Now.
    private(set) var autopilot: AutopilotState?
    /// From `GET /v1/usage/outlook`, whenever a reading arrives.
    private(set) var outlook: UsageOutlook?

    /// Forks started from this phone: the hosted session's name, and the title of the session it came from.
    private(set) var forkedFrom: [String: String] = [:]

    /// Live sessions' History rows as the Mac last answered a change: pin and Side A's own title.
    private(set) var past: [String: PastSession] = [:]

    /// Settings changed from this phone, field by field, until the session's row says so; the demo keeps them.
    private(set) var changed: [SessionKey: SessionSettings] = [:]
    /// Each session's models from `GET /v1/models`, which for Codex are its own home's.
    private(set) var sessionModels: [SessionKey: [ModelOption]] = [:]

    /// Photos waiting for each session's next reply.
    let attachments = ComposerAttachments()

    @ObservationIgnored private let mode: Mode
    /// No keys to sign with: this iPhone has none for the Mac (a pairing from before them), or the Mac said it has
    /// none (`details.hint = pairAgain`).
    private var keyless = false
    /// The id the Mac at this pairing's address answers to, when it isn't the one this pairing signs for: its signatures
    /// can't verify, whatever the keys. Side A Dev under the id it shared with release before it got its own, say.
    private(set) var answersAs: String?

    /// Set once. `unavailable`: no Mac to act on, before pairing or when the outbox can't open, so every change fails
    /// instead of pretending as the demo does.
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
        /// The Mac these tools act on, for the device keys that sign for it.
        let paired: PairedMac
        /// Where terminal input waits for its ack, shared with the extensions.
        let outbox: Outbox
        /// `paired.sign`, unless a test stands in for Face ID, which needs a person.
        let sign: (DeviceKeys.Signer, ConfirmPurpose, _ subject: String, _ reason: String) async -> String?

        init(engine: SyncEngine, paired: PairedMac, outbox: Outbox,
             sign: ((DeviceKeys.Signer, ConfirmPurpose, String, String) async -> String?)? = nil) {
            self.engine = engine; self.paired = paired; self.outbox = outbox
            self.sign = sign ?? { await paired.sign($0, purpose: $1, subject: $2, reason: $3) }
        }
    }

    init(_ mode: Mode = .unavailable) {
        self.mode = mode
        capabilities = []
        switch mode {
        case .demo(let demo):
            capabilities = Self.everything
            options = demo.options; projects = demo.projects; autopilot = demo.autopilot; outlook = demo.outlook
        case .live(let live):
            let macID = live.paired.endpoint.macID
            keyless = !DeviceKeys.has(.confirm, for: macID) || !DeviceKeys.has(.unlock, for: macID)
        case .unavailable:
            break
        }
        attachments.tools = self
    }

    /// Talking to a real Mac, not the demo.
    var isLive: Bool { live != nil }
    var isDemo: Bool { if case .demo = mode { true } else { false } }
    private var live: Live? { if case .live(let live) = mode { live } else { nil } }
    private var paired: PairedMac? { live?.paired }

    /// The Mac to act on, or why there's none.
    private func connection() throws -> Live {
        switch mode {
        case .live(let live): live
        case .demo: throw ToolError.demo
        case .unavailable: throw ToolError.unavailable
        }
    }

    static let everything: Set<Capability> = [.hosted, .terminal, .continueOnPhone, .uploads, .options, .history, .search, .restart, .ports,
                                              .quit, .mac, .cleanup, .autopilot, .incidents, .interrupt, .interruptNextStep, .replyNote,
                                              .replyTerminal, .replyInbox, .hostedTrust, .accountsUse,
                                              .autopilotToggle, .autopilotAnswers, .rotation]

    func can(_ capability: Capability) -> Bool { capabilities.contains(capability) }

    /// The Mac checks signatures and this pairing can't make any it accepts: allows past the Lock Screen, settings,
    /// the terminal, accounts and Autopilot wait for Pair Again, and Face ID isn't asked for in vain.
    var needsKeys: Bool { keyless && can(.confirmSigned) }

    /// A refusal that says the Mac holds no keys for this iPhone.
    func noteRefusal(_ error: APIError) { if error.pairAgain { keyless = true } }

    /// A call carrying a signature; a `pairAgain` refusal is noted on its way back.
    private func signed<T>(_ call: () async throws -> T) async throws -> T {
        do { return try await call() } catch let failure as RemoteFailure {
            noteRefusal(failure.error)
            throw failure
        }
    }

    /// Runs a call the Mac may want signed. The unlock key signs silently, or Face ID when `level` asks and this Mac wants
    /// it; a Mac that wants more than the phone thought says so, and Face ID signs it again. With nothing to sign with
    /// the call goes as it is: an older Mac takes it, and a newer one's refusal is what the user reads. `mustSign`: it
    /// never goes unsigned, a locked phone throws `.locked`, and Face ID is asked for `level` whatever the Mac lists.
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

    /// From each new state of the sync engine.
    func apply(_ state: RemoteState) {
        let capabilities = state.hello?.capabilities ?? []
        if self.capabilities != capabilities { self.capabilities = capabilities }
        if let id = state.hello?.mac.id, let paired, id != paired.endpoint.macID, answersAs != id {
            answersAs = id
            keyless = true
        }
        if hosted != state.hosted { hosted = state.hosted }
        if attention != state.attention { attention = state.attention }
        if incidents != state.incidents { incidents = state.incidents }
        if let latest = state.autopilot, autopilot != latest { autopilot = latest }
        for (id, settings) in changed {
            guard let row = state.sessions[id] else { continue }
            let left = settings.pending(over: row.settings)
            if left != settings { changed[id] = left }
        }
    }

    func attention(for session: RemoteSession) -> HostedAttention? {
        (session.hosted ?? hosted(for: session)?.name).flatMap { attention[$0] }
    }

    /// The demo's Autopilot and combined room.
    func showDemoRotation(_ state: AutopilotState, outlook: UsageOutlook?) {
        guard isDemo else { return }
        autopilot = state
        self.outlook = outlook
    }

    #if DEBUG
    /// `--attention`: a notice on the demo's hosted session, for screenshots.
    func show(_ notice: HostedAttention) {
        attention[notice.name] = notice
        if hosted[notice.name] == nil {
            hosted[notice.name] = HostedSession(name: notice.name, agent: .codex, cwd: "~/Coding/side-a", project: "side-a", createdAt: Date.now.timeIntervalSince1970)
        }
    }
    #endif

    /// The hosted session a live session runs in, when the Mac hosts it.
    func hosted(for session: RemoteSession) -> HostedSession? {
        session.hosted.flatMap { hosted[$0] } ?? hosted.values.first { $0.sessionID == session.id }
    }

    private func client() async throws -> RemoteClient {
        await (try connection()).engine.client
    }

    // MARK: Options and projects

    /// Once per launch, again on demand; a Mac without `options` leaves the composer's own list.
    func loadOptions(force: Bool = false) async {
        guard !isDemo, can(.options), force || options == nil else { return }
        if let list = try? await client().options() { options = list }
    }

    func models(for agent: AgentProvider) -> [ModelOption] {
        options?.agents.first { $0.agent == agent }?.models ?? []
    }

    func agent(_ agent: AgentProvider) -> AgentOptions? { options?.agents.first { $0.agent == agent } }

    func loadProjects() async throws {
        guard !isDemo else { return }
        projects = try await client().projects().projects
    }

    // MARK: Sessions

    /// The key is the caller's, made once per sheet, so a second tap on Start is a replay, not a second session.
    func start(_ start: StartHosted, key: String) async throws -> HostedSession {
        let session: HostedSession = try await guarded(.settings, subject: ConfirmMessage.subject(start: start), level: ConfirmPolicy.start(start), reason: "Start this session") { confirm in
            try await client().post("/v1/hosted", json: start, idempotencyKey: key, confirm: confirm)
        }
        hosted[session.name] = session
        return session
    }

    /// A new hosted session continuing from a live one's latest state; the parent keeps running.
    func fork(_ session: RemoteSession) async throws -> HostedSession {
        guard let conversation = session.conversationID, let cwd = session.cwd else { throw ToolError.demo }
        let hosted = try await start(StartHosted(cwd: cwd, agent: session.agent, resume: conversation, fork: true), key: UUID().uuidString.lowercased())
        forkedFrom[hosted.name] = session.title
        return hosted
    }

    func continueOnPhone(_ session: SessionKey) async throws -> HostedSession {
        let hosted = try await guarded(subject: ConfirmMessage.subject(action: .continue, target: session), reason: "Continue this session on iPhone") { confirm in
            try await client().continueOnPhone(session, confirm: confirm)
        }
        self.hosted[hosted.name] = hosted
        return hosted
    }

    func handoff(_ session: SessionKey) async throws -> Handoff { try await client().handoff(session) }

    func restart(_ session: SessionKey, _ handoff: Handoff, key: String) async throws -> HostedSession {
        let restart = RestartRequest(handoff: handoff, accountID: handoff.accountID, model: handoff.model)
        return try await guarded(subject: ConfirmMessage.subject(action: .restart, target: session, body: restart), reason: "Restart this session") { confirm in
            try await client().restart(session, restart, idempotencyKey: key, confirm: confirm)
        }
    }

    func quit(_ session: SessionKey) async throws {
        try await guarded(subject: ConfirmMessage.subject(action: .quit, target: session), reason: "Quit this session") { try await client().quit(session, confirm: $0) }
    }
    func quitIdle(olderThanMinutes: Int = 30) async throws -> [SessionKey] {
        try await guarded(subject: ConfirmMessage.subject(action: .quitIdle, body: QuitIdleRequest(olderThanMinutes: olderThanMinutes)), reason: "Quit idle sessions") {
            try await client().quitIdle(olderThanMinutes: olderThanMinutes, confirm: $0).quit
        }
    }

    /// Trust and Start: after Face ID the confirm key signs the folder the user saw, and the Mac answers its trust
    /// dialog. A dialog that's already gone (409 `cannot_deliver`) just clears the card.
    func trust(_ name: String) async throws {
        guard let hosted = hosted[name] else { throw ToolError.demo }
        let confirm = try await faceID(.trust, subject: ConfirmMessage.subject(trust: name, cwd: hosted.cwd), reason: "Trust \(hosted.project) and start")
        do {
            self.hosted[name] = try await signed { try await client().trust(hosted, confirm: confirm) }
        } catch let failure as RemoteFailure where failure.error.code == .cannotDeliver {}
        attention[name] = nil
    }

    // MARK: Settings

    /// The session's settings as it runs, or as just changed from here; model and effort fall back to the row's own.
    func settings(of session: RemoteSession) -> SessionSettings {
        let row = session.settings, mine = changed[session.id]
        return SessionSettings(model: mine?.model ?? row?.model ?? session.model,
                               effort: mine?.effort ?? row?.effort ?? session.effort.map(Effort.init(rawValue:)),
                               mode: mine?.mode ?? row?.mode, fast: mine?.fast ?? row?.fast)
    }

    func mode(of session: RemoteSession) -> PermissionMode? { settings(of: session).mode }

    /// The models a session can switch to: its own list from the Mac, else the options', with the one it runs first
    /// when neither has it.
    func models(for session: RemoteSession) -> [ModelOption] {
        var models = sessionModels[session.id] ?? models(for: session.agent)
        if let current = settings(of: session).model, !models.contains(where: { $0.id == current || $0.title == current }) {
            models.insert(ModelOption(id: current, title: ModelName.short(current), agent: session.agent), at: 0)
        }
        return models
    }

    func loadModels(for session: RemoteSession) async {
        guard session.abilities.contains(.settingsModel) || session.abilities.contains(.settingsEffort) else { return }
        guard isLive else { return }
        if let list = try? await client().models(session.agent, session: session.id) { sessionModels[session.id] = list.models }
    }

    /// Signed with the unlock key, or with the confirm key after Face ID when the change raises. A Mac that wants Face ID
    /// for a change the phone took as safe says so (`confirm_required`, level biometric), and Face ID signs it again.
    /// `title` names the change for the Face ID prompt.
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
        // The Mac's own reading where it has one ("claude-opus-5-5" for "opus"), so the row's catches up with it.
        let done = result.settings
        let mine = SessionSettings(model: change.model.map { done.model ?? $0 }, effort: change.effort.map { done.effort ?? $0 },
                                   mode: change.mode.map { done.mode ?? $0 }, fast: change.fast.map { done.fast ?? $0 })
        changed[session.id] = (changed[session.id] ?? SessionSettings()).merging(mine)
        return result
    }

    /// Compacts an idle session's context; the demo pretends.
    func compact(_ session: SessionKey) async throws {
        if isDemo { return }
        try await guarded(subject: ConfirmMessage.subject(action: .compact, target: session), reason: "Compact this session") { try await client().compact(session, confirm: $0) }
    }

    /// Starts a review of an idle Codex session's uncommitted changes; the demo pretends.
    func review(_ session: SessionKey) async throws {
        if isDemo { return }
        try await guarded(subject: ConfirmMessage.subject(action: .review, target: session, body: ReviewRequest()), reason: "Review this session's changes") {
            try await client().review(session, confirm: $0)
        }
    }

    /// What a turn changed. The demo gathers its transcript's diffs, as the Mac would for a Claude turn.
    func turnDiff(_ session: SessionKey, turn: String, demo messages: [TranscriptMessage]) async throws -> TurnDiff {
        if isDemo {
            var files = messages.flatMap(\.tools).flatMap(\.diffs)
            #if DEBUG
            // `--cut-diff`: each file as the Mac sends one over 2,000 lines.
            if ProcessInfo.processInfo.arguments.contains("--cut-diff") {
                files = files.map { FileDiff(path: $0.path, oldPath: $0.oldPath, change: $0.change, additions: $0.additions,
                                             deletions: $0.deletions, hunks: $0.hunks, truncated: true) }
            }
            #endif
            return TurnDiff(sessionID: session, turnID: turn, files: files, note: "Edits made with Claude's file tools; shell changes aren't shown.")
        }
        return try await client().turnDiff(session, turn: turn)
    }

    // MARK: Terminal

    /// A terminal view of a hosted session; the demo's shows a still screen.
    func terminal(_ name: String) async -> TerminalModel {
        guard let live else { return TerminalModel(name: name, session: nil) }
        let paired = live.paired
        // Each open is signed with the Face ID key, which the Mac requires for a terminal; one Face ID holds for 5 minutes.
        let confirm = needsKeys ? nil : DeviceKeys.terminal(macID: paired.endpoint.macID, deviceID: paired.deviceID)
        let session = TerminalSession(client: await live.engine.client, name: name, viewer: TerminalModel.viewer(for: name, mac: paired.endpoint.macID),
                                      outbox: live.outbox,
                                      confirm: confirm)
        return TerminalModel(name: name, session: session)
    }

    // MARK: Ports

    /// The key pinned at pairing, which the preview's WebView holds the Mac to as well.
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

    // MARK: The Mac

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

    /// Autopilot on or off, after Face ID either way: the confirm key signs it. The demo just flips it.
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

    /// Answering with the recommended choice after a minute, on or off, after Face ID like Autopilot. The demo just flips it.
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

    // MARK: Rotation

    func loadOutlook() async {
        guard isLive, can(.rotation), let latest = try? await client().outlook() else { return }
        if outlook != latest { outlook = latest }
    }

    /// The percentage at which Autopilot moves off an account, after Face ID. The demo just changes it.
    func setSwapAt(_ percent: Int) async throws {
        if isDemo { autopilot = autopilot?.changing(swapAt: percent); return }
        let confirm = try await faceID(.rotation, subject: ConfirmMessage.subject(swapAt: percent), reason: "Move at \(percent)%")
        autopilot = try await signed { try await client().setSwapAt(percent, confirm: confirm) }
    }

    /// Ranking accounts by Fable's room while Fable runs, after Face ID. The demo just changes it.
    func setFollowFable(_ enabled: Bool) async throws {
        if isDemo { autopilot = autopilot?.changing(followFable: enabled); return }
        let confirm = try await faceID(.rotation, subject: ConfirmMessage.subject(followFable: enabled),
                                       reason: enabled ? "Follow Fable" : "Stop following Fable")
        autopilot = try await signed { try await client().setFollowFable(enabled, confirm: confirm) }
    }

    /// First, Normal or Last, after Face ID; the engine applies the list the Mac answers.
    func setPriority(_ account: RemoteAccount, _ level: PriorityLevel) async throws {
        let engine = try connection().engine
        let confirm = try await faceID(.rotation, subject: ConfirmMessage.subject(account: account.id, priority: level),
                                       reason: "Use \(account.name) \(RotationText.priority(level).lowercased())")
        try await signed { try await engine.setPriority(account.id, level, confirm: confirm) }
    }

    /// Whether Autopilot may use an account, after Face ID; the engine applies the list the Mac answers.
    func setAuto(_ account: RemoteAccount, _ enabled: Bool) async throws {
        let engine = try connection().engine
        let confirm = try await faceID(.rotation, subject: ConfirmMessage.subject(account: account.id, auto: enabled),
                                       reason: enabled ? "Let Autopilot use \(account.name)" : "Keep Autopilot off \(account.name)")
        try await signed { try await engine.setAuto(account.id, enabled, confirm: confirm) }
    }

    // MARK: Accounts

    /// Makes an account its provider's login on the Mac, after Face ID; the engine applies the list the Mac answers.
    func useAccount(_ account: RemoteAccount) async throws {
        let engine = try connection().engine
        let confirm = try await faceID(.account, subject: ConfirmMessage.subject(useAccount: account.id), reason: "Use \(account.name)")
        try await signed { try await engine.useAccount(account.id, confirm: confirm) }
    }

    /// The confirm key's signature after Face ID; a cancel throws `ToolError.cancelled`.
    private func faceID(_ purpose: ConfirmPurpose, subject: String, reason: String) async throws -> String {
        let live = try connection()
        guard !needsKeys else { throw ToolError.pairAgain }
        guard let confirm = await live.sign(.confirm, purpose, subject, reason) else { throw ToolError.cancelled }
        return confirm
    }

    // MARK: History

    func history(archived: Bool, cursor: Cursor?) async throws -> HistoryPage { try await client().history(archived: archived, cursor: cursor) }
    func search(_ query: String, cursor: Cursor?) async throws -> SearchResults { try await client().search(query, cursor: cursor, limit: 30) }
    func change(_ conversation: String, _ change: HistoryChange) async throws -> PastSession {
        // The demo keeps a live session's pin and title here; it has no History to change.
        if isDemo {
            let updated = (past[conversation] ?? PastSession(id: conversation, agent: .claude, title: "", project: "")).applying(change)
            past[conversation] = updated
            return updated
        }
        let updated = try await client().change(conversation, change)
        past[conversation] = updated
        return updated
    }

    /// The title Side A shows: a rename from this phone wins until the Mac's own row carries it.
    func title(for session: RemoteSession) -> String {
        session.conversationID.flatMap { past[$0]?.customTitle } ?? session.title
    }

    func isPinned(_ session: RemoteSession) -> Bool { session.conversationID.flatMap { past[$0]?.pinned } ?? false }

    /// The first page of History, for which live sessions are pinned and renamed.
    func loadPast() async {
        guard !isDemo, can(.history), past.isEmpty, let page = try? await history(archived: false, cursor: nil) else { return }
        for row in page.sessions where row.isPinned || row.customTitle != nil { past[row.id] = row }
    }

    // MARK: Uploads

    func upload(_ data: Data, mime: String) async throws -> Upload {
        try await connection().engine.upload(data, mime: mime)
    }

    /// The Mac's own words when it sent some.
    static func message(_ error: Error) -> String {
        switch error {
        case let failure as RemoteFailure: failure.error.message
        case ToolError.demo: "The demo doesn't change anything."
        case ToolError.unavailable: "Side A can't open its storage on this iPhone. Reinstall it to make changes."
        case ToolError.badURL: "The Mac sent an address the phone can't open."
        case ToolError.cancelled: "Cancelled."
        case ToolError.locked: "Unlock your iPhone to do this."
        case ToolError.pairAgain: "Pair this iPhone again to do this from it."
        default: (error as NSError).localizedDescription
        }
    }
}

extension AutopilotState {
    /// The same state with those fields changed.
    func changing(enabled: Bool? = nil, answersRecommended: Bool? = nil, swapAt: Int? = nil, followFable: Bool? = nil) -> AutopilotState {
        AutopilotState(enabled: enabled ?? self.enabled, pending: pending, decisions: decisions,
                       answersRecommended: answersRecommended ?? self.answersRecommended, held: held, next: next, waiting: waiting,
                       swapAt: swapAt ?? self.swapAt, followFable: followFable ?? self.followFable, fableMode: fableMode)
    }
}

enum ToolError: Error {
    case demo, badURL
    /// No Mac to act on: not paired, or the outbox couldn't open (`MacTools.Mode.unavailable`).
    case unavailable
    /// Face ID was cancelled: nothing to report.
    case cancelled
    /// The unlock key wouldn't sign: the phone locked, or it has no keys for this Mac.
    case locked
    /// The Mac checks signatures, and this pairing has no keys it knows (`MacTools.needsKeys`).
    case pairAgain
}
