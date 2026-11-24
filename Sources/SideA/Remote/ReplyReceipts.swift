import Foundation
import SideACore
import SideAProtocol

/// Replies sent into a Claude or Codex session, followed until the agent has read them, so the phone says where each
/// one is from the agent's own record rather than from seeing its words come back: Claude's transcript, Codex's
/// rollout, or Codex's app server, which reports by `clientUserMessageId` through `codex(client:_:)`.
/// A record line is about one message, so it settles one reply, the oldest it fits: two "yes" in one turn are two lines.
@MainActor final class ReplyReceipts {
    private struct Watch {
        /// Nil for a hosted pane whose session isn't in the live list yet.
        var pid: Int?
        let hosted: String?
        let agent: AgentProvider
        /// What the record will show: the reply, or the one prompt it went in with others.
        var text: String
        /// The reply's own words, as the phone sent them: a retry is answered from this one only if it says the same.
        let asked: String
        var transcript: URL?
        var start: UInt64
        let since: Double
        var receipt: ReplyReceipt
        let delivery: ReplyResult.Delivery
        var client: String?
        var stop = StopState.none
        /// Typed as one prompt with others: the line that reads one reads them all.
        var batch: String?
        /// Codex's rollout: a turn ended without it, and none has started since.
        var ended: (at: Double, interrupted: Bool)?
        /// When it went `expired`.
        var expired: Double?

        var state: Following { expired != nil ? .expired(receipt.stage) : Following(receipt.stage) }
        var open: Bool { if case .open = state { true } else { false } }
        var carried: Double? { if case .carried(let since) = stop { since } else { nil } }
        var letGo: Double? { if case .stopping(let letGo) = stop { letGo } else { nil } }
    }

    /// Where a Stop has a reply: one being taken back isn't carried, and a carried one isn't taken back again.
    enum StopState: Hashable {
        case none
        /// A Stop is taking it back from the prompt, so Claude letting go of it isn't the end: that waits in `letGo` for
        /// the Stop's outcome, and stands if it found nothing.
        case stopping(letGo: Double?)
        /// Interrupt and Send: off the prompt since then, to go ahead of the message that follows.
        case carried(since: Double)

        enum Event: Equatable, CaseIterable {
            case stopBegins, letGo, stopEnds, carry, joined
        }

        func next(_ event: Event, at: Double) -> StopState? {
            switch (self, event) {
            case (.none, .stopBegins): .stopping(letGo: nil)
            // Two Stops at once: the first one's let-go stays.
            case (.stopping, .stopBegins): nil
            case (.stopping, .letGo): .stopping(letGo: at)
            case (.stopping, .stopEnds): StopState.none
            case (.none, .carry), (.carried, .carry): .carried(since: at)
            case (.carried, .joined): StopState.none
            // A carried reply is never taken back or matched to a line; `stopEnds` and `carry` come only after `stopBegins`,
            // except a second Stop's on a reply the first one carried, which leaves it carried.
            default: nil
            }
        }
    }

    /// A watch's receipt, and with `StopState` all of where a watched reply stands: followed while the agent hasn't read
    /// it, then kept `kept` for a phone that was away. One with no word for `patience` expires: it is left out of
    /// `receipts` and no longer looked for.
    enum Following: Hashable {
        case open(ReplyReceipt.Stage)
        case settled(ReplyReceipt.Stage)
        case expired(ReplyReceipt.Stage)

        init(_ stage: ReplyReceipt.Stage) { self = [.typed, .held].contains(stage) ? .open(stage) : .settled(stage) }

        enum Event: Hashable {
            case stage(ReplyReceipt.Stage)
            case expire
        }

        func next(_ event: Event) -> Following? {
            switch (self, event) {
            case (.open(let stage), .stage(let to)): stage == to ? nil : Following(to)
            case (.open(let stage), .expire): .expired(stage)
            // Only Codex's app server, by id, moves one that went unsent: what a stop took back, sent again.
            case (.settled(.unsent), .stage(let to)) where to != .unsent && to != .typed: Following(to)
            case (.settled, _): nil
            // No longer followed, so a late word changes nothing: settled, it would still be left out of `receipts`.
            case (.expired, _): nil
            }
        }
    }

    /// What a Stop found in the prompt after Esc, for the replies it was taking back, oldest first.
    enum TakeBack: Equatable {
        /// The replies from `from` on were all the prompt held, and it was cleared; earlier ones weren't there.
        case cleared(from: Int)
        /// Something Side A can't tell for the phone's alone: left as it was.
        case left
        /// Nothing came back.
        case absent
    }

    /// A settled receipt stays this long, for a phone that was away when it settled.
    static let kept: Double = 300
    /// As on the app server: a Codex turn that ended without the message, with no other starting, won't take it.
    static let unseen: Double = 30
    /// A transcript that stops saying anything (its format changed, say) isn't read for ever.
    static let patience: Double = 3600
    /// Interrupt and Send's message comes right after the stop; without it, what the stop took back goes back.
    static let carry: Double = InterruptTiming.carried

    private weak var store: AccountStore?
    private var watches: [String: Watch] = [:]
    /// Each transcript is read once per pass, from where the last pass ended.
    private var cursors: [URL: UInt64] = [:]
    /// Claude's `remove` lines still owed their `queued_command` echo, by transcript.
    private var echoes: [URL: [(text: String, at: Double)]] = [:]
    private var polling: Task<Void, Never>?
    /// One pass at a time: two reading the same lines would give one line to two replies.
    private var scanning: Task<Bool, Never>?

    init(store: AccountStore?) { self.store = store }

    /// Before typing, so that only what the transcript records after it counts. False when there is nothing to follow.
    /// `asked`: the reply's own words when `text` is the prompt it goes in with others.
    /// A session just started or continued may have no id or transcript yet: it is followed all the same, for retries and
    /// for a Stop, and its transcript is read from when it appears.
    @discardableResult func expect(_ key: String?, text: String, asked: String? = nil, live: LiveSession, delivery: ReplyResult.Delivery = .typed) -> Bool {
        guard let key else { return false }
        let transcript = live.sessionID.flatMap { transcript(live, id: $0) }
        let now = Date().timeIntervalSince1970
        watch(key, Watch(pid: live.pid, hosted: live.hosted, agent: live.provider, text: text, asked: asked ?? text, transcript: transcript,
                         start: transcript.map(Self.size) ?? 0, since: now, receipt: ReplyReceipt(id: ReplyReceipt.family(key), stage: .typed, at: now),
                         delivery: delivery))
        return true
    }

    /// A hosted pane whose session the live list doesn't show yet: followed by the pane's name until it does.
    func expect(_ key: String?, text: String, asked: String? = nil, hosted name: String, agent: AgentProvider, delivery: ReplyResult.Delivery = .typed) {
        guard let key else { return }
        let now = Date().timeIntervalSince1970
        watch(key, Watch(pid: nil, hosted: name, agent: agent, text: text, asked: asked ?? text, transcript: nil, start: 0, since: now,
                         receipt: ReplyReceipt(id: ReplyReceipt.family(key), stage: .typed, at: now), delivery: delivery))
    }

    nonisolated private static func size(_ file: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// A transcript that appeared after its reply was typed holds nothing older than it; one that was there all along but
    /// unnamed is read only from now, so an older line can't settle it.
    private func bindTranscripts() {
        for (key, watch) in watches where watch.open && (watch.pid == nil || watch.transcript == nil && watch.client == nil) {
            guard let live = store?.sessions.live.first(where: { live in watch.pid.map { live.pid == $0 } ?? (live.hosted == watch.hosted) }) else { continue }
            if watch.pid == nil {
                watches[key]?.pid = live.pid
                changed()
            }
            guard watch.transcript == nil, watch.client == nil, let id = live.sessionID, let file = transcript(live, id: id) else { continue }
            let created = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
            watches[key]?.transcript = file
            watches[key]?.start = created >= watch.since - 2 ? 0 : Self.size(file)
        }
    }

    /// Before Codex's app server is asked, under the `clientUserMessageId` its items will carry.
    func expect(_ key: String?, text: String, asked: String? = nil, live: LiveSession, client: String, delivery: ReplyResult.Delivery) {
        guard let key else { return }
        let now = Date().timeIntervalSince1970
        watch(key, Watch(pid: live.pid, hosted: nil, agent: .codex, text: text, asked: asked ?? text, transcript: nil, start: 0, since: now,
                         receipt: ReplyReceipt(id: ReplyReceipt.family(key), stage: .typed, at: now),
                         delivery: delivery, client: client))
    }

    private func transcript(_ live: LiveSession, id: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch live.provider {
        case .claude: return AgentActivity.transcript(projects: home.appendingPathComponent(".claude/projects"), cwd: live.cwd, id: id)
        case .codex:
            let codexHome = store?.remote.codex.home(of: live).map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            return CodexInputEvidence.rollout(sessions: codexHome.appendingPathComponent("sessions"), id: id)
        }
    }

    private func stop(_ key: String, _ event: StopState.Event, at: Double = Date().timeIntervalSince1970) {
        if let next = watches[key]?.stop.next(event, at: at) { watches[key]?.stop = next }
    }

    private func watch(_ key: String, _ watch: Watch) {
        watches[ReplyReceipt.family(key)] = watch
        changed()
        follow()
    }

    /// An attempt under this key's family went in and is still followed: a retry of it is answered from that attempt.
    func follows(_ key: String?) -> Bool {
        guard let key, let watch = watches[ReplyReceipt.family(key)] else { return false }
        return watch.receipt.stage != .unsent
    }

    /// Typing failed, and the reply's answer says so.
    func forget(_ key: String?) {
        guard let key, watches.removeValue(forKey: ReplyReceipt.family(key)) != nil else { return }
        changed()
    }

    /// An earlier attempt of this reply went in: a retry after a lost answer is answered from it, never sent again. Only
    /// when it says the same: other words under that key are another message, which an answer from this one would swallow.
    /// A retry under the first attempt's very key never gets here; the server's idempotency record replays it.
    func answer(_ key: String?, text: String) -> ReplyResult.Delivery? {
        guard let key, !ReplyReceipt.types(key, typed: Set(watches.filter { $0.value.receipt.stage != .unsent }.keys)),
              let watch = watches[ReplyReceipt.family(key)], watch.asked == text else { return nil }
        return watch.delivery
    }

    /// Interrupt and Send types a reply in one prompt with others, so the record shows that prompt, not the reply.
    func typed(_ key: String?) -> String? {
        key.flatMap { watches[ReplyReceipt.family($0)]?.text }
    }

    struct Turn: Equatable {
        let id: String
        let text: String
        let at: Double
    }

    /// Read synchronously: the moved-on check is one main-actor step and can't wait for the next pass.
    func turn(_ live: LiveSession) -> Turn? {
        guard let id = live.sessionID, let file = transcript(live, id: id) else { return nil }
        return Self.newest(file, agent: live.provider)
    }

    /// A turn that began before the last 512 KB can't be told from another's, so it is none.
    nonisolated static func newest(_ file: URL, agent: AgentProvider) -> Turn? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let from = size > 512 << 10 ? size - (512 << 10) : 0
        guard (try? handle.seek(toOffset: from)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if from > 0, !lines.isEmpty { lines.removeFirst() }
        var prompt: String?
        for line in lines.reversed() {
            switch agent {
            case .claude:
                if let turn = ClaudeQueueEvidence.turn(line) { return Turn(id: turn.id, text: turn.text, at: turn.at) }
            case .codex:
                // Walking back, the last prompt seen before `task_started` is the turn's first.
                if let started = CodexInputEvidence.started(line) { return Turn(id: started.id, text: prompt ?? "", at: started.at) }
                if let words = CodexInputEvidence.prompt(line) { prompt = words }
            }
        }
        return nil
    }

    /// Codex's app server on a message it was sent: `held` in the running turn, `read` as a user item, or dropped.
    func codex(client: String, _ stage: ReplyReceipt.Stage, reason: String? = nil) {
        for (key, watch) in watches where watch.client == client && watch.receipt.stage != .read { settle(key, stage, reason: reason) }
    }

    /// Sent again after an interrupt, under the id of the turn that carries it now.
    func codex(client: String, becomes next: String) {
        for (key, watch) in watches where watch.client == client { watches[key]?.client = next }
    }

    /// The pane's own check found this reply wasn't submitted; the transcript, when it has spoken, knows better.
    func unsent(_ key: String, reason: String) {
        let key = ReplyReceipt.family(key)
        Task {
            // A dialog that opens right after Claude queued it also reads as unsent on screen.
            _ = await scan()
            guard watches[key]?.state == .open(.typed) else { return }
            settle(key, .unsent, reason: reason, batch: true)
        }
    }

    // MARK: Stop

    /// Before an Esc in a hosted pane: the phone's replies the agent hasn't read, oldest first, for the Stop to take back.
    /// One sent to wait for the turn (Codex's Tab) isn't the step's, and stays.
    func stopping(hosted name: String) async -> [(key: String, text: String)] {
        _ = await scan()
        let open = watches.filter { $0.value.hosted == name && $0.value.open && $0.value.carried == nil && $0.value.delivery != .queued }
            .sorted { $0.value.since < $1.value.since }
        for (key, _) in open { stop(key, .stopBegins) }
        return open.map { ($0.key, $0.value.text) }
    }

    /// What the Stop came to for `keys` (from `stopping`). A plain Stop gives back what it cleared from the prompt;
    /// Interrupt and Send (`carry`) keeps it for the message that follows. Nil: Esc never went.
    func stopped(_ keys: [String], _ outcome: TakeBack?, carry: Bool) async {
        // The "let go" lines Claude wrote while the Stop looked are read first, or the next pass would settle them as
        // let go once `stopping` is off.
        _ = await scan()
        let now = Date().timeIntervalSince1970
        for (index, key) in keys.enumerated() {
            let letGo = watches[key]?.letGo
            stop(key, .stopEnds)
            guard let watch = watches[key], watch.open else { continue }
            switch outcome {
            case .cleared(let from) where index >= from:
                if carry { stop(key, .carry, at: now); changed() } else { settle(key, .unsent, reason: ReplyReceipt.stopped(agent: watch.agent)) }
            case .left:
                settle(key, .unsent, reason: "The stop put it back in \(watch.agent.title)'s prompt on the Mac, unsent.")
            // Nothing in the prompt: the transcript's own word, held back while the Stop looked, decides.
            default:
                if let letGo { settle(key, .unsent, at: letGo, reason: Self.letGo, batch: true) }
            }
        }
    }

    /// Interrupt and Send's message is typed after what its stop took back, as one prompt: those replies, oldest first.
    func carried(hosted name: String) -> [(key: String, text: String)] {
        watches.filter { $0.value.hosted == name && $0.value.carried != nil && $0.value.open }.sorted { $0.value.since < $1.value.since }
            .map { ($0.key, $0.value.text) }
    }

    /// Before typing `text`, the one prompt `keys` go in with the reply under `key`.
    func join(_ keys: [String], with key: String?, text: String) {
        guard !keys.isEmpty else { return }
        let batch = key.map(ReplyReceipt.family) ?? UUID().uuidString
        if watches[batch] != nil { watches[batch]?.batch = batch; watches[batch]?.text = text }
        for key in keys where watches[key] != nil {
            stop(key, .joined)
            watches[key]?.text = text
            watches[key]?.batch = batch
            settle(key, .typed)
        }
    }

    /// The prompt they were to go in wasn't typed: back to the phone, as a plain Stop would have given them.
    func release(_ keys: [String]) {
        for key in keys { if let watch = watches[key], watch.open { settle(key, .unsent, reason: ReplyReceipt.stopped(agent: watch.agent)) } }
    }

    private static let letGo = "Claude let go of it unread."

    /// A queued Codex reply is left out until it settles: the phone shows it after this turn, and `held` would say sooner.
    func receipts(_ live: LiveSession) -> [ReplyReceipt]? {
        let rows = watches.values.filter { $0.pid == live.pid && $0.expired == nil && !($0.delivery == .queued && $0.open) }
            .map(\.receipt).sorted { $0.at < $1.at }
        return rows.isEmpty ? nil : rows
    }

    /// `batch`: every reply typed in the same prompt goes with it.
    private func settle(_ key: String, _ stage: ReplyReceipt.Stage, at: Double = Date().timeIntervalSince1970, reason: String? = nil, batch: Bool = false) {
        let keys = batch ? watches[key]?.batch.map { group in watches.filter { $0.value.batch == group }.map(\.key) } ?? [key] : [key]
        for key in keys {
            guard let watch = watches[key], watch.state.next(.stage(stage)) != nil else { continue }
            watches[key]?.receipt = ReplyReceipt(id: key, stage: stage, at: at, reason: reason)
            RemoteLog.shared("receipts: \(key.prefix(8)) \(stage.rawValue) in \(watch.pid.map { "pid \($0)" } ?? watch.hosted ?? "?")")
        }
        changed()
    }

    private func changed() { store?.remote.events?.liveChanged() }

    private func follow() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled, let self, await self.scan() {
                try? await Task.sleep(for: .seconds(1))
            }
            self?.polling = nil
        }
    }

    /// One look at every unsettled reply's record; false once nothing is left to follow.
    private func scan() async -> Bool {
        if let scanning { return await scanning.value }
        let pass = Task { await self.pass() }
        scanning = pass
        defer { scanning = nil }
        return await pass.value
    }

    private func pass() async -> Bool {
        let now = Date().timeIntervalSince1970
        bindTranscripts()
        let alive = Set(store?.sessions.live.map(\.pid) ?? [])
        let panes = Set(store?.hosted.sessions.map(\.name) ?? [])
        for (key, watch) in watches {
            if !watch.open {
                if now - (watch.expired ?? watch.receipt.at) > Self.kept { watches[key] = nil; changed() }
                continue
            }
            if watch.pid.map({ !alive.contains($0) }) ?? !panes.contains(watch.hosted ?? "") {
                settle(key, .unsent, reason: "The session ended before \(watch.agent.title) read it.")
            } else if let carried = watch.carried, now - carried > Self.carry {
                settle(key, .unsent, reason: ReplyReceipt.stopped(agent: watch.agent))
            } else if now - watch.since > Self.patience, watch.state.next(.expire) != nil {
                watches[key]?.expired = now
                RemoteLog.shared("receipts: \(key.prefix(8)) no word in an hour, no longer followed")
                changed()
            }
        }
        let files = Set(watches.values.filter(\.open).compactMap(\.transcript))
        cursors = cursors.filter { files.contains($0.key) }
        echoes = echoes.filter { files.contains($0.key) }
        for file in files {
            let from = cursors[file] ?? watches.values.filter { $0.open && $0.transcript == file }.map(\.start).min() ?? 0
            let (lines, end) = await Task.detached { Self.lines(file, from: from) }.value
            cursors[file] = end
            let agent = watches.values.first { $0.transcript == file }?.agent
            for (offset, line) in lines {
                if agent == .codex {
                    if let event = CodexInputEvidence.event(line) { codex(event, at: offset, in: file) }
                } else if let event = ClaudeQueueEvidence.event(line) {
                    claude(event, at: offset, in: file)
                }
            }
        }
        for (key, watch) in watches where watch.open {
            if let ended = watch.ended, now - ended.at > Self.unseen, watch.receipt.stage == .typed {
                settle(key, .unsent, reason: ended.interrupted
                    ? "The interrupt stopped Codex before it read it. It may be back in Codex's prompt on the Mac."
                    : "Codex finished its turn without reading it.")
            }
        }
        return !watches.isEmpty
    }

    /// The oldest reply in `stages` that this line, at `offset` of `file`, can be about.
    private func owner(of text: String, at offset: UInt64, in file: URL, _ stages: Set<ReplyReceipt.Stage>, letGo: Bool = false,
                       match: (String, String) -> ClaudeQueueEvidence.Match?) -> String? {
        var best: (key: String, since: Double)?
        for (key, watch) in watches where watch.transcript == file && watch.start <= offset && watch.open && watch.carried == nil {
            // One whose letting go is already held back has had its line.
            guard stages.contains(watch.receipt.stage), !(letGo && watch.letGo != nil), match(text, watch.text) != nil else { continue }
            if let best, best.since <= watch.since { continue }
            best = (key, watch.since)
        }
        return best?.key
    }

    private func claude(_ event: ClaudeQueueEvidence.Event, at offset: UInt64, in file: URL) {
        let match = ClaudeQueueEvidence.match
        switch event {
        case .held(let text, let at):
            if let key = owner(of: text, at: offset, in: file, [.typed], match: match) { settle(key, .held, at: at, batch: true) }
        case .read(let text, let at, let from):
            echoes[file]?.removeAll { at - $0.at > 60 }
            if from == .attachment, let echo = echoes[file]?.firstIndex(where: { match(text, $0.text) != nil }) {
                echoes[file]?.remove(at: echo)
                return
            }
            if from == .removed { echoes[file, default: []].append((text, at)) }
            if let key = owner(of: text, at: offset, in: file, [.typed, .held], match: match) { settle(key, .read, at: at, batch: true) }
        case .letGo(let text, let at):
            // Esc during a Stop lets go of what it puts back in the prompt; the Stop says what came of it, and this line
            // waits for it: the cursor is past it already, so it can't be read again.
            guard let key = owner(of: text, at: offset, in: file, [.typed, .held], letGo: true, match: match) else { return }
            if case .stopping? = watches[key]?.stop {
                stop(key, .letGo, at: at)
                return
            }
            settle(key, .unsent, at: at, reason: Self.letGo, batch: true)
        }
    }

    private func codex(_ event: CodexInputEvidence.Event, at offset: UInt64, in file: URL) {
        switch event {
        case .read(let text, let at):
            guard let key = owner(of: text, at: offset, in: file, [.typed, .held], match: CodexInputEvidence.match) else { return }
            watches[key]?.ended = nil
            settle(key, .read, at: at, batch: true)
        case .ended, .started:
            for (key, watch) in watches where watch.transcript == file && watch.start <= offset && watch.open {
                if case .ended(let at, let interrupted) = event { watches[key]?.ended = (at, interrupted) } else { watches[key]?.ended = nil }
            }
        }
    }

    /// The whole lines written after `offset`, each with where it starts, and where they end.
    nonisolated private static func lines(_ url: URL, from offset: UInt64) -> ([(UInt64, Substring)], UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(),
              let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], offset) }
        let text = String(decoding: data[...end], as: UTF8.self)
        var lines: [(UInt64, Substring)] = [], at = offset
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            if !line.isEmpty { lines.append((at, line)) }
            at += UInt64(line.utf8.count + 1)
        }
        return (lines, offset + UInt64(end - data.startIndex + 1))
    }
}
