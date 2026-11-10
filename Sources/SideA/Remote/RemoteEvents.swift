import Foundation
import SideACore

/// Turns changes in the island, the live sessions and usage into state events. Records whenever Remote is active
/// (on, with a paired device), connected or not: replay and push both need what happened while the phone was away.
@MainActor
final class RemoteEvents: Island.Watcher {
    private weak var store: AccountStore?
    private let hub: EventHub
    private let queue: DispatchQueue
    private var sessions: [SessionKey: RemoteSession] = [:]
    /// Which key each process was last known by, so a new conversation id is a replacement, not a new session.
    private var keys: [String: SessionKey] = [:]
    private var accounts: [String: RemoteAccount] = [:]
    private var hosted: [String: HostedSession] = [:]
    private var hostedTask: Task<Void, Never>?
    private var hostedAgain = false
    private var usageTask: Task<Void, Never>?
    private var autopilot: AutopilotState?
    private var autopilotTask: Task<Void, Never>?
    private var mac: MacState?
    private var macTask: Task<Void, Never>?
    /// When each session was first seen working since its last finished turn, and when that turn finished: what's known
    /// of how long a turn ran. The Stop hook doesn't say when the turn began.
    private var working: [SessionKey: Date] = [:]
    private var lastFinished: [SessionKey: Date] = [:]
    private(set) var recording = false

    init(store: AccountStore, hub: EventHub, queue: DispatchQueue) {
        self.store = store; self.hub = hub; self.queue = queue
    }

    func start() {
        guard !recording, let store else { return }
        recording = true
        store.island.watcher = self
        sessions = Dictionary(current().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        keys = Dictionary(store.sessions.live.map { (Self.process($0), WireBuilders.key($0)) }, uniquingKeysWith: { a, _ in a })
        accounts = Dictionary(WireBuilders.accounts(store).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        hosted = Dictionary(hostedNow(store).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        hostedChanged()
        store.sessions.retainLive("remote")
        autopilot = Autopilot.state(store, log: Autopilot.tail(store.root.appendingPathComponent("runtime/autopilot.log")))
        mac = MacStats.state(store)
        macTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, let store = self.store else { return }
                self.macChanged(MacStats.state(store))
            }
        }
    }

    func stop() {
        guard recording else { return }
        recording = false
        if store?.island.watcher === self { store?.island.watcher = nil }
        store?.sessions.releaseLive("remote")
        usageTask?.cancel(); usageTask = nil
        macTask?.cancel(); macTask = nil
        autopilotTask?.cancel(); autopilotTask = nil
        hostedTask?.cancel(); hostedTask = nil
    }

    /// The full open list each time; an empty one clears the phone's.
    func incidentsChanged() {
        guard recording, let store else { return }
        record(.incidentUpdate(WireBuilders.incidents(store)))
    }

    /// Power, battery, memory and keep awake, read every 30 s and after the phone changes a setting.
    func macChanged(_ state: MacState) {
        guard recording, MacStats.changed(mac, state) else { return }
        mac = state
        record(.macUpdate(state))
    }

    /// Autopilot's state after anything that could change it, at most once a second and only when it did.
    func autopilotChanged() {
        guard recording, autopilotTask == nil else { return }
        autopilotTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let store = self.store else { return }
            let log = store.root.appendingPathComponent("runtime/autopilot.log")
            let text = await Task.detached { Autopilot.tail(log) }.value
            self.autopilotTask = nil
            guard self.recording else { return }
            let next = Autopilot.state(store, log: text)
            if next != self.autopilot {
                self.autopilot = next
                self.record(.autopilotUpdate(next))
            }
        }
    }

    private func record(_ event: ServerEvent) {
        guard recording else { return }
        let hub = hub, at = Date().timeIntervalSince1970
        queue.async { hub.record(event, at: at) }
    }

    // MARK: Island

    func requestAdded(_ item: Island.Pending) {
        let request = WireBuilders.request(item)
        record(.requestAdd(request))
        store?.remote.push.request(WireBuilders.fullRequest(item))
        liveChanged()
    }

    func requestResolved(_ item: Island.Pending, by: Island.Resolution, answer: IslandAnswer?) {
        let resolution = Island.resolution(item.id, by, answer, at: Date())
        record(.requestResolve(resolution))
        store?.remote.approvals.add(.init(resolution: resolution, request: WireBuilders.summary(item)))
        store?.remote.push.dismiss(item.id.uuidString.lowercased(), answeredBy: resolution.deviceID)
        liveChanged()
    }

    func readyChanged(from old: [Island.Ready], to new: [Island.Ready], reason: Island.ReadyReason) {
        guard let island = store?.island else { return }
        let before = Set(old.map(\.id))
        let after = Set(new.map(\.id))
        for row in new where !before.contains(row.id) {
            guard let finished = WireBuilders.finished(row, island: island) else { continue }
            record(.finishedAdd(finished))
            store?.remote.push.finished(finished, ran: ran(finished.sessionID, at: row.at))
        }
        for row in old where !after.contains(row.id) {
            if let session = row.finish.sessionID { record(.finishedResolve(sessionID: session, reason: reason.rawValue)) }
            store?.remote.push.finishedResolved(row.id.uuidString.lowercased())
        }
        liveChanged()
    }

    /// From when the session was first seen working, else from its last finished turn, which can only make it longer.
    /// Nil when neither is known.
    private func ran(_ session: SessionKey, at end: Date) -> TimeInterval? {
        let start = working.removeValue(forKey: session) ?? lastFinished[session]
        lastFinished[session] = end
        return start.map { end.timeIntervalSince($0) }
    }

    func queued(session: String, text: String, became outcome: Island.QueuedFollowUp) {
        switch outcome {
        case .waiting: break
        case .delivered: record(.finishedResolve(sessionID: session, reason: Island.ReadyReason.sentQueued.rawValue))
        case .dropped:
            record(.finishedResolve(sessionID: session, reason: ServerEvent.finishedQueueDropped))
            store?.remote.push.queuedDropped(session: session, title: store?.sessions.title(of: session), text: text)
        }
    }

    // MARK: Sessions

    private static func process(_ session: LiveSession) -> String { "\(session.pid)-\(Int(session.started ?? 0))" }

    func current() -> [RemoteSession] {
        guard let store else { return [] }
        let finished = Set(store.island.ready.compactMap(\.finish.sessionID))
        var seen = Set<SessionKey>()
        return store.sessions.live.map { WireBuilders.session($0, store: store, finished: finished) }.filter { seen.insert($0.id).inserted }
    }

    /// Memory and ports are left out of the comparison, so a refresh that only moves them sends nothing.
    func liveChanged() {
        guard recording, let store else { return }
        store.remote.codex.sync()
        store.remote.inbox.prune(store.sessions.live)
        let next = current()
        let nextKeys = Dictionary(store.sessions.live.map { (Self.process($0), WireBuilders.key($0)) }, uniquingKeysWith: { a, _ in a })
        var replaced: [SessionKey: SessionKey] = [:]
        for (process, key) in nextKeys { if let old = keys[process], old != key { replaced[old] = key } }
        let ids = Set(next.map(\.id))
        for old in sessions.keys where !ids.contains(old) { record(.sessionRemove(id: old, replacedBy: replaced[old])) }
        for session in next where sessions[session.id].map({ !Self.same($0, session) }) ?? true { record(.sessionUpsert(session)) }
        // A flag that starts; `start` took in the ones already up.
        for session in next {
            if let flag = session.flag, sessions[session.id].map({ $0.flag?.kind != flag.kind }) ?? true { store.remote.push.health(session, flag) }
            if session.status == .working, working[session.id] == nil {
                working[session.id] = session.statusAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
            }
        }
        let latest = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, session) in sessions where session.flag != nil && latest[id]?.flag == nil {
            store.remote.push.healthEnded(id)
        }
        working = working.filter { ids.contains($0.key) }
        lastFinished = lastFinished.filter { ids.contains($0.key) }
        sessions = latest
        keys = nextKeys
        store.remote.previews.prune(listening: RemotePreviews.listening(store))
        store.remote.push.activity(Self.activity(next, requests: store.island.pending.map { $0.id.uuidString.lowercased() }, accounts: WireBuilders.accounts(store)))
    }

    /// The Live Activity's numbers: counts, the next request's id, and the tightest window of the accounts in use.
    /// Takes request ids, not wire requests: building one records its gate as shown to a phone.
    static func activity(_ sessions: [RemoteSession], requests: [String], accounts: [RemoteAccount]) -> ActivityContentState {
        let windows = accounts.filter(\.active).flatMap { [$0.usage?.fiveHour, $0.usage?.weekly].compactMap { $0 } }
        let tightest = windows.max { $0.percent < $1.percent }
        return ActivityContentState(working: sessions.filter { $0.status == .working }.count, waiting: requests.count,
                                    topRequest: requests.first, soonestResetAt: tightest?.resetsAt,
                                    tightestPercent: tightest.map { min(max(Int($0.percent.rounded()), 0), 100) })
    }

    private static func same(_ a: RemoteSession, _ b: RemoteSession) -> Bool {
        var a = a, b = b
        a.memoryBytes = nil; b.memoryBytes = nil
        a.ports = nil; b.ports = nil
        return a == b
    }

    // MARK: Hosted

    /// After each tmux refresh: an upsert for a pane that's new or changed, a remove for one that's gone. One pass at
    /// a time; a refresh during one runs another after.
    func hostedChanged() {
        guard recording, let store else { return }
        guard hostedTask == nil else { hostedAgain = true; return }
        hostedTask = Task { [weak self] in
            let next = await RemoteRoutes.hostedSessions(store)
            guard let self, !Task.isCancelled else { return }
            self.hostedTask = nil
            let names = Set(next.map(\.name))
            for name in self.hosted.keys.sorted() where !names.contains(name) { self.record(.hostedRemove(name: name)) }
            for session in next where self.hosted[session.name] != session { self.record(.hostedUpsert(session)) }
            self.hosted = Dictionary(next.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            if self.hostedAgain {
                self.hostedAgain = false
                self.hostedChanged()
            }
        }
    }

    /// A hosted session needs someone at its screen: a reply that may not have gone in, a compaction that didn't show.
    func hostedAttention(_ name: String, _ attention: HostedSessions.Attention) {
        record(.hostedAttention(HostedAttention(name: name, kind: .init(rawValue: attention.kind), text: attention.text)))
    }

    /// The panes now, with the viewer counts last seen (counting them takes a tmux call).
    private func hostedNow(_ store: AccountStore) -> [HostedSession] {
        store.hosted.sessions.compactMap { RemoteRoutes.wire($0, hosted: store.hosted, store: store, viewers: hosted[$0.name]?.viewers ?? 0) }
    }

    // MARK: Usage

    /// At most one `usage.update` a second, with only the accounts that changed, and an `account.remove` for each
    /// account gone from the library.
    func usageChanged() {
        guard recording, usageTask == nil else { return }
        usageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let store = self.store else { return }
            self.usageTask = nil
            let next = WireBuilders.accounts(store)
            let changed = next.filter { self.accounts[$0.id] != $0 }
            for account in changed where account.active {
                for window in account.usage?.windows ?? [] {
                    let before = self.accounts[account.id]?.usage?.windows.first { $0.id == window.id }?.percent ?? 0
                    for threshold in [90, 100] where window.percent >= Double(threshold) && before < Double(threshold) {
                        store.remote.push.limit(account, window, threshold: threshold)
                    }
                }
            }
            let removed = Set(self.accounts.keys).subtracting(next.map(\.id)).sorted()
            self.accounts = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in removed { self.record(.accountRemove(id: id)) }
            if !changed.isEmpty { self.record(.usageUpdate(changed)) }
            if !changed.isEmpty || !removed.isEmpty { self.liveChanged() }
        }
    }

    // MARK: Snapshot

    /// Everything a phone needs to start over, gathered in one pass on the main actor.
    func snapshot() -> @Sendable (Int, String) -> StateSnapshot {
        guard let store else { return { seq, epoch in StateSnapshot(seq: seq, epoch: epoch) } }
        let island = store.island
        let sessions = current()
        let finished = island.ready.compactMap { WireBuilders.finished($0, island: island) }
        let requests = island.pending.map(WireBuilders.request)
        let accounts = WireBuilders.accounts(store)
        let mac = MacStats.state(store)
        let incidents = WireBuilders.incidents(store)
        let hosted = hostedNow(store)
        let autopilot = autopilot
        let dropped = island.droppedForPhones()
        return { seq, epoch in
            StateSnapshot(seq: seq, epoch: epoch, sessions: sessions, finished: finished, requests: requests, hosted: hosted, accounts: accounts,
                          mac: mac, incidents: incidents, autopilot: autopilot, droppedReplies: dropped.isEmpty ? nil : dropped)
        }
    }
}
