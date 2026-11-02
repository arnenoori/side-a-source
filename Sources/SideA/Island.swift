import AppKit
import Carbon.HIToolbox
import Observation
import SideACore
import UserNotifications

@MainActor @Observable
final class Island {
    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let connection: UInt64?
        let request: IslandRequest
        let title: String
        let account: String?
        let arrived = Date()
        /// Codex shows its own prompt only after the hook returns, so its requests go back to the terminal after a while.
        let handBackAt: Date?
        var origin: String? = nil
    }

    struct Event: Identifiable, Equatable {
        enum Kind { case track, limit, waiting, finished }
        let id = UUID()
        let kind: Kind
        let title: String
        let detail: String
        var pid: Int?
        var cwd: String?
    }

    /// A finished turn, and the background Stop hook waiting on it for a follow-up, while it waits.
    struct Ready: Identifiable, Equatable {
        let id = UUID()
        let finish: IslandFinish
        let title: String
        let at = Date()
        var waiter: UInt64? = nil
    }

    /// A follow-up sent while its session worked. Only `waiting` ones are held; the others are what became of them.
    enum QueuedFollowUp: Sendable, Equatable {
        enum Drop: Sendable, Equatable {
            case sessionEnded
            /// The turn ended with a Stop hook that doesn't wait.
            case cannotWait
            /// The phone that sent it was removed.
            case revoked
            /// The session asks more now than was proven when it was sent.
            case outranked
        }
        /// Who queued it, and what they proved. Nil from the Mac itself, whoever is at it being its owner.
        struct Origin: Sendable, Equatable {
            let device: String
            let proven: ConfirmProof
        }
        case waiting(String, from: Origin? = nil)
        case delivered
        case dropped(Drop)
    }

    struct Layout: Equatable {
        /// nil on a display without a notch.
        var notch: CGSize?
    }

    static let onKey = "island"
    static let eventsKey = "islandEvents"
    static let waitingKey = "islandWaiting"
    static let finishedKey = "islandFinished"
    /// Off by default: an automated run's finish has no prompt to go back to.
    static let finishedAutomatedKey = "islandFinishedAutomated"
    /// Seconds a finished session stays in the notch's Done list; 0 keeps it until it's gone to or given work.
    static let finishedClearKey = "islandFinishedClear"
    static let screenKey = "islandScreen"
    static let lastCodexHookKey = "lastCodexHookAt"
    static let queueLimit = 5

    /// Who or what settled a request, kept for late answers: a phone that answers one already gone gets a precise 409.
    enum Resolution: Sendable, Equatable {
        case mac, notification, remote(device: String, name: String), terminal, finished, handedBack, gone
        /// Answered by itself after `autoAnswerAfter`, with the request's `recommendedAnswer`.
        case auto
    }

    /// Remote's view of the island; set only while Remote records.
    @MainActor protocol Watcher: AnyObject {
        func requestAdded(_ item: Pending)
        func requestResolved(_ item: Pending, by: Resolution, answer: IslandAnswer?)
        func readyChanged(from old: [Ready], to new: [Ready], reason: ReadyReason)
        func queued(session: String, text: String, became outcome: QueuedFollowUp)
    }
    enum ReadyReason: String, Sendable {
        case replied, resumed, released, expired, sentQueued
        /// A phone that doesn't know it only drops the session's finished row, as for any other reason.
        case queueDropped
    }

    var pending: [Pending] = []
    var index = 0
    var expanded = false
    var event: Event?
    /// Sessions that finished and haven't been given more work, newest first.
    var ready: [Ready] = [] {
        didSet {
            guard oldValue != ready else { return }
            watcher?.readyChanged(from: oldValue, to: ready, reason: leavingBecause)
        }
    }
    /// Why rows are going, for the length of the one change `drop` makes.
    @ObservationIgnored private var leavingBecause: ReadyReason = .released
    @ObservationIgnored weak var watcher: Watcher?
    @ObservationIgnored private(set) var resolved: [Pending.ID: (by: Resolution, answer: IslandAnswer?, at: Date)] = [:]
    @ObservationIgnored private var resolvedOrder: [Pending.ID] = []
    /// The card that took the place of one settled elsewhere, and when.
    @ObservationIgnored private(set) var arrived: (id: Pending.ID, at: Date)?
    /// Seconds a card that slid into a settled one's place ignores the Mac's own answers.
    static let arrivalGuard: TimeInterval = 0.6
    var layout = Layout()
    var installed: [IslandAgent: Bool] = [:]
    /// Whether Codex runs the mail hooks ("trusted", "review" until the user trusts them in Codex, "unknown"), while
    /// its island is on.
    var codexMail: String?
    var focusRequest = 0
    /// ⌃⌥1–4 on a form the view pages through: the option to pick on the question it shows.
    var choice: Choice?
    struct Choice: Equatable { let option: Int; let serial: Int }
    /// Answers picked so far on each question form, so folding the island or stepping to another request keeps them.
    var drafts: [Pending.ID: Draft] = [:]
    struct Draft { var picked: [String: [String]] = [:]; var other: [String: String] = [:]; var step = 0 }
    /// The Ready row whose reply field is open.
    var replying: Ready.ID?
    /// Per session, follow-ups queued while it works: on disk, because the Stop hook that takes them can outlast this app.
    @ObservationIgnored private(set) var queued: [String: [QueuedFollowUp]] = [:]
    @ObservationIgnored private var queuedGoneSince: [String: Date] = [:]
    @ObservationIgnored lazy var queuedFile: URL? = store.flatMap { $0.isDemo ? nil : $0.root.appendingPathComponent("runtime/queued-followups.json") }
    /// Tests hold waiters without touching Remote's global state.
    @ObservationIgnored var keepsFinished: () -> Bool = { Island.keepsWaiters }
    /// How long a session must stay off the live list before what's queued for it counts as lost.
    static let queuedGrace: TimeInterval = 60
    /// Answers for requests that didn't come through the hook socket: Codex's app server asks every client it has.
    @ObservationIgnored private var responders: [Pending.ID: (IslandAnswer) -> Void] = [:]
    /// When each request that has a recommended answer gets it, while that's on; an answer from anywhere removes it.
    @ObservationIgnored private(set) var autoAnswerAt: [Pending.ID: Date] = [:]
    /// How long a question or plan waits before it's answered with the recommended choice, while that's on.
    @ObservationIgnored var autoAnswerAfter: TimeInterval = 60
    @ObservationIgnored private var autoAnswerTask: Task<Void, Never>?

    var current: Pending? { pending.indices.contains(index) ? pending[index] : pending.first }
    /// With the notch off, requests and finished sessions are still held for Remote, just never shown here.
    var visible: Bool { Self.on && (!pending.isEmpty || event != nil || !ready.isEmpty) }
    /// The notch. Remote keeps the hooks and the Stop waiters without it.
    static var on: Bool { UserDefaults.standard.bool(forKey: onKey) }
    static var keepsWaiters: Bool { on && setting(finishedKey) || RemoteController.active }

    @ObservationIgnored private weak var store: AccountStore?
    @ObservationIgnored private var server: IslandServer?
    @ObservationIgnored private let hotKeys = HotKeys()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private lazy var panel = IslandPanel(island: self)
    @ObservationIgnored private var keys: KeySet = .none
    private enum KeySet { case none, ready, requests }

    init(store: AccountStore) { self.store = store }

    func start() {
        guard server == nil, let store else { return }
        loadQueued()
        let server = IslandServer(path: store.root.appendingPathComponent("runtime/island.sock").path,
            received: { [weak self] id, line in
                Task { @MainActor in self?.receive(id, line) }
            },
            closed: { [weak self] id in
                Task { @MainActor in self?.handedBack(id) }
            })
        do { try server.start(); self.server = server } catch { store.error = error.localizedDescription }
    }

    func stop() { server?.stop(); server = nil }

    private func receive(_ connection: UInt64, _ line: Data) {
        if let finish = IslandFinish(message: line) {
            if finish.agent == .codex { Self.heardFromCodex() }
            finished(finish, connection: connection)
            return
        }
        guard let request = IslandRequest(message: line) else {
            server?.reply(connection, IslandAnswer.terminal.line)
            return
        }
        if request.agent == .codex { Self.heardFromCodex() }
        let title = request.sessionID.flatMap { store?.sessions.title(of: $0) } ?? request.project ?? request.agent.title
        // The hook's parent is alive while the hook runs, so its environment answers what the message doesn't say.
        let env = request.hosted == nil || request.agent == .codex && request.home == nil ? request.pid.flatMap { ProcessEnvironment.read(pid: pid_t($0)) } : nil
        let hosted = request.hosted ?? env?["SIDE_A_HOSTED"]
        let item = Pending(connection: connection, request: request, title: title, account: account(request, env: env),
                           handBackAt: IslandHold.handBack(agent: request.agent, headless: request.headless, hosted: hosted != nil,
                                                               subagent: request.subagent)
                               .map { Date().addingTimeInterval($0) },
                           origin: request.pid.flatMap(TerminalFocus.origin(of:)))
        add(item)
    }

    /// Claude by its slot's owner; Codex by its home, which names a profile's account and is never traded.
    private func account(_ request: IslandRequest, env: [String: String]?) -> String? {
        guard let store else { return nil }
        let id: String?
        if request.agent == .claude {
            id = request.slot.flatMap(store.accountID(inSlot:))
        } else {
            let value = request.home ?? env?["CODEX_HOME"]
            let home = ProcessEnvironment.codexHome(value.map { ["CODEX_HOME": $0] } ?? [:], root: store.root.path,
                                                    home: FileManager.default.homeDirectoryForCurrentUser.path)
            id = store.accountID(codexHome: home) ?? store.activeIDs[.codex]
        }
        return id.flatMap { id in store.config.accounts.first { $0.id == id }?.name }
    }

    /// Codex keeps its hook trust to itself; a message from its hooks is the proof setup shows.
    private static func heardFromCodex() { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCodexHookKey) }

    private func add(_ item: Pending) {
        if let session = item.request.sessionID { drop(ready.filter { $0.finish.sessionID == session }, .released) }
        let first = pending.isEmpty
        pending.append(item)
        if first { index = 0 }
        expanded = true
        if event?.kind == .waiting { event = nil }
        watcher?.requestAdded(item)
        if Self.on {
            Sounds.play(.nudge)
            announce(item.request.announcement, high: true)
        }
        if WaitingNotifier.enabled { WaitingNotifier.deliver(item) }
        if let handBack = item.handBackAt {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(handBack.timeIntervalSinceNow))
                guard let self, self.pending.contains(where: { $0.id == item.id }) else { return }
                self.answer(.terminal, item.id, quietly: true, by: .handedBack)
            }
        }
        armAutoAnswer([item], from: item.arrived)
        changed()
    }

    /// The setting changed: requests already waiting get their minute from now, so turning it on never answers at once.
    func autoAnswerChanged() {
        autoAnswerAt = [:]
        armAutoAnswer(pending, from: Date())
    }

    private func armAutoAnswer(_ items: [Pending], from start: Date) {
        if store?.config.answerRecommended == true {
            for item in items where item.request.recommendedAnswer != nil { autoAnswerAt[item.id] = start.addingTimeInterval(autoAnswerAfter) }
        }
        autoAnswerTask?.cancel()
        guard let next = autoAnswerAt.values.min() else { autoAnswerTask = nil; return }
        autoAnswerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled else { return }
            self?.answerDue()
        }
    }

    /// Answers each request whose minute is up, quietly, and records it; then waits for the next.
    func answerDue(now: Date = Date()) {
        for (id, at) in autoAnswerAt where at <= now {
            autoAnswerAt[id] = nil
            guard let item = pending.first(where: { $0.id == id }), let answer = item.request.recommendedAnswer,
                  respond(answer, id, quietly: true, by: .auto) else { continue }
            store?.autoAnswered(item, answer)
        }
        armAutoAnswer([], from: now)
    }

    /// A request from somewhere other than a hook, answered through `respond`. The terminal asks too, so it is never
    /// handed back on a timer.
    @discardableResult
    func add(_ request: IslandRequest, account: String?, respond: @escaping (IslandAnswer) -> Void) -> Pending.ID {
        let title = request.sessionID.flatMap { store?.sessions.title(of: $0) } ?? request.project ?? request.agent.title
        let item = Pending(connection: nil, request: request, title: title, account: account, handBackAt: nil)
        responders[item.id] = respond
        add(item)
        return item.id
    }

    /// The request was settled elsewhere, as in the terminal, or its source went away.
    func withdraw(_ id: Pending.ID, by: Resolution) {
        responders[id] = nil
        remove(id, by: by)
    }

    private func handedBack(_ connection: UInt64) {
        for index in ready.indices where ready[index].waiter == connection { ready[index].waiter = nil }
        guard let item = pending.first(where: { $0.connection == connection }) else { return }
        remove(item.id, by: .gone)
    }

    /// `confirmed` is a click on the card's own Allow, or the phone's confirmation after Face ID; a destructive Allow
    /// without it is refused. `by` is who answered, for a late answer from the phone.
    func answer(_ answer: IslandAnswer, _ id: Pending.ID? = nil, quietly: Bool = false, confirmed: Bool = false, by: Resolution = .mac) {
        respond(answer, id, quietly: quietly, confirmed: confirmed, by: by)
    }

    /// `answer`, saying whether the request took it.
    @discardableResult
    func respond(_ answer: IslandAnswer, _ id: Pending.ID? = nil, quietly: Bool = false, confirmed: Bool = false, by: Resolution = .mac) -> Bool {
        // A card answering a request that's already gone must not answer the next one.
        if let id, !pending.contains(where: { $0.id == id }) { return false }
        guard let item = id.flatMap({ id in pending.first { $0.id == id } }) ?? current else { return false }
        if by == .mac, let arrived, arrived.id == item.id, -arrived.at.timeIntervalSinceNow < Self.arrivalGuard {
            NSSound.beep()
            return false
        }
        if case .allow = answer, case .plan = item.request.action {
            return respond(.approvePlan(input: item.request.input, acceptEdits: false), item.id, quietly: quietly, by: by)
        }
        if case .allow = answer, case .question = item.request.action { if case .remote = by {} else { NSSound.beep() }; return false }
        // A mode switch rides on an Allow; a plan's own approval and a question's answers have their own shapes.
        if case .allowMode = answer {
            switch item.request.action {
            case .plan, .question: return false
            default: break
            }
        }
        if !item.request.accepts(answer, confirmed: confirmed) {
            if case .remote = by { return false }
            NSSound.beep()
            announce("\(item.request.riskReason ?? "This request is destructive"). Click Allow anyway to approve it.", high: true)
            return false
        }
        if let connection = item.connection { server?.reply(connection, answer.line) } else { responders.removeValue(forKey: item.id)?(answer) }
        remove(item.id, by: by, answer: answer)
        if case .remote(_, let name) = by, Self.on {
            Sounds.play(.tick)
            announce("Answered on \(name).", high: false)
        } else if !quietly {
            Sounds.play(.tick)
            switch answer {
            case .allow, .allowMode, .always, .approvePlan: announce("Allowed.", high: false)
            case .answers: announce("Answered.", high: false)
            case .deny: announce("Denied.", high: false)
            case .terminal: announce("Handed back to the terminal.", high: false)
            }
        }
        return true
    }

    func always(_ suggestion: IslandSuggestion? = nil) {
        guard let item = current, item.request.offersAlways,
              let suggestion = suggestion ?? item.request.suggestions.first else { return }
        answer(.always(suggestion), item.id)
    }

    /// The request stays, folded into the notch, until it's answered here or in the terminal.
    func showTerminal(_ item: Pending? = nil) {
        guard let item = item ?? current else { return }
        if let origin = item.origin {
            return notice("No terminal to show", "It's an automated run started by \(origin), so only Side A can answer it.")
        }
        reveal(pid: item.request.pid, cwd: item.request.cwd, title: item.title)
        collapse()
    }

    func answerInTerminal(_ item: Pending) {
        answer(.terminal, item.id)
        reveal(pid: item.request.pid, cwd: item.request.cwd, title: item.title)
    }

    func reveal(pid: Int?, cwd: String?, title: String?) {
        // A hosted session's parents end at tmux's server; its tab is found through its tmux client.
        if let pid, let sessions = store?.sessions, let live = sessions.live.first(where: { $0.pid == pid }), live.hosted != nil {
            return sessions.show(live)
        }
        guard let pid, let sessions = store?.sessions else {
            return notice("Couldn't find that terminal", "The session may have closed.")
        }
        Task { [weak self] in
            if let message = await sessions.reveal(pid: pid, cwd: cwd, title: title) { self?.notice("Couldn't show that terminal", message) }
        }
    }

    func step(_ delta: Int) {
        guard !pending.isEmpty else { return }
        index = (index + delta + pending.count) % pending.count
        if let item = current { announce("\(index + 1) of \(pending.count). \(item.request.announcement)", high: true) }
    }

    func collapse() { expanded = false; changed() }

    func expand() { expanded = true; changed() }

    func focus() {
        guard visible else { return }
        expanded = true
        changed()
        panel.makeKey()
        focusRequest += 1
    }

    /// The one place a request leaves, with who or what settled it.
    private func remove(_ id: Pending.ID, by: Resolution, answer: IslandAnswer? = nil) {
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [WaitingNotifier.requestPrefix + id.uuidString])
        }
        responders[id] = nil
        autoAnswerAt[id] = nil
        guard let position = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending[position]
        let shown = current?.id
        pending.remove(at: position)
        // The card on screen stays on screen when one before it goes.
        if position < index { index -= 1 }
        index = min(index, max(pending.count - 1, 0))
        // Settled away from this card: the next one slides in under the pointer, so for a moment a click or ⌃⌥Y meant for
        // the old card mustn't answer it.
        switch by {
        case .mac, .notification: arrived = nil
        default: arrived = shown == id ? current.map { ($0.id, Date()) } : arrived
        }
        resolved[id] = (by, answer, Date())
        resolvedOrder.append(id)
        if resolvedOrder.count > 256 { resolved[resolvedOrder.removeFirst()] = nil }
        watcher?.requestResolved(item, by: by, answer: answer)
        drafts[id] = nil
        if pending.isEmpty { expanded = false }
        changed()
    }

    func show(_ kind: Event.Kind, _ title: String, _ detail: String, pid: Int? = nil, cwd: String? = nil) {
        guard Self.on, kind == .waiting ? Self.setting(Self.waitingKey) : Self.setting(Self.eventsKey) else { return }
        if kind == .waiting, pending.contains(where: { $0.request.cwd == cwd && cwd != nil }) { return }
        event = Event(kind: kind, title: title, detail: detail, pid: pid, cwd: cwd)
        announce("\(title). \(detail)", high: false)
        eventTask?.cancel()
        let seconds: Double = kind == .waiting ? 8 : 5
        eventTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.event = nil
            self.changed()
        }
        changed()
    }

    func finished(_ finish: IslandFinish, connection: UInt64? = nil) {
        let title = finish.sessionID.flatMap { store?.sessions.title(of: $0) } ?? finish.project ?? finish.agent.title
        for item in pending where item.request.sessionID != nil && item.request.sessionID == finish.sessionID {
            answer(.terminal, item.id, quietly: true, by: .finished)
        }
        if let connection, !finish.waits { server?.reply(connection, Data()) }
        let earlier = ready.filter { $0.finish.sessionID != nil && $0.finish.sessionID == finish.sessionID }
        var waiter = finish.waits ? connection : nil
        if let session = finish.sessionID, queued[session] != nil, connection != nil {
            guard let waiter else { dropQueued(session, .cannotWait); return finishedRow(finish, title: title, earlier: earlier, waiter: nil) }
            if deliverQueued(session, to: waiter, title: title, earlier: earlier) { return }
        } else if finish.sessionID == nil, let unusable = waiter {
            server?.reply(unusable, IslandFollowUp.line(nil))
            waiter = nil
        }
        finishedRow(finish, title: title, earlier: earlier, waiter: waiter)
    }

    /// The turn's row in Ready, in place of any before it, and its notice.
    private func finishedRow(_ finish: IslandFinish, title: String, earlier: [Ready], waiter: UInt64?) {
        guard keepsFinished() else {
            if let waiter { server?.reply(waiter, IslandFollowUp.line(nil)) }
            drop(earlier, .released)
            return
        }
        drop(earlier, .released)
        var row = Ready(finish: finish, title: title)
        row.waiter = waiter
        ready.insert(row, at: 0)
        let kept = ready.filter { -$0.at.timeIntervalSinceNow <= 7200 }.prefix(8)
        drop(ready.filter { row in !kept.contains { $0.id == row.id } }, .expired)
        let clearAfter = UserDefaults.standard.integer(forKey: Self.finishedClearKey)
        if Self.on, clearAfter > 0, let row = ready.first?.id {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(clearAfter))
                self?.clearReady(row)
            }
        }
        guard Self.on, Self.setting(Self.finishedKey), !finish.headless || UserDefaults.standard.bool(forKey: Self.finishedAutomatedKey) else {
            changed(); return
        }
        Sounds.play(.done)
        event = Event(kind: .finished, title: "\(title) is done", detail: finish.summary.isEmpty ? "Ready for what's next." : finish.summary,
                      pid: finish.pid, cwd: finish.cwd)
        announce("\(title) is done. \(finish.summary) Control Option G goes to it.", high: false)
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard let self, !Task.isCancelled else { return }
            self.event = nil
            self.changed()
        }
        changed()
    }

    /// Opens the session's terminal for its next task; with no argument, the one that finished last.
    func go(_ item: Ready? = nil) {
        guard let item = item ?? ready.first else { return }
        if event?.kind == .finished { event = nil; eventTask?.cancel() }
        reveal(pid: item.finish.pid, cwd: item.finish.cwd, title: item.title)
        leave([item], .released)
    }

    /// The one way rows go from Ready. Each one's Stop hook ends now, with `followUp` as its next task if there is one, so
    /// no hook outlives its row and no row is shown as waiting on a hook that's gone.
    private func drop(_ rows: [Ready], _ reason: ReadyReason, followUp: String? = nil) {
        let ids = Set(rows.map(\.id))
        let going = ready.filter { ids.contains($0.id) }
        guard !going.isEmpty else { return }
        for row in going {
            if let waiter = row.waiter { server?.reply(waiter, IslandFollowUp.line(followUp)) }
        }
        if let replying, ids.contains(replying) { self.replying = nil }
        leavingBecause = reason
        ready.removeAll { ids.contains($0.id) }
        leavingBecause = .released
    }

    /// `drop`, then the notch folds if that was the last of what it held.
    private func leave(_ rows: [Ready], _ reason: ReadyReason, followUp: String? = nil) {
        drop(rows, reason, followUp: followUp)
        if ready.isEmpty && pending.isEmpty { expanded = false }
        changed()
    }

    func clearReady() { leave(ready, .released) }

    /// One finished row whose time in the Done list is up; a row being replied to stays.
    private func clearReady(_ id: Ready.ID) {
        guard replying != id, let row = ready.first(where: { $0.id == id }) else { return }
        leave([row], .expired)
    }

    func canReply(_ item: Ready) -> Bool { ready.first { $0.id == item.id }?.waiter != nil }

    /// Wakes the finished session with its next task through its waiting Stop hook. Without one (Codex, or the
    /// hour it waits has passed) the text goes on the clipboard and the session's terminal comes forward.
    func reply(_ item: Ready, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replying = nil
        if canReply(item) {
            leave([item], .replied, followUp: text)
            Sounds.play(.tick)
            announce("Sent to \(item.title).", high: false)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        go(item)
        notice("Copied your reply", "Paste it into \(item.title) with ⌘V.")
    }

    /// For a session that is still working: delivered the moment it next finishes.
    /// False when the text is empty or five are already waiting.
    @discardableResult
    func queue(_ session: String, _ text: String, from origin: QueuedFollowUp.Origin? = nil) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, queued[session, default: []].count < Self.queueLimit else { return false }
        queued[session, default: []].append(.waiting(text, from: origin))
        queuedGoneSince[session] = nil
        saveQueued()
        return true
    }

    /// Hands the next follow-up to the Stop hook that just arrived. False when the session had none after all.
    private func deliverQueued(_ session: String, to waiter: UInt64, title: String, earlier: [Ready]) -> Bool {
        while var next = queued[session], case .waiting(let text, let origin)? = next.first {
            next.removeFirst()
            queued[session] = next.isEmpty ? nil : next
            saveQueued()
            if let origin, origin.proven < queuedNeeds(session) {
                reportDropped(session, text, .outranked)
                continue
            }
            server?.reply(waiter, IslandFollowUp.line(text))
            drop(earlier, .sentQueued)
            watcher?.queued(session: session, text: text, became: .delivered)
            if Self.on { show(.track, "Next task sent to \(title)", text) }
            return true
        }
        return false
    }

    /// What the session's mode asks of a reply right now.
    private func queuedNeeds(_ session: String) -> ConfirmProof {
        guard let store else { return .biometric }
        return ConfirmProof(ConfirmPolicy.session(mode: SessionCommands(store: store).permissionMode(session) ?? nil))
    }

    /// Everything queued for a session that can no longer take it. What was promised as Queued is said to be lost.
    private func dropQueued(_ session: String, _ why: QueuedFollowUp.Drop) {
        guard let lost = queued.removeValue(forKey: session) else { return }
        queuedGoneSince[session] = nil
        saveQueued()
        for case .waiting(let text, _) in lost { reportDropped(session, text, why) }
    }

    /// What a removed phone left queued: its authority went with it.
    func dropQueued(device: String) {
        for (session, items) in queued {
            let kept = items.filter { if case .waiting(_, let origin?) = $0 { origin.device != device } else { true } }
            guard kept.count != items.count else { continue }
            queued[session] = kept.isEmpty ? nil : kept
            saveQueued()
            for case .waiting(let text, let origin?) in items where origin.device == device { reportDropped(session, text, .revoked) }
        }
    }

    private func reportDropped(_ session: String, _ text: String, _ why: QueuedFollowUp.Drop) {
        watcher?.queued(session: session, text: text, became: .dropped(why))
        guard Self.on else { return }
        let reason = switch why {
        case .sessionEnded: "ended"
        case .cannotWait: "can't take it"
        case .revoked: "lost the iPhone that sent it"
        case .outranked: "needs Face ID for it now"
        }
        notice("A queued reply wasn't sent", "\(store?.sessions.title(of: session) ?? "The session") \(reason): \(text)")
    }

    /// Each read of the live list. A session gone from it for `queuedGrace` won't finish, so its Stop hook will never come.
    func liveSessions(_ alive: Set<String>, now: Date = Date()) {
        for session in queued.keys {
            if alive.contains(session) { queuedGoneSince[session] = nil; continue }
            let since = queuedGoneSince[session] ?? now
            queuedGoneSince[session] = since
            if now.timeIntervalSince(since) >= Self.queuedGrace { dropQueued(session, .sessionEnded) }
        }
    }

    /// A queued follow-up on disk. Absent `device` and `proven` means the Mac queued it.
    private struct SavedFollowUp: Codable {
        let text: String
        var device: String?
        var proven: Int?
    }

    func loadQueued() {
        guard let queuedFile, let data = try? Data(contentsOf: queuedFile) else { return }
        guard let saved = try? JSONDecoder().decode([String: [SavedFollowUp]].self, from: data) else {
            // From before follow-ups said who sent them, or unreadable: nobody can vouch for these.
            RemoteLog.shared("dropped a queued follow-up file with no record of who sent them")
            try? FileManager.default.removeItem(at: queuedFile)
            return
        }
        queued = saved.mapValues { $0.map { item in
            .waiting(item.text, from: item.device.map { .init(device: $0, proven: item.proven.flatMap(ConfirmProof.init(rawValue:)) ?? .none) })
        } }
        keepLiveListForQueued()
    }

    private func saveQueued() {
        keepLiveListForQueued()
        guard let queuedFile else { return }
        if queued.isEmpty { try? FileManager.default.removeItem(at: queuedFile); return }
        let items = queued.mapValues { $0.compactMap { item -> SavedFollowUp? in
            guard case .waiting(let text, let origin) = item else { return nil }
            return SavedFollowUp(text: text, device: origin?.device, proven: origin?.proven.rawValue)
        } }
        try? PrivateFile.write(items, to: queuedFile)
    }

    /// Nothing else may be reading the live list, and losing a session is only noticed from it.
    private func keepLiveListForQueued() {
        guard let store, !store.isDemo else { return }
        if !queued.isEmpty { store.sessions.retainLive("queued") } else if store.sessions.liveOwners.contains("queued") { store.sessions.releaseLive("queued") }
    }

    func openReply(_ item: Ready? = nil) {
        guard let item = item ?? ready.first else { return }
        replying = item.id
        dismissEvent()
        expanded = true
        changed()
        panel.makeKey()
        focusRequest += 1
    }

    var holdsSessions: Bool { !pending.isEmpty || !ready.isEmpty || event?.kind == .waiting }

    /// Drops what Claude Code's registry says was settled in the terminal. True when a status is too new to trust yet.
    func sync(_ sessions: [IslandSession]) -> Bool {
        var unsure = false
        for item in pending {
            switch IslandSession.verdict(item.request, arrived: item.arrived, in: sessions, alive: ProcessCheck.alive) {
            case .answered: answer(.terminal, item.id, quietly: true, by: .terminal)
            case .unsure: unsure = true
            case .open: break
            }
        }
        // Codex's pid is the hook's parent, which may be a shell that has already exited.
        let gone = ready.filter { row in row.finish.agent == .claude && row.finish.pid.map { !ProcessCheck.alive($0) } ?? false }
        if !gone.isEmpty { leave(gone, .released) }
        if let event, event.kind == .waiting, let pid = event.pid,
           !ProcessCheck.alive(pid) || sessions.first(where: { $0.pid == pid }).map({ $0.status != "waiting" }) ?? true {
            dismissEvent()
        }
        resumed(Set(sessions.filter { $0.status == "busy" }.compactMap(\.sessionID)))
        return unsure
    }

    /// Claude Code's registry says these sessions are working again, so they've had their next task.
    func resumed(_ sessions: Set<String>) {
        // Given work in the terminal: a follow-up typed in the island now would arrive mid-turn, so release the wait.
        let working = ready.filter { $0.finish.sessionID.map(sessions.contains) == true }
        if !working.isEmpty { leave(working, .resumed) }
    }

    /// Shown whatever the event settings say: it answers something the user just did.
    private func notice(_ title: String, _ detail: String) {
        event = Event(kind: .limit, title: title, detail: detail)
        announce("\(title). \(detail)", high: true)
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            self.event = nil
            self.changed()
        }
        changed()
    }

    func dismissEvent() { eventTask?.cancel(); event = nil; changed() }

    static func setting(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    func preview() {
        let request = IslandRequest(agent: .claude, cwd: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("code/web-app").path,
                                    tool: "Bash", action: .command("npm run test -- --watch=false"), reason: "Run the test suite",
                                    suggestions: [IslandSuggestion(json: Data(#"{"type":"addRules"}"#.utf8), title: "Always allow Bash(npm run test:*) in this project")])
        add(Pending(connection: nil, request: request, title: "Fix the flaky login test", account: store?.active?.name, handBackAt: nil))
    }

    private func changed() {
        // No global shortcuts for a notch that isn't shown.
        let wanted: KeySet = !Self.on ? .none : !pending.isEmpty ? .requests : !ready.isEmpty ? .ready : .none
        if wanted != keys {
            keys = wanted
            switch wanted {
            case .none: hotKeys.unregister()
            case .ready: hotKeys.register([(.controlOption(kVK_ANSI_G), { [weak self] in self?.go() }),
                                           (.controlOption(kVK_ANSI_R), { [weak self] in self?.openReply() }),
                                           (.controlOption(kVK_ANSI_I), { [weak self] in self?.focus() })])
            case .requests: registerKeys()
            }
        }
        panel.update()
    }

    private func registerKeys() {
        hotKeys.register([
            (.controlOption(kVK_ANSI_G), { [weak self] in self?.go() }),
            (.controlOption(kVK_ANSI_Y), { [weak self] in self?.answer(.allow) }),
            (.controlOption(kVK_ANSI_N), { [weak self] in self?.answer(.deny(nil)) }),
            (.controlOption(kVK_ANSI_A), { [weak self] in self?.always() }),
            (.controlOption(kVK_ANSI_T), { [weak self] in self?.showTerminal() }),
            (.controlOption(kVK_ANSI_I), { [weak self] in self?.focus() }),
            (.controlOption(kVK_RightArrow), { [weak self] in self?.step(1) }),
            (.controlOption(kVK_LeftArrow), { [weak self] in self?.step(-1) }),
            (.controlOption(kVK_ANSI_R), { [weak self] in self?.openReply() }),
        ] + [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4].enumerated().map { index, key in
            (.controlOption(key), { [weak self] in self?.choose(index) })
        })
    }

    /// ⌃⌥1–4: answers a one-question, single-choice AskUserQuestion; on a longer form, picks on the question showing.
    func choose(_ index: Int) {
        guard let item = current, case .question(let questions) = item.request.action else { return }
        if questions.count == 1, !questions[0].multiSelect {
            guard questions[0].options.indices.contains(index) else { return }
            answer(.answers([questions[0].question: questions[0].options[index].label], input: item.request.input), item.id)
        } else if expanded {
            choice = Choice(option: index, serial: (choice?.serial ?? 0) + 1)
        }
    }

    func announce(_ text: String, high: Bool) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: (high ? NSAccessibilityPriorityLevel.high : .medium).rawValue])
    }
}
