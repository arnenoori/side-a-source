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
        case attached
        case own
    }

    enum Failure: Error, Equatable {
        case notAttached, rpc(String), closed
        case unsupported
        case invalid(String)
        case busy
    }

    struct Interrupt: Equatable {
        let ids: Set<String>
        var follows: Follows

        enum Follows: Equatable {
            case nothing
            case reply
            case resend

            init(send: Bool, resend: Bool) { self = !send ? .nothing : resend ? .resend : .reply }
        }

        var holds: Bool { follows != .nothing }
    }

    struct Thread {
        var status: CodexAppServer.Thread.Status
        var turn: String?
        var sent: [String: (text: String, at: Date)] = [:]
        var queued: [String: (text: String, at: Date)] = [:]
        var interrupting: Interrupt?
        var carry: (entries: [(id: String, text: String)], at: Date)?
        var carryTimer: Task<Void, Never>?
        /// One it dropped: a steer still waiting when the turn was interrupted never reaches the model or the TUI.
        var unsent: (text: String, at: Date)?
        var settings: CodexAppServer.Settings? { didSet { if let settings, !settings.raised { base = settings } } }
        var base: CodexAppServer.Settings?
        var contextPercent: Int?
        var cost: Double?
        var lastTurn: String?
        var diffs: [(turn: String, diff: String)] = []
        var plan: TurnPlan?
    }

    @MainActor final class Link {
        let home: String
        var client: AppServerClient?
        var connecting = false
        var failures = 0
        var retry: Task<Void, Never>?
        var loaded: Set<String>?
        var threads: [String: Thread] = [:]
        var attaching: Set<String> = []
        var queues = true
        var settable = true
        var steers = true
        var costs = true
        var models: [CodexAppServer.Model]?
        var approvals: [String: (id: Island.Pending.ID, thread: String)] = [:]
        var changes: [String: (files: [String], diff: String)] = [:]
        init(home: String) { self.home = home }
    }

    static let enabledKey = "remoteCodexAppServer"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
    static let allowedHomes: Set<String>? = ProcessInfo.processInfo.environment["SIDEA_CODEX_HOMES"]
        .map { Set($0.split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }) }

    weak var store: AccountStore?
    private(set) var links: [String: Link] = [:]
    private(set) var running = false
    private var recheck: Task<Void, Never>?

    #if DEBUG
    struct Staged { var reach: Reach; var status: SessionStatus; var unsent: String? = nil }
    var staged: [String: Staged]?
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
        if let loaded = link.loaded, !loaded.contains(thread), !link.attaching.contains(thread) { return .own }
        if link.client == nil, !link.connecting, link.failures > 0 { return .own }
        return nil
    }

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

    func link(of live: LiveSession) -> (Link, AppServerClient, String)? {
        guard let thread = live.sessionID, let home = home(of: live), let link = links[home], let client = link.client,
              link.threads[thread] != nil else { return nil }
        return (link, client, thread)
    }

    func send(_ live: LiveSession, text typed: String, queue: Bool, key: String? = nil) async throws(Failure) -> ReplyResult.Delivery {
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
        // Interrupt and Send's reply can arrive before the turn it stopped has ended. Past the wait it goes alone and what
        // the stop was to carry goes back to the phone now, rather than waiting for a reply that has already come.
        for _ in 0..<Int(Self.carryWait * 10) where link.threads[thread]?.interrupting?.holds == true { try? await Task.sleep(for: .milliseconds(100)) }
        if let stop = link.threads[thread]?.interrupting, stop.holds {
            link.threads[thread]?.interrupting?.follows = .nothing
            for id in stop.ids where link.threads[thread]?.sent.removeValue(forKey: id) != nil {
                store?.remote.receipts.codex(client: id, .unsent, reason: ReplyReceipt.stopped(agent: .codex))
            }
            RemoteLog.shared("codex app server at \(link.home): the interrupted turn hadn't ended after \(Int(Self.carryWait)) s, sending alone")
        }
        let carried = link.threads[thread]?.carry?.entries ?? []
        if typed.isEmpty, carried.isEmpty { return .typed }
        link.threads[thread]?.carry = nil
        link.threads[thread]?.carryTimer?.cancel()
        let text = (carried.map(\.text) + [typed]).filter { !$0.isEmpty }.joined(separator: "\n")
        let working = link.threads[thread].map { if case .active = $0.status { true } else { false } } ?? false
        let id = UUID().uuidString.lowercased()
        let fields: [String: CodexAppServer.JSON] = ["threadId": .string(thread), "clientUserMessageId": .string(id), "input": CodexAppServer.input(text)]
        let params = CodexAppServer.JSON.object(fields)
        let receipts = store?.remote.receipts
        for entry in carried { receipts?.codex(client: entry.id, becomes: id) }
        func giveBack() { if !carried.isEmpty { receipts?.codex(client: id, .unsent, reason: ReplyReceipt.stopped(agent: .codex)) } }
        if queue, working, link.queues {
            receipts?.expect(key, text: text, asked: typed, live: live, client: id, delivery: .queued)
            // Before the call: the turn can end and Codex report it leaving the queue before the answer comes.
            link.threads[thread]?.queued[id] = (text, Date())
            do {
                _ = try await client.call("thread/queue/add", params)
                if link.threads[thread]?.queued[id] != nil || link.threads[thread]?.sent[id] != nil { receipts?.codex(client: id, .held) }
                return .queued
            } catch AppServerClient.Failure.rpc(let error) where error.unknownMethod {
                link.threads[thread]?.queued[id] = nil
                link.queues = false
                RemoteLog.shared("codex app server at \(link.home): no thread/queue/add, steering instead")
            } catch {
                link.threads[thread]?.queued[id] = nil
                receipts?.forget(key)
                giveBack()
                throw Self.failure(error)
            }
        }
        receipts?.expect(key, text: text, asked: typed, live: live, client: id, delivery: .typed)
        do {
            link.threads[thread]?.sent[id] = (text, Date())
            if !queue, working, link.steers, let turn = link.threads[thread]?.turn {
                do {
                    _ = try await client.call("turn/steer", .object(fields.merging(["expectedTurnId": .string(turn)]) { $1 }))
                    // Its answer means the running turn holds it, to read once the current step ends; unless its user
                    // item came first.
                    if link.threads[thread]?.sent[id] != nil { receipts?.codex(client: id, .held) }
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
            receipts?.forget(key)
            giveBack()
            throw Self.failure(error)
        }
    }

    private func sent(_ thread: String, _ link: Link) -> ReplyResult.Delivery {
        if link.threads[thread]?.unsent != nil {
            link.threads[thread]?.unsent = nil
            store?.remote.events?.liveChanged()
        }
        return .typed
    }

    func unsent(_ live: LiveSession) -> String? {
        #if DEBUG
        if let staged { return live.sessionID.flatMap { staged[$0]?.unsent } }
        #endif
        guard let thread = live.sessionID, let home = home(of: live), let unsent = links[home]?.threads[thread]?.unsent else { return nil }
        return unsent.text
    }

    private func lost(_ thread: String, _ link: Link, interrupted: Bool, stopped: Bool = false) {
        guard var state = link.threads[thread], !state.sent.isEmpty else { return }
        let idle = state.status == .idle
        let held = state.interrupting?.ids ?? []
        let late = state.sent.filter { !held.contains($0.key) && (interrupted || idle && Date().timeIntervalSince($0.value.at) > ReplyReceipts.unseen) }
        guard let last = late.values.max(by: { $0.at < $1.at }) else { return }
        for id in late.keys {
            state.sent[id] = nil
            store?.remote.receipts.codex(client: id, .unsent, reason: stopped ? ReplyReceipt.stopped(agent: .codex)
                : interrupted ? "The interrupt stopped Codex before it read it." : "Codex never took it into a turn.")
        }
        state.unsent = last
        link.threads[thread] = state
        RemoteLog.shared("codex app server at \(link.home): a message to \(thread) never reached the session")
        store?.remote.events?.liveChanged()
    }

    /// How long Interrupt and Send's reply waits for the stopped turn to end; the phone waits at least as long first.
    static let carryWait: Double = InterruptTiming.macWaits

    private func dequeued(_ thread: String, _ link: Link) {
        guard let client = link.client else { return }
        Task { [weak self] in
            var waiting = Set<String>()
            var cursor: CodexAppServer.JSON = .null
            var seen: Set<String> = []
            // A daemon that keeps handing out cursors would page for ever; with the list unfinished, nothing has left it.
            for _ in 0..<20 {
                guard let page = try? await client.call("thread/queue/list", .object(["threadId": .string(thread), "cursor": cursor])) else { return }
                waiting.formUnion(page["data"]?.array?.compactMap { $0["clientUserMessageId"]?.string } ?? [])
                cursor = page["nextCursor"] ?? .null
                if cursor == .null || !seen.insert(Self.key(cursor)).inserted { break }
            }
            guard cursor == .null else { return }
            guard self != nil, link.client === client, let queued = link.threads[thread]?.queued else { return }
            for (id, entry) in queued where !waiting.contains(id) {
                link.threads[thread]?.queued[id] = nil
                link.threads[thread]?.sent[id] = (entry.text, Date())
            }
        }
    }

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

    static func failure(_ error: Error) -> Failure {
        switch error as? AppServerClient.Failure {
        case .rpc(let rpc)?: .rpc(rpc.message)
        default: .closed
        }
    }

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
        reset(link)
    }

    private func reset(_ link: Link) {
        link.threads = [:]
        link.attaching = []
        link.loaded = nil
        link.models = nil
        link.costs = true
        for approval in link.approvals.values { store?.island.withdraw(approval.id, by: .gone) }
        link.approvals = [:]
    }

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
            reset(link)
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
            link.changes = [:]
            let interrupted = params["turn"]?["status"]?.string == "interrupted"
            let stop = link.threads[thread]?.interrupting
            if interrupted, let stop, stop.holds { hold(thread, link, stop) }
            link.threads[thread]?.interrupting = nil
            lost(thread, link, interrupted: interrupted, stopped: interrupted && stop != nil)
            readCost(thread, link)
        case "thread/tokenUsage/updated":
            guard let thread, link.threads[thread] != nil, let percent = params["tokenUsage"].flatMap(CodexAppServer.contextPercent),
                  link.threads[thread]?.contextPercent != percent else { return }
            link.threads[thread]?.contextPercent = percent
            store?.remote.events?.liveChanged()
        case "account/rateLimits/updated":
            guard let store, let windows = params["rateLimits"].map(CodexAppServer.windows), !windows.isEmpty,
                  let account = store.sessions.live.first(where: { $0.sessionID.map { link.threads[$0] != nil } == true })
                    .flatMap({ store.sessions.accountID(of: $0, agent: .codex) }) else { return }
            store.takeLive(windows, for: account, at: Date().timeIntervalSince1970)
        case "thread/started":
            guard let started = params["thread"]?["id"]?.string, wanted()[link.home]?.contains(started) == true,
                  link.threads[started] == nil, !link.attaching.contains(started) else { return }
            link.loaded?.insert(started)
            attach([started], link)
        case "item/started", "item/completed":
            guard let item = params["item"] else { return }
            if let id = item["id"]?.string, let changes = CodexAppServer.changes(item) { link.changes[id] = changes }
            if method == "item/completed", item["type"]?.string == "userMessage", let thread, let state = link.threads[thread] {
                // A queued one may lose its clientId on the way out of the queue; its text still names it. An id that is
                // another's (typed in the TUI, or another client's) is that message, whatever its words.
                let pending = state.sent.merging(state.queued) { $1 }
                let named = item["clientId"]?.string
                guard let id = named.map({ pending[$0] != nil ? $0 : nil })
                        ?? pending.sorted(by: { $0.value.at < $1.value.at }).first(where: { CodexInputEvidence.matches(item, $0.value.text) })?.key else { return }
                link.threads[thread]?.sent[id] = nil
                link.threads[thread]?.queued[id] = nil
                store?.remote.receipts.codex(client: id, .read)
            }
        case "thread/queue/changed":
            guard let thread, link.threads[thread]?.queued.isEmpty == false else { return }
            dequeued(thread, link)
        case "thread/settings/updated":
            guard let thread, link.threads[thread] != nil, let settings = params["threadSettings"].flatMap(CodexAppServer.Settings.init(updated:)),
                  link.threads[thread]?.settings != settings else { return }
            link.threads[thread]?.settings = settings
            store?.remote.events?.liveChanged()
        case "serverRequest/resolved":
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
