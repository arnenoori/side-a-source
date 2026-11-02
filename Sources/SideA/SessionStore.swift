import AppKit
import SideACore
import SwiftUI

@MainActor @Observable
final class SessionStore {
    let store: AccountStore
    var query = ""
    var agent: String?
    var project: String?
    var days: Double?
    var includeAutomated = false
    var filtered: Bool { agent != nil || project != nil || days != nil || includeAutomated || showArchived }
    var results: [SessionInfo] = [] { didSet { regroup() } }
    var pinnedSessions: [SessionInfo] = []
    private(set) var pins: [String] = UserDefaults.standard.stringArray(forKey: "pinnedSessions") ?? [] {
        didSet {
            UserDefaults.standard.set(pins, forKey: "pinnedSessions")
            regroup()
        }
    }
    private(set) var groups: [ProjectGroup] = []
    var projects: [String] = []
    var live: [LiveSession] = [] {
        didSet {
            readIdentities()
            store.island.liveSessions(Set(live.compactMap(\.sessionID)))
            store.remote.events?.liveChanged()
            liveByID = Dictionary(live.compactMap { session in
                session.status == "idle" ? nil : session.sessionID.map { ($0, session) }
            }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            waiting = live.filter { $0.status == "waiting" && $0.sessionID != nil }
                .sorted { ($0.since ?? 0) > ($1.since ?? 0) }
                .filter { seen.insert($0.sessionID!).inserted }
            var seenRunning = Set<String>()
            running = live.filter { $0.status != "waiting" }
                .filter { $0.sessionID.map { seenRunning.insert($0).inserted } ?? false }
                .sorted { ($0.started ?? 0, $0.pid) > ($1.started ?? 0, $1.pid) }
            if let app = Self.terminal(of: live, host: TerminalFocus.host(of:)) { usualTerminal = app }
            regroup()
        }
    }
    private(set) var waiting: [LiveSession] = []

    /// The terminal app the first live session runs in. Each pid is asked once: a lazy compactMap asks twice, and a
    /// process that exits in between answers nil the second time, which traps.
    static func terminal(of live: [LiveSession], host: (Int) -> TerminalFocus.Host?) -> TerminalApp? {
        for session in live {
            guard let found = host(session.pid) else { continue }
            if let app = TerminalApp.allCases.first(where: { $0.bundleID == found.bundleID }) { return app }
        }
        return nil
    }
    /// What each process's environment says about its login, read once per process: a pid reused later starts at another time.
    @ObservationIgnored private var identities: [Int: (started: Double?, slot: String?, codexHome: ProcessEnvironment.CodexHome?)] = [:]
    /// Sessions that finished and wait for their next task, newest first; the island's Ready list.
    var finished: [Island.Ready] {
        let busy = Set((waiting + running.filter { $0.status == "busy" }).compactMap(\.sessionID))
        return store.island.ready.filter { $0.finish.sessionID.map { !busy.contains($0) } ?? false }
    }
    var liveMemory: Int { live.compactMap(\.memory).reduce(0, +) }
    var stale: [LiveSession] { running.filter(\.stale) }
    var quittingStale = false
    var quitting: LiveSession?

    /// Claude Code saves on SIGTERM, so a quit session resumes later with `claude --resume`; a hosted one ends with its
    /// tmux session. The phone's own Quit, checked again against a fresh list first.
    func quit(_ session: LiveSession) {
        guard !store.isDemo else { return }
        command { commands throws(SessionCommands.Failure) in try await commands.quit(WireBuilders.key(session)) }
    }

    /// Quit Idle: those idle half an hour or more, each checked again before it goes.
    func quitStale() {
        guard !store.isDemo else { return }
        let count = stale.count
        command { commands throws(SessionCommands.Failure) in
            let skipped = count - (try await commands.quitIdle(olderThanMinutes: 30)).count
            if skipped > 0 { self.error = skipped == 1 ? "That session changed since the list was shown, so it was left running." : "\(skipped) sessions changed since the list was shown, so they were left running." }
        }
    }

    /// SIGTERM to each session that a fresh list still shows as the same process passing `still`. Returns the ones
    /// signalled, or nil when the list couldn't be read.
    func terminate(_ sessions: [LiveSession], still: (LiveSession) -> Bool) async -> [LiveSession]? {
        guard let fresh = await freshLive() else { return nil }
        var ended: [LiveSession] = []
        for session in sessions {
            guard let now = fresh.first(where: { $0.pid == session.pid && $0.sessionID == session.sessionID && $0.started == session.started }),
                  still(now), ProcessCheck.maySignal(pid: now.pid, started: now.started) else { continue }
            kill(pid_t(now.pid), SIGTERM)
            ended.append(now)
        }
        return ended
    }
    var stoppingServer: LiveSession.Port?

    func stopServer(_ port: LiveSession.Port) {
        guard !store.isDemo, let owner = live.first(where: { $0.ports?.contains(port) == true }) else { return }
        command { commands throws(SessionCommands.Failure) in try await commands.stopServer(WireBuilders.key(owner), port: port.port) }
    }

    /// SIGTERM to a server a session started, when a fresh list still shows that same process listening there;
    /// never the session's own process.
    func endServer(_ port: LiveSession.Port) async -> Bool {
        guard let owner = live.first(where: { $0.ports?.contains(port) == true }), let fresh = await freshLive(),
              let session = fresh.first(where: { $0.pid == owner.pid && $0.started == owner.started }),
              let now = session.ports?.first(where: { $0.pid == port.pid && $0.port == port.port && $0.started == port.started }),
              ProcessCheck.maySignal(pid: now.pid, started: now.started), now.pid != session.pid else { return false }
        kill(pid_t(now.pid), SIGTERM)
        return true
    }

    private struct Live: Decodable, Sendable { let sessions: [LiveSession] }
    func freshLive() async -> [LiveSession]? {
        // The demo's list is set by hand, so it is its own truth.
        if store.isDemo { return live }
        return try? await bridge?.request(["live"], as: Live.self).sessions
    }
    /// Every running session, newest started first. Status and memory change every refresh,
    /// so ordering by them moved rows out from under the pointer.
    private(set) var running: [LiveSession] = []

    /// The live sections as the list shows them; working and idle are split so idle ones can fold away.
    struct Listed {
        var waiting: [LiveSession] = []
        var finished: [Island.Ready] = []
        var working: [LiveSession] = []
        var idle: [LiveSession] = []
        fileprivate var shape: [[String]] {
            [waiting.map { "\($0.pid)" }, finished.map(\.id.uuidString), working.map { "\($0.pid)" }, idle.map { "\($0.pid)" }]
        }
    }
    struct RunningGroup: Identifiable {
        let project: String
        let sessions: [LiveSession]
        var id: String { project }
    }
    /// While the pointer is over the list, rows keep their sections and places so nothing moves under
    /// a click. They still update in place, and a session that ends still leaves.
    var holding = false {
        didSet {
            guard holding != oldValue else { return }
            if holding { held = current } else { withAnimation(Ink.ease) { held = nil } }
        }
    }
    private var held: Listed?
    var idleOpen = UserDefaults.standard.bool(forKey: "runningIdleOpen") {
        didSet { UserDefaults.standard.set(idleOpen, forKey: "runningIdleOpen") }
    }

    private var current: Listed {
        let finished = self.finished
        let done = Set(finished.compactMap(\.finish.sessionID))
        let rest = running.filter { !done.contains($0.sessionID ?? "") }
        return Listed(waiting: waiting, finished: finished, working: rest.filter { $0.status == "busy" }, idle: rest.filter { $0.status != "busy" })
    }

    var listed: Listed {
        guard let held else { return current }
        let fresh = Dictionary(live.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let keep = { (rows: [LiveSession]) in rows.compactMap { row in fresh[row.pid].flatMap { $0.started == row.started ? $0 : nil } } }
        let alive = Set(live.compactMap(\.sessionID))
        return Listed(waiting: keep(held.waiting), finished: held.finished.filter { $0.finish.sessionID.map(alive.contains) ?? false },
                      working: keep(held.working), idle: keep(held.idle))
    }

    /// True while the held list hides a change, so the list can offer to show it.
    var heldBehind: Bool { held != nil && listed.shape != current.shape }

    func showHeld() { withAnimation(Ink.ease) { held = current } }

    /// Running sessions by project, alphabetically, newest first within each.
    func byProject(_ sessions: [LiveSession]) -> [RunningGroup] {
        Dictionary(grouping: sessions) { project(of: $0.cwd) }
            .map { RunningGroup(project: $0.key, sessions: $0.value) }
            .sorted { $0.project.localizedStandardCompare($1.project) == .orderedAscending }
    }

    @ObservationIgnored private var projectNames: [String: String] = [:]
    func project(of cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "No folder" }
        if let name = projectNames[cwd] { return name }
        let link = try? String(contentsOf: URL(fileURLWithPath: cwd).appendingPathComponent(".git"), encoding: .utf8)
        let name = Self.projectName(cwd: cwd, gitLink: link)
        projectNames[cwd] = name
        return name
    }

    /// A worktree's .git file points into its main checkout (<main>/.git/worktrees/<name>),
    /// so lanes sit with the project they branch from.
    nonisolated static func projectName(cwd: String, gitLink: String?) -> String {
        if let link = gitLink?.trimmingCharacters(in: .whitespacesAndNewlines), link.hasPrefix("gitdir: "),
           let range = link.range(of: "/.git/worktrees/") {
            let main = link[link.index(link.startIndex, offsetBy: 8)..<range.lowerBound]
            if !main.isEmpty { return URL(fileURLWithPath: String(main)).lastPathComponent }
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
    /// Notes and stops waiting for a session's next tool call, by pid.
    private(set) var mail: [Int: String] = [:] {
        didSet { if mail != oldValue { store.remote.events?.liveChanged() } }
    }
    /// When each pid's mail was left, for the phone's "Note waiting" line.
    private(set) var mailAt: [Int: Double] = [:]
    var noting: LiveSession?
    /// The composer's text for each conversation, kept while another one is open.
    var drafts: [String: String] = [:]
    /// What became of the last thing the composer sent, by conversation.
    var outcomes: [String: ComposerOutcome] = [:]
    /// Photos waiting to go with the next reply, by conversation: stored as the phone's uploads are.
    var attachments: [String: [Upload]] = [:]
    /// Each agent's commands and skills, for the composer's suggestions; read again at most every half minute.
    var commands: (claude: [AgentOptions.Option], codex: [AgentOptions.Option]) = ([], [])
    /// Where running sessions live, so Resume opens in the terminal you already use.
    private(set) var usualTerminal = TerminalApp.firstInstalled
    private(set) var liveByID: [String: LiveSession] = [:]
    var detail: SessionDetail?
    var selectedID: String?
    var focus: String?
    var remaining = 0
    var total = 0
    var loading = false
    var error: String?
    var listError: String?
    /// "Needs you" and "Pinned" step aside while filters narrow the list.
    var showsSections: Bool { !filtered && !searching }
    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var finding = false
    var focusSearch = 0
    var showArchived = false
    var renaming: SessionInfo?
    /// Names and archiving are Side A's own; Claude Code's and Codex's files are never written.
    private(set) var names: [String: String] = UserDefaults.standard.dictionary(forKey: "sessionNames") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(names, forKey: "sessionNames") }
    }
    private(set) var archived = Set(UserDefaults.standard.stringArray(forKey: "archivedSessions") ?? []) {
        didSet { UserDefaults.standard.set(Array(archived), forKey: "archivedSessions") }
    }

    @ObservationIgnored private var bridge: SessionBridge?
    // Conversations get their own process, so parsing a long transcript never delays a keystroke's search.
    @ObservationIgnored private var reader: SessionBridge?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var changed: Set<String> = []
    @ObservationIgnored private var registryChanged = false
    @ObservationIgnored private var cache: [String: SessionDetail] = [:]
    @ObservationIgnored private var recency: [String] = []
    @ObservationIgnored private var inflight: [String: (limit: Int, task: Task<SessionDetail, Error>)] = [:]
    @ObservationIgnored private var generation: [String: Int] = [:]
    @ObservationIgnored private var pages: [String: SessionDetail] = [:]
    @ObservationIgnored private var liveLoaded = false
    @ObservationIgnored private var fullHistory: Set<String> = []
    @ObservationIgnored private var warmed = false
    @ObservationIgnored private var shutdown: Task<Void, Never>?
    @ObservationIgnored private var painted = false
    private var snapshotURL: URL { store.root.appendingPathComponent("runtime/sessions-snapshot.json") }

    init(store: AccountStore) { self.store = store }

    func warm() {
        guard !store.isDemo else { return }
        shutdown?.cancel()
        if bridge == nil, let python = store.python, let url = store.bridgeURL {
            bridge = SessionBridge(python: python, bridge: url, root: store.root)
            reader = SessionBridge(python: python, bridge: url, root: store.root)
        }
        Task { [bridge, reader] in try? await bridge?.warm(); try? await reader?.warm() }
        paintSnapshot()
    }

    /// The last list, read from disk, so the first paint never waits for Python to start.
    private func paintSnapshot() {
        guard !painted, results.isEmpty else { return }
        painted = true
        struct Listing: Decodable { let sessions: [SessionInfo]; let projects: [String]?; let pinned: [SessionInfo]? }
        guard let data = try? Data(contentsOf: snapshotURL), let listing = try? SessionBridge.decode(data, as: Listing.self) else { return }
        results = listing.sessions.map(localized).filter { !archived.contains($0.id) }
        projects = listing.projects ?? []
        pinnedSessions = (listing.pinned ?? []).map(localized).filter { pins.contains($0.id) }
    }

    func appear() { retainLive("window") }

    func disappear() { releaseLive("window") }

    /// Who needs the live list kept fresh: the Sessions window, and Remote while a phone is paired. The loop runs from
    /// the first owner to the last.
    @ObservationIgnored private(set) var liveOwners: Set<String> = []

    func retainLive(_ owner: String) {
        liveOwners.insert(owner)
        if store.isDemo, live.isEmpty { live = Self.demoLive }
        guard loop == nil, !store.isDemo else { return }
        shutdown?.cancel()
        warm()
        let home = FileManager.default.homeDirectoryForCurrentUser
        watcher = FolderWatcher(folders: [".claude/projects", ".claude/sessions", ".codex/sessions"].map { home.appendingPathComponent($0) }) { [weak self] paths in
            self?.filesChanged(paths)
        }
        loop = Task { [weak self] in
            // The list first; the live registry and the index wait behind it on the same process.
            await self?.refresh()
            var lastIndex = Date.distantPast
            while !Task.isCancelled, let self {
                await self.refreshLive()
                if self.remaining != 0 || Date().timeIntervalSince(lastIndex) > 300 {
                    lastIndex = Date()
                    await self.index()
                }
                try? await Task.sleep(for: .seconds(self.remaining != 0 ? 1 : 20))
            }
        }
    }

    /// The processes outlive the last owner for a while, so a quick reopen doesn't start Python again.
    func releaseLive(_ owner: String) {
        liveOwners.remove(owner)
        guard liveOwners.isEmpty else { return }
        loop?.cancel(); loop = nil
        watcher = nil
        shutdown?.cancel()
        shutdown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, let self, self.loop == nil else { return }
            await self.bridge?.stop()
            await self.reader?.stop()
        }
    }

    private func filesChanged(_ paths: [String]) {
        for path in paths {
            if path.hasSuffix(".jsonl") { changed.insert(path) } else if path.contains("/.claude/sessions/") { registryChanged = true }
        }
        scheduleChanges(after: .milliseconds(300))
    }

    private func scheduleChanges(after delay: Duration) {
        guard !changed.isEmpty || registryChanged, changeTask == nil else { return }
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.applyChanges()
        }
    }

    private func applyChanges() async {
        let paths = changed
        let registry = registryChanged
        changed = []
        registryChanged = false
        var retry = false
        defer {
            changeTask = nil
            // Changes that arrived meanwhile, or paths the locked index skipped, get their own pass.
            scheduleChanges(after: retry ? .seconds(1) : .milliseconds(300))
        }
        if registry || (!paths.isEmpty && !running.isEmpty) { await refreshLive() }
        guard !paths.isEmpty else { return }
        if await index(paths: Array(paths)) == -1 {
            changed.formUnion(paths)
            retry = true
            return
        }
        for id in Set(cache.keys).union(inflight.keys) where paths.contains(where: { $0.contains(id) }) { invalidate(id) }
        // Reordering results under the pointer while someone browses a search would be worse than a stale score.
        if !searching { await refresh() }
        // Someone reading a page further back keeps it; "Jump to latest" brings the update.
        if let id = selectedID, paths.contains(where: { $0.contains(id) }), (detail?.later ?? 0) == 0,
           let value = try? await load(id), selectedID == id, (detail?.later ?? 0) == 0 {
            detail = value
        }
    }

    private func invalidate(_ id: String) {
        cache[id] = nil
        for key in pages.keys where key.hasPrefix(id + " ") { pages[key] = nil }
        generation[id, default: 0] += 1
    }

    /// Catching up on the whole history runs at background priority, so a first index never makes the Mac feel busy;
    /// a file that just changed is someone waiting to see it.
    @discardableResult
    private func index(paths: [String]? = nil) async -> Int {
        struct Progress: Decodable { let remaining: Int; let indexed: Int; let sessions: Int }
        let args = ["sessions", "index", "--seconds", "8"] + (paths ?? []).flatMap { ["--path", $0] }
        guard let data = try? await store.bridgeOutput(args, timeout: 60, priority: paths == nil ? .background : .userInitiated),
              let progress = try? JSONDecoder().decode(Progress.self, from: data) else { return 0 }
        // -1: another indexer holds the lock; the caller tries again.
        if paths == nil { remaining = progress.remaining }
        if progress.sessions > 0 { total = progress.sessions }
        if progress.indexed > 0 { listGeneration += 1 }
        if progress.indexed > 0 && paths == nil { await refresh() }
        return progress.remaining
    }

    private var indexFiles: [URL] {
        ["sessions.db", "sessions.db-wal", "sessions.db-shm", "sessions-snapshot.json"].map { store.root.appendingPathComponent("runtime/" + $0) }
    }

    var indexBytes: Int64 {
        indexFiles.reduce(0) { total, url in total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0) }
    }

    func deleteIndex() async {
        await bridge?.stop()
        await reader?.stop()
        for url in indexFiles { try? FileManager.default.removeItem(at: url) }
        listGeneration += 1
    }

    /// Starts the index over from the transcripts; names, pins and archiving live in Side A's settings and stay.
    func rebuildIndex() async {
        await deleteIndex()
        cache = [:]; pages = [:]; recency = []; fullHistory = []
        results = []; pinnedSessions = []; detail = nil; selectedID = nil
        painted = false; warmed = false
        // -1 means the menu's background pass holds the index lock; it finishes within seconds.
        while case let left = await index(), left != 0 {
            if left < 0 { try? await Task.sleep(for: .seconds(1)) }
        }
        await refresh()
    }

    private var filterArguments: [String] {
        (agent.map { ["--agent", $0] } ?? []) + (project.map { ["--project", $0] } ?? []) + (days.map { ["--days", String($0)] } ?? []) + (includeAutomated ? ["--automated"] : [])
    }

    func queryChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func refresh() async {
        struct Listing: Decodable, Sendable { let sessions: [SessionInfo]; let projects: [String]?; let pinned: [SessionInfo]? }
        guard let bridge else {
            listError = "Install Python 3 to search your conversations."
            return
        }
        let text = query.trimmingCharacters(in: .whitespaces)
        let only = showArchived ? (archived.isEmpty ? ["--only-none"] : archived.flatMap { ["--only", $0] }) : []
        let args = text.isEmpty ? ["recent"] + filterArguments + only + pins.flatMap { ["--pin", $0] } : ["search"] + filterArguments + ["--", text]
        let listing: Listing
        do {
            let data = try await bridge.data(args)
            listing = try SessionBridge.decode(data, as: Listing.self)
            listError = nil
            if text.isEmpty && !filtered {
                let url = snapshotURL
                Task.detached(priority: .background) { try? data.write(to: url, options: .atomic) }
            }
        } catch {
            if text == query.trimmingCharacters(in: .whitespaces) { listError = error.localizedDescription }
            return
        }
        guard text == query.trimmingCharacters(in: .whitespaces) else { return }
        var sessions = listing.sessions.map(localized).filter { archived.contains($0.id) == showArchived }
        let renamed = names.filter { $0.value.localizedStandardContains(text) && !sessions.map(\.id).contains($0.key) }.map(\.key)
        if !text.isEmpty, !renamed.isEmpty,
           let extra = try? await bridge.request(["recent"] + filterArguments + renamed.flatMap { ["--only", $0] }, as: Listing.self) {
            sessions = extra.sessions.map(localized).filter { archived.contains($0.id) == showArchived } + sessions
        }
        guard text == query.trimmingCharacters(in: .whitespaces) else { return }
        if sessions != results { withAnimation(Ink.ease) { results = sessions } } else { regroup() }
        if let found = listing.projects { projects = found }
        let pinned = showArchived ? [] : (listing.pinned?.map(localized) ?? pinnedSessions)
        if pinned != pinnedSessions { withAnimation(Ink.ease) { pinnedSessions = pinned } }
        if !warmed && !searching {
            warmed = true
            for id in waiting.compactMap(\.sessionID).prefix(2) + results.prefix(1).map(\.id) { prefetch(id) }
        }
    }

    func isPinned(_ id: String) -> Bool { pins.contains(id) }

    func title(of id: String) -> String? {
        if let name = names[id] { return name }
        return (results + pinnedSessions).first { $0.id == id }?.title ?? (detail?.session.id == id ? detail?.session.title : nil)
    }
    func isArchived(_ id: String) -> Bool { archived.contains(id) }

    func localized(_ session: SessionInfo) -> SessionInfo {
        guard let name = names[session.id] else { return session }
        var copy = session
        copy.title = name
        return copy
    }

    func rename(_ session: SessionInfo, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[session.id] = trimmed.isEmpty ? nil : trimmed
        cache[session.id] = nil
        if detail?.session.id == session.id { detail?.session.title = trimmed.isEmpty ? nil : trimmed }
        Task {
            await renameLive(session.id, trimmed)
            await refresh()
            if detail?.session.id == session.id, let value = try? await load(session.id) { detail = value }
        }
    }

    func toggleArchive(_ id: String) {
        Sounds.play(.tick)
        if archived.contains(id) {
            archived.remove(id)
        } else {
            archived.insert(id)
            pins.removeAll { $0 == id }
            pinnedSessions.removeAll { $0.id == id }
        }
        withAnimation(Ink.ease) { results.removeAll { $0.id == id } }
        Task { await refresh() }
    }

    /// The phone's changes to the same pins, names and archive, without the window's sounds and animation.
    /// Archiving unpins, and pinning brings a conversation back from the archive.
    func setPinned(_ id: String, _ pinned: Bool) {
        if pinned {
            archived.remove(id)
            if !pins.contains(id) { pins.insert(id, at: 0) }
        } else {
            pins.removeAll { $0 == id }
            pinnedSessions.removeAll { $0.id == id }
        }
        Task { await refresh() }
    }

    func setTitle(_ id: String, _ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        names[id] = trimmed.isEmpty ? nil : trimmed
        cache[id] = nil
        Task {
            await renameLive(id, trimmed)
            await refresh()
        }
    }

    /// A running Claude takes the title through its own inbox, so its terminal, /resume and its transcript say it too.
    /// Codex, a closed conversation or a Claude without an inbox keeps Side A's name alone; clearing one stays here.
    private func renameLive(_ id: String, _ title: String) async {
        guard !title.isEmpty, let bridge else { return }
        _ = try? await bridge.data(["rename", "--name=\(title)", "--", id], timeout: .seconds(5))
    }

    func setArchived(_ id: String, _ value: Bool) {
        if value {
            archived.insert(id)
            pins.removeAll { $0 == id }
            pinnedSessions.removeAll { $0.id == id }
        } else {
            archived.remove(id)
        }
        results.removeAll { $0.id == id }
        Task { await refresh() }
    }

    /// Each conversation shows once: waiting on you, else running, else pinned, else under its project.
    private func regroup() {
        let shown = showsSections ? Set(pins).union((waiting + running).compactMap(\.sessionID)) : []
        groups = Self.group(results.filter { !shown.contains($0.id) })
    }

    var visiblePins: [SessionInfo] {
        let waitingIDs = Set((waiting + running).compactMap(\.sessionID))
        return pinnedSessions.filter { !waitingIDs.contains($0.id) }
    }

    func togglePin(_ id: String) {
        Sounds.play(.tick)
        withAnimation(Ink.ease) {
            if let index = pins.firstIndex(of: id) {
                pins.remove(at: index)
                pinnedSessions.removeAll { $0.id == id }
            } else {
                pins.insert(id, at: 0)
                if let session = results.first(where: { $0.id == id }) ?? (detail?.session.id == id ? detail?.session : nil) {
                    pinnedSessions.insert(session, at: 0)
                }
            }
        }
        Task { await refresh() }
    }

    func refreshLive() async {
        guard let value = try? await bridge?.request(["live"], as: Live.self) else { return }
        guard value.sessions != live else { return }
        let waiting = Set(live.filter { $0.status == "waiting" }.map(\.pid))
        if liveLoaded, value.sessions.contains(where: { $0.status == "waiting" && !waiting.contains($0.pid) }) { Sounds.play(.nudge) }
        liveLoaded = true
        withAnimation(Ink.ease) { live = value.sessions }
        pruneMail()
    }

    private static let demoLive = [
        LiveSession(pid: 90001, sessionID: "demo-1", name: nil, title: "Polish the island transitions", cost: 2.4, cwd: "/Users/demo/side-a",
                    status: "busy", waitingFor: nil, since: Date().timeIntervalSince1970, activity: "Editing IslandView.swift", context: 64_000,
                    ports: [.init(port: 3000, pid: 90011, command: "node"), .init(port: 5173, pid: 90012, command: "node"), .init(port: 9229, pid: 90011, command: "node")]),
        LiveSession(pid: 90002, sessionID: "demo-2", name: nil, title: "Fix the flaky upload test", cost: 0.9, cwd: "/Users/demo/api",
                    status: "busy", waitingFor: nil, since: Date().timeIntervalSince1970, activity: "Running pytest -k upload", context: 41_000,
                    flag: .init(kind: "loop", text: "Repeated the same step 3 times")),
        LiveSession(pid: 90003, sessionID: "demo-3", name: nil, title: "Migrate the billing tables", cost: 7.1, cwd: "/Users/demo/billing",
                    status: "idle", waitingFor: nil, since: Date().timeIntervalSince1970, context: 182_000,
                    flag: .init(kind: "bloated", text: "Context is 182k tokens")),
        LiveSession(pid: 90004, sessionID: "demo-4", name: nil, title: "Add the export endpoint", cost: nil, cwd: "/Users/demo/api",
                    status: "busy", waitingFor: nil, since: Date().timeIntervalSince1970, activity: "Running npm test", agent: "codex"),
        LiveSession(pid: 90005, sessionID: "demo-5", name: nil, title: "Review the onboarding copy", cost: nil, cwd: "/Users/demo/web",
                    status: "unknown", waitingFor: nil, since: Date().timeIntervalSince1970, agent: "codex"),
    ]

    private var mailFolder: URL { store.root.appendingPathComponent("runtime/mail") }

    /// Where a session's mail goes. Claude's hooks look for their session's pid; Codex runs a turn's hooks in the
    /// process that runs the turn (the TUI, or the app server every TUI on it shares), so its mail goes by thread id.
    private func mailFile(_ session: LiveSession) -> URL? {
        switch session.provider {
        case .claude: return mailFolder.appendingPathComponent("\(session.pid).json")
        case .codex:
            guard let thread = session.sessionID, !thread.isEmpty, thread.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
            return mailFolder.appendingPathComponent("codex/\(thread).json")
        }
    }

    /// The account a session runs on, looked up now: a trade changes a slot's owner without changing the environment.
    /// nil when its environment couldn't be read, rather than a guess.
    func accountID(of session: LiveSession, agent: AgentProvider = .claude) -> String? {
        guard let identity = identities[session.pid], identity.started == session.started else { return nil }
        switch agent {
        case .claude: return identity.slot.flatMap(store.accountID(inSlot:))
        case .codex: return identity.codexHome.flatMap(store.accountID(codexHome:))
        }
    }

    /// The `CODEX_HOME` a Codex session runs with, as its environment said; nil when that couldn't be read.
    func codexHome(of session: LiveSession) -> ProcessEnvironment.CodexHome? {
        guard let identity = identities[session.pid], identity.started == session.started else { return nil }
        return identity.codexHome
    }

    private func readIdentities() {
        guard !store.isDemo else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var next: [Int: (started: Double?, slot: String?, codexHome: ProcessEnvironment.CodexHome?)] = [:]
        for session in live {
            if let known = identities[session.pid], known.started == session.started { next[session.pid] = known; continue }
            let env = ProcessEnvironment.read(pid: pid_t(session.pid))
            next[session.pid] = (session.started, env.map(ProcessEnvironment.claudeSlot),
                                 env.map { ProcessEnvironment.codexHome($0, root: store.root.path, home: home) })
        }
        identities = next
    }

    /// The phone's own commands, from the Sessions window: a tick once it went, or the words saying why it didn't.
    func command(_ body: @escaping @MainActor (SessionCommands) async throws(SessionCommands.Failure) -> Void) {
        let commands = SessionCommands(store: store)
        Task {
            do throws(SessionCommands.Failure) {
                try await body(commands)
                Sounds.play(.tick)
            } catch { self.error = error.macMessage }
        }
    }

    /// Claude Code's mail hooks hand a note over after the session's next tool call.
    func note(_ text: String, to session: LiveSession) {
        command { commands throws(SessionCommands.Failure) in _ = try await commands.reply(WireBuilders.key(session), .init(text: text, mode: .note)) }
    }

    /// Now: Esc in a hosted pane, or Codex's own interrupt. Before its next step: stop mail, which Claude's hooks read.
    func stop(_ session: LiveSession, now: Bool) {
        command { commands throws(SessionCommands.Failure) in _ = try await commands.interrupt(WireBuilders.key(session), when: now ? .now : .nextStep) }
    }

    /// Review Changes: the agent reviews the uncommitted changes, by the phone's own command.
    func review(_ session: LiveSession) {
        command { commands throws(SessionCommands.Failure) in try await commands.review(WireBuilders.key(session), ReviewRequest()) }
    }

    /// Compact: the session compacts its context, by the phone's own command.
    func compact(_ session: LiveSession) {
        command { commands throws(SessionCommands.Failure) in try await commands.compact(WireBuilders.key(session)) }
    }

    /// The note waiting for a session, while it hasn't read it.
    func noteText(_ session: LiveSession) -> String? {
        guard mail[session.pid] == "note", let file = mailFile(session), let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONDecoder().decode([String: String].self, from: data))?["text"]
    }

    /// Edit: the waiting note comes back to be changed and sent again, unless the session read it meanwhile. It
    /// goes into the composer when its conversation is open, else into the note sheet.
    var noteDraft = ""
    func editNote(_ session: LiveSession) {
        guard let text = noteText(session) else { return }
        command { commands throws(SessionCommands.Failure) in
            try commands.takeBack(WireBuilders.key(session))
            if let id = session.sessionID, id == self.selectedID {
                self.drafts[id] = text
                self.outcomes[id] = nil
            } else {
                self.noteDraft = text
                self.noting = session
            }
        }
    }

    func deleteMail(_ session: LiveSession) {
        command { commands throws(SessionCommands.Failure) in try commands.takeBack(WireBuilders.key(session)) }
    }

    enum MailError: Error { case hooksOff, notClaude, empty, failed(String) }

    /// The mail itself, shared by the island and the phone.
    func leaveMail(_ kind: String, text: String? = nil, to session: LiveSession) throws(MailError) {
        // Codex takes notes only: it runs the tool a stop's hook answer would hold back.
        guard session.provider == .claude || kind == "note", let file = mailFile(session) else { throw .notClaude }
        guard store.isDemo || store.island.installed[session.provider == .codex ? .codex : .claude] == true else { throw .hooksOff }
        var note = ["kind": kind]
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { note["text"] = text } else if kind == "note" { throw .empty }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(note).write(to: file, options: .atomic)
        } catch {
            throw .failed(error.localizedDescription)
        }
        mailAt[session.pid] = Date().timeIntervalSince1970
        withAnimation(Ink.ease) { mail[session.pid] = kind }
    }

    /// Takes back mail the session hasn't read; false when there was none left to take.
    @discardableResult func cancelMail(_ session: LiveSession) -> Bool {
        struct Taken: Decodable { let since: Double? }
        guard let file = mailFile(session) else { return false }
        let unread = (try? Data(contentsOf: file)).map { (try? JSONDecoder().decode(Taken.self, from: $0))?.since == nil } ?? false
        try? FileManager.default.removeItem(at: file)
        mailAt[session.pid] = nil
        withAnimation(Ink.ease) { mail[session.pid] = nil }
        return unread
    }

    /// Mail is gone once a session took it; a stop it took (stamped "since") is done once its hold is over,
    /// and mail for sessions that ended is dropped.
    private func pruneMail() {
        struct Taken: Decodable { let since: Double? }
        let running = Set(live.map(\.pid))
        // Codex's by thread id, for the session that has it.
        let threads = Dictionary(live.filter { $0.provider == .codex }.compactMap { live in live.sessionID.map { ($0, live.pid) } }) { a, _ in a }
        func files(_ folder: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        }
        var left = Set<Int>()
        for (file, codex) in files(mailFolder).map({ ($0, false) }) + files(mailFolder.appendingPathComponent("codex")).map({ ($0, true) }) {
            let since = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Taken.self, from: $0) }?.since
            let name = file.deletingPathExtension().lastPathComponent
            if let pid = codex ? threads[name] : Int(name), running.contains(pid) {
                if since == nil { left.insert(pid) }
                if since.map({ Date().timeIntervalSince1970 - $0 < 10 }) ?? true { continue }
            }
            try? FileManager.default.removeItem(at: file)
        }
        if mail.keys.contains(where: { !left.contains($0) }) {
            mailAt = mailAt.filter { left.contains($0.key) }
            withAnimation(Ink.ease) { mail = mail.filter { left.contains($0.key) } }
        }
    }

    func open(_ id: String, at uuid: String? = nil) {
        selectedID = id
        focus = uuid
        fullHistory = fullHistory.filter { $0 == id }
        if let uuid, cache[id]?.messages.contains(where: { $0.uuid == uuid }) != true {
            openAround(id, uuid)
            return
        }
        if let cached = cache[id] {
            if detail?.session.id != id { detail = cached }
            error = nil
            loading = false
            return
        }
        loading = true
        Task {
            do {
                let value = try await load(id)
                if selectedID == id { detail = value; error = nil }
            } catch {
                if selectedID == id { detail = nil; self.error = error.localizedDescription }
            }
            if selectedID == id { loading = false }
        }
    }

    /// A search hit deep in a long conversation opens on a page around it, not the newest messages.
    private func openAround(_ id: String, _ uuid: String) {
        let key = id + " " + uuid
        if let page = pages[key] {
            detail = page
            focus = page.focus ?? uuid
            error = nil
            loading = false
            return
        }
        loading = true
        Task {
            do {
                let page = try await loadPage(id, uuid)
                guard selectedID == id else { return }
                detail = page
                focus = page.focus
                error = nil
            } catch {
                if selectedID == id { detail = nil; self.error = error.localizedDescription }
            }
            if selectedID == id { loading = false }
        }
    }

    private func loadPage(_ id: String, _ uuid: String) async throws -> SessionDetail {
        let key = id + " " + uuid
        if let page = pages[key] { return page }
        guard let reader else { throw BridgeFailure(message: "Install Python 3 to search sessions.") }
        var page = try await Task.detached {
            try await reader.request(["show", "--limit", "150", "--around", uuid, "--", id], as: SessionDetail.self, timeout: .seconds(60)).prepared()
        }.value
        page.session = localized(page.session)
        page.forks = page.forks.map(localized)
        page.parent = page.parent.map(localized)
        // Pages are search-only and short-lived; the newest messages stay the conversation's cached view.
        pages[key] = page
        if pages.count > 8 { pages.removeValue(forKey: pages.keys.first { $0 != key }!) }
        return page
    }

    /// Back from a page in the history to the newest messages.
    func showLatest() {
        guard let id = selectedID else { return }
        focus = nil
        open(id)
    }

    func prefetch(_ id: String, at uuid: String? = nil) {
        if let uuid {
            guard pages[id + " " + uuid] == nil, cache[id]?.messages.contains(where: { $0.uuid == uuid }) != true, inflight.count < 2 else { return }
            Task { _ = try? await loadPage(id, uuid) }
            return
        }
        // One guess at a time, so a real open never waits behind several.
        guard cache[id] == nil, inflight[id] == nil, inflight.count < 2 else { return }
        Task { _ = try? await load(id) }
    }

    /// A raw reply line for the phone's transcript, image and project calls, from the conversation process.
    func remoteReply(_ args: [String]) async throws -> Data {
        if let source = transcriptSource {
            if remoteReader == nil {
                remoteReader = SessionBridge(python: source.python, bridge: source.bridge, root: source.root,
                                             environment: ["HOME": source.home.path, "PATH": "/usr/bin:/bin"])
            }
        } else if reader == nil {
            warm()
        }
        guard let reader = remoteReader ?? reader else { throw BridgeFailure(message: "Side A can't read sessions on this Mac.") }
        return try await reader.data(args, timeout: .seconds(60))
    }

    /// The Remote harness only: the phone's transcripts come from this home, bridge and index root, even in the demo.
    /// The root is its own: every demo store in a process shares one, and parallel tests would index over each other.
    @ObservationIgnored var transcriptSource: (home: URL, bridge: URL, python: String, root: URL)? { didSet { listGeneration += 1 } }
    /// Moves on whenever the index takes in a transcript, so the phone's cached lists are made again.
    @ObservationIgnored private(set) var listGeneration = 0
    @ObservationIgnored private var remoteReader: SessionBridge?

    /// The newest messages first: a long conversation opens without decoding and laying out its whole history.
    func loadEarlier() {
        guard let id = selectedID, detail?.session.id == id else { return }
        invalidate(id)
        fullHistory.insert(id)
        Task {
            if let value = try? await load(id), selectedID == id { detail = value }
        }
    }

    private func load(_ id: String) async throws -> SessionDetail {
        if let cached = cache[id] { return cached }
        let limit = fullHistory.contains(id) ? 100_000 : 150
        let started = generation[id, default: 0]
        if let running = inflight[id], running.limit == limit { return try await running.task.value }
        guard let reader else { throw BridgeFailure(message: "Install Python 3 to search sessions.") }
        let task = Task.detached {
            try await reader.request(["show", "--limit", String(limit), "--", id], as: SessionDetail.self, timeout: .seconds(60)).prepared()
        }
        inflight[id] = (limit, task)
        defer { if inflight[id]?.limit == limit { inflight[id] = nil } }
        var value = try await task.value
        value.session = localized(value.session)
        value.forks = value.forks.map(localized)
        value.parent = value.parent.map(localized)
        // A file change during the load means this copy is already old: return it, don't keep it.
        guard generation[id, default: 0] == started else { return value }
        cache[id] = value
        recency.removeAll { $0 == id }
        recency.append(id)
        if recency.count > 24 { cache[recency.removeFirst()] = nil }
        return value
    }

    private static func group(_ results: [SessionInfo]) -> [ProjectGroup] {
        let present = Set(results.map(\.id))
        let children = Dictionary(grouping: results.filter { $0.forkedFrom.map(present.contains) == true }, by: { $0.forkedFrom! })
        func tree(_ session: SessionInfo, _ depth: Int) -> [ProjectGroup.Row] {
            [.init(session: session, depth: depth)] + (children[session.id] ?? []).sorted { ($0.firstTs ?? 0) < ($1.firstTs ?? 0) }.flatMap { tree($0, depth + 1) }
        }
        var order: [String] = []
        var rows: [String: [ProjectGroup.Row]] = [:]
        for root in results where root.forkedFrom.map(present.contains) != true {
            let path = root.cwd ?? ""
            if rows[path] == nil { order.append(path) }
            rows[path, default: []] += tree(root, 0)
        }
        return order.map { ProjectGroup(path: $0, name: $0.isEmpty ? "No folder" : URL(fileURLWithPath: $0).lastPathComponent, rows: rows[$0]!) }
    }

    /// In the order the list shows them, skipping idle sessions while they're folded away.
    func step(_ delta: Int) {
        let listed = self.listed
        let done = Set(listed.finished.compactMap(\.finish.sessionID))
        let running = (byProject(listed.working) + (idleOpen ? byProject(listed.idle) : [])).flatMap(\.sessions)
        let sections = showsSections ? listed.waiting.compactMap(\.sessionID) + listed.finished.compactMap(\.finish.sessionID)
            + running.compactMap(\.sessionID) + visiblePins.map(\.id).filter { !done.contains($0) } : []
        let ids = searching ? results.map(\.id) : sections + groups.flatMap { $0.rows.map(\.session.id).filter { !done.contains($0) } }
        guard !ids.isEmpty else { return }
        let next = selectedID.flatMap { ids.firstIndex(of: $0) }.map { min(max($0 + delta, 0), ids.count - 1) } ?? 0
        open(ids[next], at: searching ? results[next].snippets?.first?.uuid : nil)
        if ids.indices.contains(next + delta) { prefetch(ids[next + delta], at: searching ? results[next + delta].snippets?.first?.uuid : nil) }
    }

    static func command(_ session: SessionInfo, fork: Bool) -> String {
        let resume = session.isCodex ? "codex resume \(session.id)" : "claude --resume \(session.id)" + (fork ? " --fork-session" : "")
        return session.cwd.map { "cd \(Shell.quote($0)) && \(resume)" } ?? resume
    }

    /// With hosting wanted (terminal hosting or Remote on), starts the session in Side A's tmux server and opens a
    /// tab attached to it, so the phone can join too. Otherwise, or without tmux, it types the command into a new
    /// login shell, as before hosting.
    func resume(_ session: SessionInfo, fork: Bool, in app: TerminalApp) {
        if let cwd = session.cwd, !FileManager.default.fileExists(atPath: cwd) {
            error = "Its folder no longer exists (\(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))), so it can't be resumed there."
            return
        }
        guard store.hostingWanted, store.hosted.available else { return legacyResume(session, fork: fork, in: app) }
        Sounds.play(.spinUp)
        Task {
            do {
                let name = try await store.hosted.start(.init(agent: session.isCodex ? .codex : .claude, cwd: session.cwd ?? NSHomeDirectory(),
                                                              mode: fork ? .fork(session.id) : .resume(session.id)))
                attach(name, cwd: session.cwd, in: app)
                await refreshLive()
            } catch HostedError.alreadyLive(let running) {
                // Never two processes on one transcript: join it, or say where it runs.
                if let name = running.hosted { attach(name, cwd: running.cwd, in: app) }
                else { error = "It's still running in \(hostName(running) ?? "a terminal"), so it wasn't opened twice." }
            } catch HostedError.unavailable {
                legacyResume(session, fork: fork, in: app)
            } catch { self.error = error.localizedDescription }
        }
    }

    /// The terminal the Sessions window resumes into: the one picked in its menu, else the one in use.
    var resumeTerminal: TerminalApp { TerminalApp(rawValue: UserDefaults.standard.string(forKey: "resumeTerminal") ?? "") ?? usualTerminal }

    /// Fork from a running row: the phone's own Fork, a new hosted session, when hosting is wanted; otherwise
    /// `claude --resume … --fork-session` in a terminal, as Branch does.
    func fork(_ session: LiveSession) {
        guard let id = session.sessionID, let cwd = session.cwd else { return }
        let app = resumeTerminal
        guard store.hostingWanted, store.hosted.available else {
            Sounds.play(.spinUp)
            let bare = "claude --resume \(id) --fork-session"
            return open("cd \(Shell.quote(cwd)) && \(bare)", bare: bare, cwd: cwd, in: app, file: "fork-\(id.prefix(8))")
        }
        Sounds.play(.spinUp)
        command { commands throws(SessionCommands.Failure) in
            let name = try await commands.fork(WireBuilders.key(session), origin: "mac")
            self.attach(name, cwd: cwd, in: app)
            await self.refreshLive()
        }
    }

    /// New Session: the phone's own start, a hosted session the terminal attaches to, while hosting is wanted;
    /// otherwise the agent typed into a login shell in the folder, so Side A's account choice applies as it does to Resume.
    func start(_ start: StartHosted, then done: @escaping @MainActor (String?) -> Void) {
        let app = resumeTerminal
        guard store.hostingWanted, store.hosted.available else {
            let agent: Hosting.Agent = start.agent == .codex ? .codex : .claude
            var args = [start.agent == .codex ? "codex" : "claude"]
            if agent == .codex, let effort = start.effort { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            args += Hosting.arguments(agent, .new(model: start.model))
            if agent == .claude, let effort = start.effort { args += ["--effort", effort] }
            if let prompt = start.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty { args.append(prompt) }
            let bare = args.map(Shell.quote).joined(separator: " ")
            Sounds.play(.spinUp)
            open("cd \(Shell.quote(start.cwd)) && \(bare)", bare: bare, cwd: start.cwd, in: app, file: "new-\(UUID().uuidString.prefix(8))")
            return done(nil)
        }
        let commands = SessionCommands(store: store)
        Task {
            do throws(SessionCommands.Failure) {
                let name = try await commands.start(start, origin: "mac")
                Sounds.play(.spinUp)
                self.attach(name, cwd: start.cwd, in: app)
                done(nil)
                await self.refreshLive()
            } catch { done(error.macMessage) }
        }
    }

    /// New Session's sheet is open.
    var creating = false

    /// Restart Fresh's sheet: the session it restarts.
    var restarting: LiveSession?

    /// Opens a tab running `sidea-tmux attach <name>`. The tab's own shell stays behind it, so
    /// detaching or the session ending leaves a prompt.
    func attach(_ name: String, cwd: String?, in app: TerminalApp) {
        let attach = store.hosted.attachCommand(name)
        let folder = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        open(folder.map { "cd \(Shell.quote($0)) && \(attach)" } ?? attach, bare: attach, cwd: folder, in: app, file: "attach-\(name)")
    }

    /// Today's unhosted launch: a login shell, so Side A's account choice applies to the resumed session.
    private func legacyResume(_ session: SessionInfo, fork: Bool, in app: TerminalApp) {
        Sounds.play(.spinUp)
        let resume = session.isCodex ? "codex resume \(session.id)" : "claude --resume \(session.id)" + (fork ? " --fork-session" : "")
        open(Self.command(session, fork: fork), bare: resume, cwd: session.cwd, in: app, file: "resume-\(session.id.prefix(8))")
    }

    /// A new tab running `command`. Warp starts in `cwd` and runs `bare`; Terminal runs a .command file.
    private func open(_ command: String, bare: String, cwd: String?, in app: TerminalApp, file: String) {
        switch app {
        case .ghostty:
            osascript("""
            on run argv
                tell application "Ghostty"
                    activate
                    set cfg to new surface configuration
                    set initial working directory of cfg to (item 2 of argv)
                    set initial input of cfg to (item 1 of argv) & linefeed
                    if (count of windows) > 0 then
                        new tab in front window with configuration cfg
                    else
                        new window with configuration cfg
                    end if
                end tell
            end run
            """, command, cwd ?? NSHomeDirectory())
        case .iterm:
            osascript("""
            on run argv
                tell application "iTerm"
                    activate
                    set w to (create window with default profile)
                    tell current session of w to write text (item 1 of argv)
                end tell
            end run
            """, command)
        case .warp:
            // Warp runs a startup command only from a Tab Config; one file is reused for every resume.
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".warp/tab_configs")
            let toml = { (value: String) in "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            let config = "name = \"Resume with Side A\"\n\n[[panes]]\nid = \"main\"\ntype = \"terminal\"\ndirectory = \(toml(cwd ?? NSHomeDirectory()))\ncommands = [\(toml(bare))]\n"
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try config.write(to: folder.appendingPathComponent("side_a_resume.toml"), atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(URL(string: "warp://tab_config/side_a_resume")!)
            } catch { self.error = "Warp could not be opened: \(error.localizedDescription)" }
        case .terminal:
            let url = store.root.appendingPathComponent("runtime/\(file).command")
            let script = "#!/bin/zsh\nexec zsh -lic \(Shell.quote(command + "; exec zsh -l"))\n"
            do {
                try script.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                NSWorkspace.shared.open(url)
            } catch { self.error = "Terminal could not be opened: \(error.localizedDescription)" }
        }
    }

    func show(_ session: LiveSession) {
        if let name = session.hosted { return showHosted(name, session) }
        Task {
            if let message = await reveal(pid: session.pid, cwd: session.cwd, title: session.title ?? session.name) { error = message }
        }
    }

    /// A session in the user's own tmux shows through an attached client's tab, else a new tab that attaches. A client
    /// in tmux itself (nested) is followed the same way.
    func reveal(pid: Int, cwd: String?, title: String?) async -> String? {
        await reveal(pid, cwd: cwd, title: title, depth: 0)
    }

    private func reveal(_ pid: Int, cwd: String?, title: String?, depth: Int) async -> String? {
        if let host = TerminalFocus.host(of: pid) { return await TerminalFocus.show(host, cwd: cwd, title: title) }
        guard depth < 4, let pane = await TerminalFocus.tmuxPane(of: pid) else { return TerminalFocus.whereabouts(of: pid) }
        await pane.select()
        for client in pane.clients {
            // tmux titles the client's tab, so the client's own folder finds it.
            if await reveal(Int(client), cwd: TerminalFocus.cwd(of: client), title: nil, depth: depth + 1) == nil { return nil }
        }
        open(pane.attach, bare: pane.attach, cwd: cwd, in: usualTerminal, file: "tmux-attach-\(UUID().uuidString.prefix(8))")
        return nil
    }

    /// tmux daemonizes, so a hosted session's own parents end at launchd: its Mac tab is found
    /// through the tab's tmux client instead. With no tab open, Show opens one.
    private func showHosted(_ name: String, _ session: LiveSession) {
        Task {
            let tab = await store.hosted.clients(name).first { !$0.phone }
            guard let tab, let host = TerminalFocus.host(of: Int(tab.pid)) else { return attach(name, cwd: session.cwd, in: usualTerminal) }
            if let message = await TerminalFocus.show(host, cwd: session.cwd, title: session.title ?? session.name) { error = message }
        }
    }

    func hostName(_ session: LiveSession) -> String? {
        guard let name = session.hosted else { return TerminalFocus.host(of: session.pid)?.app }
        return store.hosted.macClients[name].flatMap { TerminalFocus.host(of: Int($0.pid))?.app } ?? usualTerminal.title
    }

    private func osascript(_ source: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source] + arguments
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { [weak self] finished in
            guard finished.terminationStatus != 0 else { return }
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Task { @MainActor in
                self?.error = message.contains("-1743") ? "Allow Side A to control your terminal in System Settings > Privacy & Security > Automation."
                    : "The terminal could not be opened. Copy the command instead."
            }
        }
        do { try process.run() } catch { self.error = "The terminal could not be opened. Copy the command instead." }
    }

    static func copy(_ text: String) {
        Sounds.play(.tick)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
