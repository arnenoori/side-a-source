import Foundation
import SideACore
import SideAProtocol

/// Codex sessions the user started in a terminal, reached through the app-server daemon their TUI runs on: one
/// connection per `CODEX_HOME` that has such a session, subscribed (`thread/resume`) to exactly those sessions'
/// threads. It mirrors their status, carries replies, steers, queued messages and interrupts, and puts the daemon's
/// approvals on the island. A TUI the daemon doesn't have (`--no-daemon`, `--oss`, `--profile`, `-c` overrides) stays
/// hooks only. Runs while Remote records.
@MainActor
final class CodexTerminals {
    enum Reach: Equatable {
        /// Its thread is subscribed on a live connection.
        case attached
        /// The daemon for its home is up and doesn't have its thread, or there is no daemon: the TUI runs embedded.
        case own
    }

    enum Failure: Error, Equatable {
        case notAttached, rpc(String), closed
        /// The daemon has no `thread/settings/update` (older, or the experimental API off).
        case unsupported
        /// A model or effort the daemon's own list doesn't offer, in words for the phone.
        case invalid(String)
        /// Only while it's idle.
        case busy
    }

    struct Thread {
        var status: CodexAppServer.Thread.Status
        var turn: String?
        /// Turns that ended since attaching.
        var ended = 0
        /// Messages sent with turn/start that Codex hasn't shown as the user's yet, by clientUserMessageId.
        var sent: [String: (text: String, at: Date)] = [:]
        /// One it dropped: a steer still waiting when the turn was interrupted never reaches the model or the TUI.
        var unsent: (text: String, at: Date)?
        /// Model, effort and mode for its next turns, kept in step with the TUI's own changes.
        var settings: CodexAppServer.Settings? { didSet { if let settings, !settings.raised { base = settings } } }
        /// The last settings seen without a raise: what lowering back to default restores.
        var base: CodexAppServer.Settings?
        /// How full the context window is, as the TUI's footer shows it, from the last request.
        var contextPercent: Int?
        /// Estimated US dollars so far, read after each turn when the account's billing route has it.
        var cost: Double?
        /// The newest turn seen, running or not, and the diffs of the last few turns by id.
        var lastTurn: String?
        var diffs: [(turn: String, diff: String)] = []
        /// The newest turn's plan.
        var plan: TurnPlan?
    }

    /// One daemon, by `CODEX_HOME`.
    @MainActor final class Link {
        let home: String
        var client: AppServerClient?
        var connecting = false
        var failures = 0
        var retry: Task<Void, Never>?
        /// Threads the daemon has loaded, as of the last look; one Side A wants and doesn't find there is `.own`.
        var loaded: Set<String>?
        var threads: [String: Thread] = [:]
        var attaching: Set<String> = []
        /// False once the daemon said it doesn't know `thread/queue/add` (older, or experimental API off).
        var queues = true
        /// False once it said it doesn't know `thread/settings/update`.
        var settable = true
        /// False once it said it doesn't know `turn/steer`; turn/start steers too, without the check.
        var steers = true
        /// False once `account/usage/read` failed (no sign-in, or none for this account).
        var costs = true
        /// The daemon's models for its account, read once per connection.
        var models: [CodexAppServer.Model]?
        /// The island's request for each of the daemon's approval requests, by the request's JSON id.
        var approvals: [String: (id: Island.Pending.ID, thread: String)] = [:]
        /// Files and diff of each file change item seen, so its approval can show them.
        var changes: [String: (files: [String], diff: String)] = [:]
        init(home: String) { self.home = home }
    }

    static let enabledKey = "remoteCodexAppServer"
    /// Off until turned on (`defaults write … remoteCodexAppServer -bool true`), while it waits for its first check
    /// against a real daemon. `SIDEA_CODEX_HOMES` (colon separated) limits the homes it may reach.
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
    static let allowedHomes: Set<String>? = ProcessInfo.processInfo.environment["SIDEA_CODEX_HOMES"]
        .map { Set($0.split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }) }

    private weak var store: AccountStore?
    private(set) var links: [String: Link] = [:]
    private(set) var running = false
    private var recheck: Task<Void, Never>?

    #if DEBUG
    /// The harness's two-way rows, by session id: answered here as an app server would, with no daemon behind them.
    struct Staged { var reach: Reach; var status: SessionStatus; var unsent: String? = nil }
    var staged: [String: Staged]?
    /// Hello's reply.terminal, on for staged rows whatever the setting.
    var offered: Bool { Self.enabled || staged != nil }
    #else
    var offered: Bool { Self.enabled }
    #endif
    private let version: String

    init(store: AccountStore?) {
        self.store = store
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func start() {
        guard !running, Self.enabled, store?.isDemo == false else { return }
        running = true
        sync()
        // A TUI joins its daemon after Side A looked (it started later, or the daemon restarted under it) without the
        // daemon saying so to other clients; looking again every few seconds finds it.
        recheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.running else { return }
                let wanted = self.wanted()
                for (home, link) in self.links where link.client != nil {
                    let missing = (wanted[home] ?? []).subtracting(link.threads.keys).subtracting(link.attaching)
                    if !missing.isEmpty { self.attach(missing, link) }
                    for thread in link.threads.keys { self.lost(thread, link, interrupted: false) }
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        recheck?.cancel(); recheck = nil
        for link in links.values { drop(link) }
        links = [:]
    }

    // MARK: Which sessions

    /// The sessions this can reach, by home: Codex, not hosted (a hosted pane is typed into), with a thread id.
    private func wanted() -> [String: Set<String>] {
        guard let store else { return [:] }
        var out: [String: Set<String>] = [:]
        for live in store.sessions.live where live.provider == .codex && live.hosted == nil {
            guard let thread = live.sessionID, let home = home(of: live) else { continue }
            if let allowed = Self.allowedHomes, !allowed.contains(home) { continue }
            out[home, default: []].insert(thread)
        }
        return out
    }

    func home(of live: LiveSession) -> String? {
        guard let store else { return nil }
        let path: String? = switch store.sessions.codexHome(of: live) {
        case .mac?: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        case .profile(let id)?: store.root.appendingPathComponent("profiles/\(id)").path
        case .other(let value)?: value
        case nil: nil
        }
        return path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    /// Called when the live list changes: connects to homes that gained a session, attaches new threads, and lets go
    /// of threads and homes with none left.
    func sync() {
        guard running else { return }
        let wanted = wanted()
        for (home, link) in links where wanted[home] == nil {
            drop(link)
            links[home] = nil
        }
        for (home, threads) in wanted {
            let link = links[home] ?? Link(home: home)
            links[home] = link
            if link.client == nil {
                connect(link)
                continue
            }
            for gone in Set(link.threads.keys).subtracting(threads) {
                link.threads[gone] = nil
                Task { [client = link.client] in _ = try? await client?.call("thread/unsubscribe", .object(["threadId": .string(gone)])) }
            }
            let missing = threads.subtracting(link.threads.keys).subtracting(link.attaching)
            if !missing.isEmpty { attach(missing, link) }
        }
    }

    func reach(_ live: LiveSession) -> Reach? {
        #if DEBUG
        if let staged { return live.sessionID.flatMap { staged[$0]?.reach } }
        #endif
        guard running, live.provider == .codex, live.hosted == nil, let thread = live.sessionID, let home = home(of: live),
              let link = links[home] else { return nil }
        if link.threads[thread] != nil, link.client != nil { return .attached }
        // Known not to be there: the daemon answered without it, or there is none to ask.
        if let loaded = link.loaded, !loaded.contains(thread), !link.attaching.contains(thread) { return .own }
        if link.client == nil, !link.connecting, link.failures > 0 { return .own }
        return nil
    }

    /// The daemon's own word on an attached session, which beats a rollout tail's guess.
    func status(_ live: LiveSession) -> SessionStatus? {
        #if DEBUG
        if let staged { return live.sessionID.flatMap { staged[$0] }.flatMap { $0.reach == .attached ? $0.status : nil } }
        #endif
        guard reach(live) == .attached, let thread = live.sessionID, let home = home(of: live),
              let state = links[home]?.threads[thread] else { return nil }
        switch state.status {
        case .active(let approval, let input): return approval || input ? .waiting : .working
        case .idle: return .idle
        case .notLoaded, .systemError: return nil
        }
    }

    private func link(of live: LiveSession) -> (Link, AppServerClient, String)? {
        guard let thread = live.sessionID, let home = home(of: live), let link = links[home], let client = link.client,
              link.threads[thread] != nil else { return nil }
        return (link, client, thread)
    }

    // MARK: Talking

    /// Sends a message to the session's thread. Mid-turn, `queue` waits for the turn to end (`thread/queue/add`);
    /// otherwise it steers. Idle, either one starts a turn. Both show in the TUI as the user's message.
    func send(_ live: LiveSession, text: String, queue: Bool) async throws(Failure) -> ReplyResult.Delivery {
        #if DEBUG
        if staged != nil {
            guard let id = live.sessionID, var row = staged?[id], row.reach == .attached else { throw .notAttached }
            defer { staged?[id] = row; store?.remote.events?.liveChanged() }
            row.unsent = nil
            if queue, row.status == .working { return .queued }
            row.status = .working
            return .typed
        }
        #endif
        guard let (link, client, thread) = link(of: live) else { throw .notAttached }
        let working = link.threads[thread].map { if case .active = $0.status { true } else { false } } ?? false
        let id = UUID().uuidString.lowercased()
        let fields: [String: CodexAppServer.JSON] = ["threadId": .string(thread), "clientUserMessageId": .string(id), "input": CodexAppServer.input(text)]
        let params = CodexAppServer.JSON.object(fields)
        if queue, working, link.queues {
            do {
                _ = try await client.call("thread/queue/add", params)
                return .queued
            } catch AppServerClient.Failure.rpc(let error) where error.unknownMethod {
                // An older daemon: steer instead, which the TUI shows the same way.
                link.queues = false
                RemoteLog.shared("codex app server at \(link.home): no thread/queue/add, steering instead")
            } catch {
                throw Self.failure(error)
            }
        }
        do {
            link.threads[thread]?.sent[id] = (text, Date())
            if !queue, working, link.steers, let turn = link.threads[thread]?.turn {
                // Steer only the turn that's running: one that ended meanwhile gets a turn of its own instead.
                do {
                    _ = try await client.call("turn/steer", .object(fields.merging(["expectedTurnId": .string(turn)]) { $1 }))
                    return sent(thread, link)
                } catch AppServerClient.Failure.rpc(let error) where error.unknownMethod {
                    link.steers = false
                    RemoteLog.shared("codex app server at \(link.home): no turn/steer, steering with turn/start")
                } catch AppServerClient.Failure.rpc(let error) where error.code == -32600 && error.message.contains("active turn") {
                    RemoteLog.shared("codex app server at \(link.home): the turn ended before a steer, starting one")
                }
            }
            _ = try await client.call("turn/start", params)
            return sent(thread, link)
        } catch {
            link.threads[thread]?.sent[id] = nil
            throw Self.failure(error)
        }
    }

    /// One went through: the flag of an earlier one that didn't goes.
    private func sent(_ thread: String, _ link: Link) -> ReplyResult.Delivery {
        if link.threads[thread]?.unsent != nil {
            link.threads[thread]?.unsent = nil
            store?.remote.events?.liveChanged()
        }
        return .typed
    }

    /// A message Codex dropped, for the session's flag until the next one goes through.
    func unsent(_ live: LiveSession) -> String? {
        #if DEBUG
        if let staged { return live.sessionID.flatMap { staged[$0]?.unsent } }
        #endif
        guard let thread = live.sessionID, let home = home(of: live), let unsent = links[home]?.threads[thread]?.unsent else { return nil }
        return unsent.text
    }

    /// Sends Codex never showed: dropped by an interrupt at once, otherwise once the thread has been idle a while.
    private func lost(_ thread: String, _ link: Link, interrupted: Bool) {
        guard var state = link.threads[thread], !state.sent.isEmpty else { return }
        let idle = state.status == .idle
        let late = state.sent.filter { interrupted || idle && Date().timeIntervalSince($0.value.at) > 30 }
        guard let last = late.values.max(by: { $0.at < $1.at }) else { return }
        for id in late.keys { state.sent[id] = nil }
        state.unsent = last
        link.threads[thread] = state
        RemoteLog.shared("codex app server at \(link.home): a message to \(thread) never reached the session")
        store?.remote.events?.liveChanged()
    }

    func interrupt(_ live: LiveSession) async throws(Failure) {
        #if DEBUG
        if staged != nil {
            guard let id = live.sessionID, var row = staged?[id], row.reach == .attached else { throw .notAttached }
            guard row.status == .working else { throw .rpc("No turn is running.") }
            row.status = .idle
            staged?[id] = row
            store?.remote.events?.liveChanged()
            return
        }
        #endif
        guard let (link, client, thread) = link(of: live) else { throw .notAttached }
        var turn = link.threads[thread]?.turn
        if turn == nil {
            // Attached mid-turn: the newest turn is the running one.
            let page = try? await client.call("thread/turns/list", .object(["threadId": .string(thread), "limit": .number(1)]))
            turn = page?["data"]?.array?.first.flatMap { $0["status"]?.string == "inProgress" ? $0["id"]?.string : nil }
        }
        guard let turn else { throw .rpc("No turn is running.") }
        do {
            _ = try await client.call("turn/interrupt", .object(["threadId": .string(thread), "turnId": .string(turn)]))
        } catch {
            throw Self.failure(error)
        }
    }

    /// What an attached session's row adds: its settings and what can change them, context and cost.
    struct Row {
        var settings: SessionSettings?
        var abilities: Set<SessionAbility> = []
        var reasons: [String: String] = [:]
        var contextPercent: Double?
        var cost: Double?
        var turnID: String?
        var plan: TurnPlan?
    }

    func row(_ live: LiveSession) -> Row? {
        guard let (link, _, thread) = link(of: live), let state = link.threads[thread] else { return nil }
        var row = Row(contextPercent: state.contextPercent.map(Double.init), cost: state.cost, turnID: state.turn ?? state.lastTurn, plan: state.plan)
        if let turn = row.turnID, state.diffs.contains(where: { $0.turn == turn }) { row.abilities.insert(.turnDiff) }
        if state.status == .idle { row.abilities.formUnion([.compact, .review]) }
        if let settings = state.settings {
            row.settings = SessionSettings(model: settings.model, effort: settings.effort.map(Effort.init(rawValue:)),
                                           mode: PermissionMode(rawValue: settings.shown))
            if link.settable {
                row.abilities.formUnion([.settingsModel, .settingsEffort, .settingsMode])
            } else {
                let reason = "This version of Codex can't change settings from Side A."
                row.reasons = Dictionary(uniqueKeysWithValues: [SessionAbility.settingsModel, .settingsEffort, .settingsMode].map { ($0.rawValue, reason) })
            }
        }
        return row
    }

    /// What a turn changed, as its diff last stood, and whether it's still running.
    func diff(_ live: LiveSession, turn: String) -> (files: [FileDiff], running: Bool)? {
        guard let (link, _, thread) = link(of: live), let state = link.threads[thread],
              let diff = state.diffs.last(where: { $0.turn == turn })?.diff else { return nil }
        return (CodexAppServer.fileDiffs(diff), state.turn == turn)
    }

    /// Compacts the conversation, or reviews the uncommitted changes, as `/compact` and `/review` would in the TUI.
    /// Idle only: the TUI refuses both during a task.
    func compact(_ live: LiveSession) async throws(Failure) { try await idle(live, "thread/compact/start") { _ in [:] } }

    func review(_ live: LiveSession) async throws(Failure) {
        try await idle(live, "review/start") { _ in ["target": .object(["type": .string("uncommittedChanges")]), "delivery": .string("inline")] }
    }

    private func idle(_ live: LiveSession, _ method: String, _ extra: (String) -> [String: CodexAppServer.JSON]) async throws(Failure) {
        guard let (link, client, thread) = link(of: live) else { throw .notAttached }
        guard link.threads[thread]?.status == .idle else { throw .busy }
        do {
            _ = try await client.call(method, .object(extra(thread).merging(["threadId": .string(thread)]) { $1 }))
        } catch AppServerClient.Failure.rpc(let error) where error.unknownMethod {
            throw .unsupported
        } catch {
            throw Self.failure(error)
        }
    }

    /// Context and cost for the session's row.
    func usage(_ live: LiveSession) -> (contextPercent: Int?, cost: Double?) {
        guard let (link, _, thread) = link(of: live), let state = link.threads[thread] else { return (nil, nil) }
        return (state.contextPercent, state.cost)
    }

    /// The thread's estimated cost. A daemon signed in to no account, or one whose billing route has none, has none;
    /// after the first no, the connection stops asking.
    private func readCost(_ thread: String, _ link: Link) {
        guard link.costs, let client = link.client else { return }
        Task { [weak self] in
            do {
                let usage = try await client.call("account/usage/read", .object(["threadId": .string(thread)]))
                guard let self, link.client === client, let cost = CodexAppServer.cost(usage), link.threads[thread]?.cost != cost else { return }
                link.threads[thread]?.cost = cost
                self.store?.remote.events?.liveChanged()
            } catch {
                link.costs = false
            }
        }
    }

    // MARK: Settings

    /// The model, effort and mode the session's next turns run with, while they can be changed from here.
    func settings(_ live: LiveSession) -> CodexAppServer.Settings? {
        guard let (link, _, thread) = link(of: live), link.settable else { return nil }
        return link.threads[thread]?.settings
    }

    /// The models the session's daemon offers, read once per connection.
    func models(_ live: LiveSession) async throws(Failure) -> [CodexAppServer.Model] {
        guard let (link, client, _) = link(of: live) else { throw .notAttached }
        if let models = link.models { return models }
        var models: [CodexAppServer.Model] = []
        var cursor: CodexAppServer.JSON = .null
        do {
            repeat {
                let page = try await client.call("model/list", .object(["cursor": cursor]))
                models += page["data"]?.array?.compactMap(CodexAppServer.Model.init) ?? []
                cursor = page["nextCursor"] ?? .null
            } while cursor != .null
        } catch {
            throw Self.failure(error)
        }
        if link.client === client { link.models = models }
        return models
    }

    /// Changes what the session's next turns run with; the TUI's footer follows. A model without the effort the
    /// session has takes the model's default, as the TUI's own picker does.
    func change(_ live: LiveSession, model: String? = nil, effort: String? = nil, mode: String? = nil) async throws(Failure) {
        guard let (link, client, thread) = link(of: live) else { throw .notAttached }
        guard link.settable else { throw .unsupported }
        guard let current = link.threads[thread]?.settings else { throw .notAttached }
        let raises = [CodexAppServer.Settings.neverMode, CodexAppServer.Settings.fullAccessMode]
        if let mode, !CodexAppServer.modes.contains(mode), !raises.contains(mode) { throw .invalid("Codex has no \(mode) mode.") }
        var effort = effort
        if model != nil || effort != nil {
            let models = try await models(live)
            let name = model ?? current.model
            // A model the account doesn't list (a custom provider's) takes any effort the user picks.
            if let chosen = models.first(where: { $0.id == name }) {
                if let wanted = effort, !chosen.efforts.contains(wanted) { throw .invalid("\(chosen.name) has no \(wanted) effort.") }
                if effort == nil, let had = current.effort, !chosen.efforts.contains(had) { effort = chosen.defaultEffort }
            } else if model != nil {
                throw .invalid("This Codex account doesn't offer \(name).")
            }
        }
        // A raise sets the approval or sandbox policy; default lowers one back to what the session ran with before it.
        var updates: [CodexAppServer.JSON] = []
        if let mode, raises.contains(mode) {
            updates.append(current.raise(thread: thread, to: mode))
            if model != nil || effort != nil { updates.append(current.update(thread: thread, model: model, effort: effort, mode: nil)) }
        } else {
            if mode == "default", current.raised {
                guard let base = link.threads[thread]?.base else {
                    throw .invalid("Side A doesn't know what this session ran with before full access. Change it in the terminal.")
                }
                updates.append(CodexAppServer.Settings.lower(thread: thread, to: base))
            }
            if model != nil || effort != nil || mode != nil {
                updates.append(current.update(thread: thread, model: model, effort: effort, mode: mode))
            }
        }
        do {
            for update in updates { _ = try await client.call("thread/settings/update", update) }
        } catch AppServerClient.Failure.rpc(let error) where error.unknownMethod {
            link.settable = false
            RemoteLog.shared("codex app server at \(link.home): no thread/settings/update")
            store?.remote.events?.liveChanged()
            throw .unsupported
        } catch {
            throw Self.failure(error)
        }
    }

    private static func failure(_ error: Error) -> Failure {
        switch error as? AppServerClient.Failure {
        case .rpc(let rpc)?: .rpc(rpc.message)
        default: .closed
        }
    }

    // MARK: Connection

    private func connect(_ link: Link) {
        guard !link.connecting, link.retry == nil else { return }
        link.connecting = true
        let socket = CodexAppServer.socket(home: link.home)
        let client = AppServerClient(socket: socket) { [weak self, weak link] event in
            // In arrival order: a hop per event through the main queue keeps turn/started before turn/completed.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let link else { return }
                    self.handle(event, link)
                }
            }
        }
        Task { [weak self, version] in
            do {
                try await client.connect(version: version)
                guard let self, self.running, self.links[link.home] === link else { client.close(); return }
                link.connecting = false
                link.failures = 0
                link.client = client
                RemoteLog.shared("codex app server at \(link.home): connected")
                self.attach(self.wanted()[link.home] ?? [], link)
            } catch {
                guard let self else { return }
                link.connecting = false
                link.failures += 1
                if link.failures == 1 { RemoteLog.shared("codex app server at \(link.home): \(error.localizedDescription)") }
                self.store?.remote.events?.liveChanged()
                self.again(link)
            }
        }
    }

    /// Daemon restarts and a TUI that starts the daemon later: try again, backing off to 30 s.
    private func again(_ link: Link) {
        guard running, links[link.home] === link, link.retry == nil else { return }
        let delay = min(30, Double(1 << min(max(link.failures - 1, 0), 5)))
        link.retry = Task { [weak self, weak link] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let link, !Task.isCancelled else { return }
            link.retry = nil
            if self.links[link.home] === link { self.connect(link) }
        }
    }

    private func drop(_ link: Link) {
        link.retry?.cancel(); link.retry = nil
        link.client?.close(); link.client = nil
        link.threads = [:]
        link.attaching = []
        link.loaded = nil
        link.models = nil
        link.costs = true
        for approval in link.approvals.values { store?.island.withdraw(approval.id, by: .gone) }
        link.approvals = [:]
    }

    /// Subscribes to the threads the daemon has loaded; the rest are TUIs that don't run on it.
    private func attach(_ threads: Set<String>, _ link: Link) {
        guard let client = link.client, !threads.isEmpty else { return }
        link.attaching.formUnion(threads)
        Task { [weak self] in
            var loaded = Set<String>()
            var cursor: CodexAppServer.JSON = .null
            repeat {
                guard let page = try? await client.call("thread/loaded/list", .object(["cursor": cursor])) else { break }
                loaded.formUnion(page["data"]?.array?.compactMap(\.string) ?? [])
                cursor = page["nextCursor"] ?? .null
            } while cursor != .null
            guard let self, link.client === client else { return }
            link.loaded = loaded
            for thread in threads {
                guard loaded.contains(thread) else { link.attaching.remove(thread); continue }
                do {
                    let result = try await client.call("thread/resume", .object(["threadId": .string(thread), "excludeTurns": .bool(true)]))
                    let status = CodexAppServer.Thread.status(result["thread"]?["status"])
                    if link.client === client, self.wanted()[link.home]?.contains(thread) == true {
                        var state = Thread(status: status, turn: nil)
                        state.settings = CodexAppServer.Settings(resumed: result)
                        link.threads[thread] = state
                        self.readCost(thread, link)
                    }
                } catch {
                    RemoteLog.shared("codex app server at \(link.home): couldn't attach a thread: \(error.localizedDescription)")
                }
                link.attaching.remove(thread)
            }
            self.store?.remote.events?.liveChanged()
        }
    }

    private func handle(_ event: AppServerClient.Event, _ link: Link) {
        guard running, links[link.home] === link else { return }
        switch event {
        case .closed:
            guard link.client != nil || link.connecting else { return }
            RemoteLog.shared("codex app server at \(link.home): closed")
            link.client = nil
            link.threads = [:]
            link.attaching = []
            link.loaded = nil
            link.models = nil
            link.costs = true
            for approval in link.approvals.values { store?.island.withdraw(approval.id, by: .gone) }
            link.approvals = [:]
            store?.remote.events?.liveChanged()
            link.failures += 1
            again(link)
        case .notification(let method, let params):
            notification(method, params, link)
        case .request(let id, let method, let params):
            request(id, method, params, link)
        }
    }

    private func notification(_ method: String, _ params: CodexAppServer.JSON, _ link: Link) {
        let thread = params["threadId"]?.string
        switch method {
        case "thread/status/changed":
            guard let thread, link.threads[thread] != nil else { return }
            link.threads[thread]?.status = CodexAppServer.Thread.status(params["status"])
            store?.remote.events?.liveChanged()
        case "turn/started":
            guard let thread, link.threads[thread] != nil else { return }
            link.threads[thread]?.turn = params["turn"]?["id"]?.string
            link.threads[thread]?.lastTurn = params["turn"]?["id"]?.string
            link.threads[thread]?.plan = nil
            store?.remote.events?.liveChanged()
        case "turn/diff/updated":
            guard let thread, link.threads[thread] != nil, let turn = params["turnId"]?.string, let diff = params["diff"]?.string else { return }
            var diffs = link.threads[thread]?.diffs.filter { $0.turn != turn } ?? []
            diffs.append((turn, diff))
            link.threads[thread]?.diffs = Array(diffs.suffix(5))
            if link.threads[thread]?.lastTurn != turn { link.threads[thread]?.lastTurn = turn; store?.remote.events?.liveChanged() }
        case "turn/plan/updated":
            guard let thread, link.threads[thread] != nil, let plan = CodexAppServer.plan(params), link.threads[thread]?.plan != plan else { return }
            link.threads[thread]?.plan = plan
            link.threads[thread]?.lastTurn = params["turnId"]?.string ?? link.threads[thread]?.lastTurn
            store?.remote.events?.liveChanged()
        case "turn/completed":
            guard let thread, link.threads[thread] != nil else { return }
            link.threads[thread]?.turn = nil
            link.threads[thread]?.ended += 1
            link.changes = [:]
            lost(thread, link, interrupted: params["turn"]?["status"]?.string == "interrupted")
            readCost(thread, link)
        case "thread/tokenUsage/updated":
            guard let thread, link.threads[thread] != nil, let percent = params["tokenUsage"].flatMap(CodexAppServer.contextPercent),
                  link.threads[thread]?.contextPercent != percent else { return }
            link.threads[thread]?.contextPercent = percent
            store?.remote.events?.liveChanged()
        case "account/rateLimits/updated":
            // The account the daemon runs on: any of its sessions says which.
            guard let store, let windows = params["rateLimits"].map(CodexAppServer.windows), !windows.isEmpty,
                  let account = store.sessions.live.first(where: { $0.sessionID.map { link.threads[$0] != nil } == true })
                    .flatMap({ store.sessions.accountID(of: $0, agent: .codex) }) else { return }
            store.takeLive(windows, for: account, at: Date().timeIntervalSince1970)
        case "thread/started":
            // A TUI that started after the last look: attach if Side A already lists it.
            guard let started = params["thread"]?["id"]?.string, wanted()[link.home]?.contains(started) == true,
                  link.threads[started] == nil, !link.attaching.contains(started) else { return }
            link.loaded?.insert(started)
            attach([started], link)
        case "item/started", "item/completed":
            guard let item = params["item"] else { return }
            if let id = item["id"]?.string, let changes = CodexAppServer.changes(item) { link.changes[id] = changes }
            if method == "item/completed", item["type"]?.string == "userMessage", let thread, let id = item["clientId"]?.string {
                link.threads[thread]?.sent[id] = nil
            }
        case "thread/settings/updated":
            // Changed from here, from the TUI, or by another client: the next turns run with these.
            guard let thread, link.threads[thread] != nil, let settings = params["threadSettings"].flatMap(CodexAppServer.Settings.init(updated:)),
                  link.threads[thread]?.settings != settings else { return }
            link.threads[thread]?.settings = settings
            store?.remote.events?.liveChanged()
        case "serverRequest/resolved":
            // Answered in the terminal (or by another client): the island lets it go.
            guard let id = params["requestId"], let approval = link.approvals.removeValue(forKey: Self.key(id)) else { return }
            store?.island.withdraw(approval.id, by: .terminal)
        default: break
        }
    }

    private func request(_ id: CodexAppServer.JSON, _ method: String, _ params: CodexAppServer.JSON, _ link: Link) {
        // Requests the island can't show stay with the terminal, which was asked too.
        guard let store, let approval = CodexAppServer.Approval(id: id, method: method, params: params),
              link.threads[approval.threadID] != nil else { return }
        let changes = approval.itemID.flatMap { link.changes[$0] }
        let account = store.sessions.live.first { $0.sessionID == approval.threadID }
            .flatMap { store.sessions.accountID(of: $0, agent: .codex) }
            .flatMap { id in store.config.accounts.first { $0.id == id }?.name }
        let key = Self.key(id)
        let pending = store.island.add(approval.request(files: changes?.files ?? [], diff: changes?.diff ?? ""), account: account) { [weak link] answer in
            // Handed back, the terminal keeps asking; anything else goes to the daemon, which tells the TUI.
            guard let link, link.approvals.removeValue(forKey: key) != nil, let decision = CodexAppServer.Approval.decision(answer) else { return }
            link.client?.respond(id, decision)
        }
        link.approvals[key] = (pending, approval.threadID)
    }

    private static func key(_ id: CodexAppServer.JSON) -> String {
        String(decoding: (try? JSONEncoder().encode(id)) ?? Data(), as: UTF8.self)
    }
}
