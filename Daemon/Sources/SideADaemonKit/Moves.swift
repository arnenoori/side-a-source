import Crypto
import Foundation
import SideACore
import SideAProtocol

/// Sends hosted sessions to another of the user's computers and receives them (docs/moving-sessions-prd.md), as the
/// Mac's `Moves` does, which this ports. The files are the bridge's work (`bridge/move.py`), the order of events is
/// `MoveJournal`'s, and this actor stops and starts the hosted sessions, carries the files, and writes the journal down
/// before each step the other computer could act on. The rule both sides keep: the receiver starts a conversation only
/// on `commit`, once, never after `abort`; the sender starts it again only on the receiver's word that it did not.
actor DaemonMoves {
    struct Places: Sendable {
        /// The bridge's `--root` (the state folder's `root`), which also holds the move's working files.
        var root: URL
        /// Where a repository this computer does not have yet is cloned.
        var landing: URL
        /// Folders to look for the repository in, besides the ones sessions here have run in.
        var repositories: [String]
        /// What the bridge, git and the agents run with.
        var environment: [String: String]
    }

    /// Moves that did not happen, kept a while for whoever asked from another device.
    struct Failed: Sendable { let entry: MoveJournal.Entry?; let message: String; let at: Double }

    static let chunk = 512 << 10
    /// What one part may grow to here: the bridge's own limits on a bundle and a conversation are 2 GB each.
    static let maxPart = 4 << 30
    static let partNames: Set<String> = ["manifest.json", "conversation.json", "workspace.bundle", "conversation.tar", "extras.tar"]

    let places: Places
    let engine: SessionEngine
    let links: ComputerLinks
    let logins: DaemonLogins
    let location: BridgeLocation
    let store: any SecretStore
    private let journalRecord: JSONRecord<MoveJournal>
    private let incomingRecord: JSONRecord<[String: Incoming]>
    let keptRecord: JSONRecord<[String: Kept]>
    let sentRecord: JSONRecord<Sent>
    /// The journal on disk could not be read: nothing moves, so nothing it says is forgotten.
    private let unreadable: Bool
    private(set) var journal = MoveJournal()
    var incoming: [String: Incoming] = [:]
    var received: [String: [String: Int]] = [:]
    var failures: [String: Failed] = [:]
    /// Moves this process is carrying now, which `settle` leaves alone.
    var inFlight: Set<String> = []
    /// Conversations a move has been agreed for and not finished: no second move of one starts meanwhile.
    var claimed: Set<String> = []
    /// Arriving moves whose session this process is starting now.
    var starting: Set<String> = []
    /// Moves a phone started that the journal does not hold yet.
    var sending: [String: MoveRecord] = [:]
    /// Standby, as the computer sessions run on: what was last sent of each conversation and where, and the computers
    /// still to be told to delete what this one sent them.
    var sent = Sent()
    /// Conversations a checkpoint is being taken of now.
    var checkpointing: Set<String> = []
    /// Standby, as the computer that keeps them: other computers' checkpoints, by checkpoint id.
    var kept: [String: Kept] = [:]
    /// Conversations a copy of is being started here now.
    var copying: Set<String> = []
    private(set) weak var daemon: SideADaemon?
    /// How a linked computer is reached; tests put a link that loses messages in front.
    var peerFor: @Sendable (LinkedComputer) -> any MovePeer = { LinkedPeer($0) }
    /// How long a stopped session gets to leave the process list.
    var patience = Duration.seconds(20)
    var clock: @Sendable () -> Double = { Date().timeIntervalSince1970 }
    /// How an arriving session is started; tests hold it to see a move while it is starting.
    var launch: @Sendable (HostedTmux.Start) async throws -> String

    init(places: Places, engine: SessionEngine, links: ComputerLinks, logins: DaemonLogins, location: BridgeLocation, store: any SecretStore) {
        self.places = places; self.engine = engine; self.links = links; self.logins = logins; self.location = location; self.store = store
        launch = { [tmux = engine.tmux] in try await tmux.start($0) }
        journalRecord = JSONRecord(store: store, name: "moves.json")
        incomingRecord = JSONRecord(store: store, name: "moves-incoming.json")
        keptRecord = JSONRecord(store: store, name: "standby-kept.json")
        sentRecord = JSONRecord(store: store, name: "standby-sent.json")
        var unreadable = false, loaded = MoveJournal()
        do { loaded = try journalRecord.load(default: MoveJournal()) } catch { unreadable = true }
        self.unreadable = unreadable
        journal = loaded
        let arriving = (try? incomingRecord.load(default: [:])) ?? [:]
        incoming = arriving.filter { [.staging, .staged, .starting, .live].contains(loaded[$0.key]?.step) }
        sent = (try? sentRecord.load(default: Sent())) ?? Sent()
        kept = Self.keptAtStart(keptRecord, folder: places.root.appendingPathComponent("runtime/moves/standby"))
    }

    func attach(_ daemon: SideADaemon) { self.daemon = daemon }

    func set(peers: @escaping @Sendable (LinkedComputer) -> any MovePeer) { peerFor = peers }
    func set(patience: Duration) { self.patience = patience }
    func set(launch: @escaping @Sendable (HostedTmux.Start) async throws -> String) { self.launch = launch }
    func set(clock: @escaping @Sendable () -> Double) { self.clock = clock }

    /// The switches `sidead config` sets, read now.
    func settings() -> MoveSettings { MoveSettings.load(store) }

    /// `sidead config KEY VALUE`. Pointing Standby elsewhere, or turning it off, is acted on by the next pass.
    func configure(_ key: String, _ value: String) async throws -> MoveSettings {
        let next = try settings().changed(key, to: value, computers: await links.all)
        try MoveSettings.save(next, to: store)
        return next
    }

    var folder: URL { places.root.appendingPathComponent("runtime/moves") }
    var away: URL { folder.appendingPathComponent("away") }
    func now() -> Double { clock() }

    func me() -> MacInfo { daemon?.me ?? MacInfo(id: "", name: "This computer", os: .linux, headless: true) }

    /// Changes the journal and writes it down. A step is not taken until its record is on disk.
    @discardableResult
    func record<T>(_ change: (inout MoveJournal) -> T) throws -> T {
        guard !unreadable else { throw MoveFailure.refused("\(me().name) couldn't read its record of moves. Check the state folder's permissions.") }
        var next = journal
        let result = change(&next)
        try journalRecord.save(next)
        journal = next
        return result
    }

    /// Records a step on a path that must go on to its end whether or not the disk took the record.
    func note(_ change: (inout MoveJournal) -> Void) {
        do { try record(change) } catch {
            change(&journal)
            DaemonLog.line("couldn't save the move journal: \(error)")
        }
    }

    func saveIncoming() {
        do { try incomingRecord.save(incoming) } catch { DaemonLog.line("couldn't save the moves being received: \(error)") }
    }

    /// One request to `bridge/move.py`, as JSON on standard input. A refusal is thrown with the sentence the bridge gave.
    func ask(_ request: [String: Any]) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: request)
        let run = await Run.process(location.python, [location.script, "--root", places.root.path, "move"], environment: places.environment,
                                    input: input, timeout: 600)
        guard run.status == 0 else { throw BridgeFailure(message: "The move couldn't be prepared on \(me().name) (the bridge stopped with \(run.status)).") }
        let answer = (try? JSONSerialization.jsonObject(with: Data(run.output.utf8))) as? [String: Any] ?? [:]
        if let refused = answer["refused"] as? String { throw MoveFailure.refused(refused) }
        return answer
    }

    func ownership(of conversation: String) -> MoveJournal.Ownership { journal.ownership(of: conversation) }

    /// The computer a conversation is on, or on its way to or from, when it may not run here.
    func elsewhere(_ conversation: String) -> (id: String, name: String)? {
        guard !journal.ownership(of: conversation).mayRun, let entry = journal.open(for: conversation) else { return nil }
        return (entry.peer, entry.peerName)
    }

    func movable() async -> Bool { await links.any }

    // MARK: Sending

    /// Why this session cannot be moved right now, or nil.
    static func refusal(_ row: LiveRow) -> String? {
        guard row.hosted != nil else { return "Only sessions Side A hosts can move." }
        guard row.id != nil, row.cwd != nil else { return "That session has no conversation to move yet." }
        guard row.status == "idle" else { return "It's working. Move it when it has finished its turn." }
        return nil
    }

    /// A move both computers have agreed to and nothing has been stopped for.
    struct Plan: Sendable {
        let row: LiveRow
        let conversation: String
        let cwd: String
        let name: String
        let agent: Hosting.Agent
        let offer: MoveOffer
        let answer: MoveAnswer
        let account: String?
        /// The account the pane was started on, to start it there again if it stays.
        let slot: String?
        /// The account's login goes with the session.
        let hands: Bool
        /// The move it arrived here under, when its agent has exited since: nothing is stopped (Moves+Ended.swift).
        var ended: String?
    }

    /// Checks the session and asks `peer` whether it will take it. Nothing is stopped. The offer stays open on the
    /// other computer until `run` or `withdraw`.
    func prepare(_ row: LiveRow, to peer: any MovePeer) async throws -> Plan {
        let ended = try await endedArrival(of: row)
        let row = ended?.row ?? row
        if let refusal = Self.refusal(row) { throw MoveFailure.refused(refusal) }
        // A stand-in whose arrival has since run again or moved on names no process to stop.
        guard ended != nil || row.pid > 0 else { throw MoveFailure.refused("That session isn't running on \(me().name).") }
        guard let conversation = row.id, let cwd = row.cwd, let name = row.hosted else { throw MoveFailure.refused("That session can't move.") }
        // Checked and claimed in one step, before anything is awaited, so two moves of one session can't both go on.
        guard journal.ownership(of: conversation).mayRun, claimed.insert(conversation).inserted else {
            throw MoveFailure.refused("That session is already moving.")
        }
        do {
            return try await agree(row, conversation: conversation, cwd: cwd, name: name, with: peer, ended: ended?.id)
        } catch {
            claimed.remove(conversation)
            throw error
        }
    }

    private func agree(_ row: LiveRow, conversation: String, cwd: String, name: String, with peer: any MovePeer, ended: String?) async throws -> Plan {
        let agent: Hosting.Agent = row.agent == .codex ? .codex : .claude
        let checked = try await ask(["action": "inspect", "folder": cwd])
        if let first = (checked["refusals"] as? [String])?.first { throw MoveFailure.refused(first) }
        let id = "mv-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
        let project = URL(fileURLWithPath: checked["top"] as? String ?? cwd).lastPathComponent
        var slot = await engine.tmux.account(of: name)
        if slot == nil, let ended { slot = arrivalSlot(ended) }
        let account = logins.account(of: row.agent, slot: slot)
        let offer = MoveOffer(id: id, conversationID: conversation, agent: row.agent, project: Self.slug(project), title: row.title ?? row.name,
                              commits: checked["candidates"] as? [String] ?? [], model: row.model, effort: row.effort,
                              permissionMode: row.mode.map(PermissionMode.init(rawValue:)), from: me(), account: account?.wire)
        let answer = try await refusing { try await peer.offer(offer) }
        var hands = false
        if let account, answer.account == .wanted || answer.account == .missing {
            let staying = logins.staying(account.id, agent: row.agent, besides: row.pid)
            hands = staying == nil
            if let staying, answer.account == .missing {
                _ = try? await peer.abort(id)
                throw MoveFailure.refused("\(peer.name) isn't signed in to \(row.agent.title), and \(staying).")
            }
        }
        return Plan(row: row, conversation: conversation, cwd: cwd, name: name, agent: agent, offer: offer, answer: answer, account: account?.id,
                    slot: slot, hands: hands, ended: ended)
    }

    /// Tells the other computer a prepared move will not happen.
    func withdraw(_ plan: Plan, from peer: any MovePeer) async {
        claimed.remove(plan.conversation)
        _ = try? await peer.abort(plan.offer.id)
    }

    /// Moves a hosted, idle session to `peer`. Returns once it runs there. Throws `refused` when nothing moved (the
    /// session runs here again if it was stopped) and `unknown` when the other computer did not answer the request to
    /// start it.
    func run(_ plan: Plan, to peer: any MovePeer) async throws -> MoveState {
        let id = plan.offer.id
        inFlight.insert(id)
        defer { inFlight.remove(id); claimed.remove(plan.conversation); sending[id] = nil }
        do {
            return try await carry(plan, to: peer)
        } catch {
            if case MoveFailure.refused(let message) = error { failures[id] = Failed(entry: journal[id], message: message, at: now()) }
            throw error
        }
    }

    private func carry(_ plan: Plan, to peer: any MovePeer) async throws -> MoveState {
        let id = plan.offer.id, row = plan.row, agent = plan.agent
        do {
            var entry = MoveJournal.Entry(id: id, role: .source, session: plan.conversation, agent: agent.rawValue, peer: peer.id, peerName: peer.name,
                                          step: .prepared, at: now(), folder: plan.cwd, name: plan.name)
            entry.ended = plan.ended
            try record {
                $0.begin(entry)
                $0.describe(id, title: plan.offer.title, project: plan.offer.project)
            }
            if plan.ended != nil {
                try await stillEnded(plan)
            } else {
                // It was idle when the move was agreed; a turn started since then is not cut off.
                guard (await engine.live()).first(where: { $0.pid == row.pid })?.status ?? "idle" == "idle" else {
                    throw MoveFailure.refused("It started working. Move it when it has finished its turn.")
                }
                _ = await engine.tmux.end(plan.name)
                guard await gone(row) else { throw MoveFailure.refused("It didn't quit, so it's still running here.") }
                await engine.refresh(force: true)
            }
            try record { $0.advance(id, to: .held, at: now()) }
        } catch {
            note { $0.returned(id, at: now()) }
            _ = try? await peer.abort(id)
            throw MoveFailure.refused(Self.sentence(error, peer: nil))
        }
        var login: MoveLogin?
        do {
            let work = folder.appendingPathComponent(id)
            defer { try? FileManager.default.removeItem(at: work) }
            let parts = try await pack(id: id, agent: agent, conversation: plan.conversation, cwd: plan.cwd, have: plan.answer.have, slot: plan.slot, into: work)
            for part in parts { try await upload(part, from: work, move: id, to: peer) }
            let staged = try await peer.stage(id, MoveStage(parts: parts))
            guard staged.status == .staged else { throw MoveFailure.refused("\(peer.name) didn't accept the session.") }
            try record { $0.advance(id, to: .sent, at: now()) }
            // The login leaves its folder only now, when the other computer holds everything else and has checked it.
            if plan.hands, let account = plan.account {
                // Asked again now: minutes may have passed since the move was agreed.
                if let staying = logins.staying(account, agent: row.agent, besides: row.pid) {
                    if plan.answer.account == .missing { throw MoveFailure.refused("\(peer.name) isn't signed in to \(row.agent.title), and \(staying).") }
                } else {
                    try record { $0.carry(id, login: account) }
                    do { login = try logins.hold(account, agent: row.agent) } catch {
                        // Whatever a failed hold left aside goes back into its folder before the record is cleared.
                        logins.restore(account)
                        note { $0.carry(id, login: nil) }
                        if plan.answer.account == .missing { throw error }
                    }
                }
            }
            try record { $0.advance(id, to: .committing, at: now()) }
        } catch {
            // Nothing asked so far can start the session there, so it starts here again whatever went wrong.
            _ = try? await peer.abort(id)
            await comeBack(id, plan: plan)
            throw MoveFailure.refused(Self.sentence(error, peer: peer.name))
        }
        do {
            let state = try await peer.commit(id, MoveCommit(login: login))
            // Starting there and not yet known to run: neither a yes nor a no, so it is asked again later.
            if state.status == .starting { throw PeerFailure.noAnswer }
            guard state.status == .live else { throw MoveFailure.refused("\(peer.name) didn't start the session.") }
            note { $0.runs(id, in: state.session) }
            handed(id, stored: state.account != nil)
            await left(id, agent: agent, conversation: plan.conversation, cwd: plan.cwd)
            return state
        } catch let failure as MoveFailure {
            // The other computer's own word that it did not start.
            _ = try? await peer.abort(id)
            await comeBack(id, plan: plan)
            throw failure
        } catch {
            note { $0.advance(id, to: .unknown, at: now()) }
            throw MoveFailure.unknown(peer: peer.name)
        }
    }

    /// The other computer started the session: the login that went with it is deleted here if it is stored there, and
    /// put back if it is not.
    private func handed(_ id: String, stored: Bool) {
        guard let account = journal[id]?.login else { return }
        if stored { logins.release(account) } else { logins.restore(account) }
        note { $0.carry(id, login: nil) }
    }

    /// The session stays here: a login taken out of use for the move goes back.
    private func kept(_ id: String) {
        guard let account = journal[id]?.login else { return }
        logins.restore(account)
        note { $0.carry(id, login: nil) }
    }

    /// The `projects` folder a Claude conversation is filed in here: the account's own first, then any other.
    func filed(_ conversation: String, slot: String?) -> URL {
        let candidates = logins.allProjects(first: slot)
        return candidates.first { Self.holds($0, conversation) } ?? candidates[0]
    }

    static func holds(_ projects: URL, _ conversation: String) -> Bool {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        return folders.contains { FileManager.default.fileExists(atPath: projects.appendingPathComponent("\($0)/\(conversation).jsonl").path) }
    }

    /// Captures the workspace and the conversation into `work` and says what is there to send. The project's ignored
    /// `.env` files go too when `sidead config include-env` is on.
    func pack(id: String, agent: Hosting.Agent, conversation: String, cwd: String, have: [String], slot: String?, into work: URL) async throws -> [MovePart] {
        var capture: [String: Any] = ["action": "capture", "folder": cwd, "move": id, "out": work.path, "have": have]
        if settings().includesEnv { capture["env"] = true }
        let manifest = try await ask(capture)
        let exported = try await ask(["action": "export", "agent": agent.rawValue, "session": conversation, "out": work.path, "folder": cwd,
                                      "projects": filed(conversation, slot: slot).path, "stores": logins.codexStores.map(\.path)])
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: work.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: exported, options: [.sortedKeys]).write(to: work.appendingPathComponent("conversation.json"))
        return try ["manifest.json", "conversation.json", "workspace.bundle", "conversation.tar", "extras.tar"].compactMap { name in
            let url = work.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return MovePart(name: name, sha256: try Self.sha256(url), size: try Self.size(url))
        }
    }

    private func upload(_ part: MovePart, from work: URL, move: String, to peer: any MovePeer) async throws {
        try await Self.pieces(of: part, from: work) { index, data in try await peer.part(move, part.name, index, data) }
    }

    /// A file in pieces of at most `chunk`, in order from 0; an empty file is one empty piece.
    static func pieces(of part: MovePart, from work: URL, _ send: (Int, Data) async throws -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: work.appendingPathComponent(part.name))
        defer { try? handle.close() }
        var index = 0
        while let data = try handle.read(upToCount: Self.chunk), !data.isEmpty {
            try await send(index, data)
            index += 1
        }
        if index == 0 { try await send(0, Data()) }
    }

    /// The session runs on the other computer: its transcript goes out of the CLI's reach here.
    private func left(_ id: String, agent: Hosting.Agent, conversation: String, cwd: String) async {
        note { $0.advance(id, to: .away, at: now()) }
        // If it arrived here from another computer, that arrival is over.
        for entry in journal.all where entry.session == conversation && entry.role == .destination && entry.step == .live {
            note { $0.ended(entry.id, at: now()) }
            incoming[entry.id] = nil
        }
        saveIncoming()
        let stores = logins.codexStores.map(\.path)
        for projects in agent == .claude ? logins.allProjects(first: nil) : [logins.projects(for: nil)] {
            guard agent == .codex || Self.holds(projects, conversation) else { continue }
            _ = try? await ask(["action": "park", "agent": agent.rawValue, "session": conversation, "away": away.path, "projects": projects.path, "stores": stores])
        }
        _ = try? await ask(["action": "release", "folder": cwd, "move": id])
        await clearEnded(conversation)
    }

    /// How a moved session is started here: resumed by id, on the model and effort it had, in a mode this computer allows.
    /// A standby's copy is a fork of it instead, under a new id.
    static func launch(_ agent: Hosting.Agent, cwd: String, conversation: String, model: String?, effort: String?, mode: String?, fork: Bool = false) -> HostedTmux.Start {
        let model = Hosting.safeOption(model) ? model : nil, effort = Hosting.safeOption(effort) ? effort : nil
        var start = HostedTmux.Start(agent: agent, cwd: cwd, mode: fork ? .fork(conversation) : .resume(conversation, model: model))
        var arguments: [String] = []
        if agent == .codex {
            // Nobody may be at the terminal to skip Codex's update prompt.
            arguments += ["-c", "check_for_update_on_startup=false"]
            if let effort { arguments += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        }
        arguments += Hosting.arguments(agent, start.mode)
        if agent == .claude, let effort { arguments += ["--effort", effort] }
        if let mode, let permission = Hosting.permissionArguments(agent, mode: mode) { arguments += permission }
        start.arguments = arguments
        start.origin = "move"
        return start
    }

    /// Starts the session here again after a move that did not happen, on the account and in the mode it had.
    private func comeBack(_ id: String, plan: Plan) async {
        kept(id)
        note { $0.returned(id, at: now()) }
        _ = try? await ask(["action": "release", "folder": plan.cwd, "move": id])
        // Nothing was running when it began, so nothing starts.
        guard plan.ended == nil else { return }
        var start = Self.launch(plan.agent, cwd: plan.cwd, conversation: plan.conversation, model: plan.row.model, effort: plan.row.effort, mode: plan.row.mode)
        start.environment = logins.seat(plan.slot)
        start.account = plan.slot.flatMap { $0.isEmpty ? nil : $0 }
        do { _ = try await engine.tmux.start(start) } catch { DaemonLog.line("move \(id): the session couldn't be started here again: \(error)") }
        await engine.refresh(force: true)
    }

    /// Finishes what a restart or a lost answer left open. Safe to call at any time: a move this process is carrying
    /// is left to it.
    func settle(only: String? = nil) async {
        if only == nil { await resolveStarting() }
        for entry in journal.all where entry.role == .source && !inFlight.contains(entry.id) && (only == nil || only == entry.id) {
            switch journal.recovery(entry.id) {
            case .nothing: continue
            case .rollBack:
                if let link = await links.computer(entry.peer) { _ = try? await peerFor(link).abort(entry.id) }
                await restore(entry)
            case .ask:
                if entry.step == .committing { note { $0.advance(entry.id, to: .unknown, at: now()) } }
                guard let link = await links.computer(entry.peer) else { continue }
                let peer = peerFor(link)
                guard var state = try? await peer.state(entry.id) else { continue }
                // Starting there right now: it may yet run or fail, so nothing is decided and nothing is dropped.
                if state.status == .starting { continue }
                if state.status != .live, let dropped = try? await peer.abort(entry.id) { state = dropped } else if state.status != .live { continue }
                if state.status == .starting { continue }
                let status = MoveJournal.PeerStatus(rawValue: state.status.rawValue) ?? .staged
                guard let here = try? record({ $0.settle(entry.id, peerSays: status, at: now()) }) else { continue }
                if here {
                    await restore(entry, recorded: true)
                } else if journal[entry.id]?.step == .away, let agent = Hosting.Agent(rawValue: entry.agent) {
                    note { $0.runs(entry.id, in: state.session) }
                    handed(entry.id, stored: state.account != nil)
                    await left(entry.id, agent: agent, conversation: entry.session, cwd: entry.folder ?? "")
                }
            }
        }
        if only == nil { await expire() }
    }

    /// Starts a journal entry's session here again, unless it is running already. One whose agent had exited before it
    /// left starts only when the person asks for it here (`ranHere`), as it ran on arrival.
    func restore(_ entry: MoveJournal.Entry, recorded: Bool = false, ranHere: Bool = false) async {
        let arrived = entry.ended.flatMap { incoming[$0] }
        let account = entry.login ?? arrived?.account.flatMap { $0.isEmpty || $0 == DaemonLogins.codex ? nil : $0 }
        kept(entry.id)
        if !recorded { note { $0.returned(entry.id, at: now()) } }
        if let folder = entry.folder { _ = try? await ask(["action": "release", "folder": folder, "move": entry.id]) }
        guard entry.ended == nil || ranHere, let cwd = entry.folder, let agent = Hosting.Agent(rawValue: entry.agent),
              !(await engine.live()).contains(where: { $0.id == entry.session }) else { return }
        var start = Self.launch(agent, cwd: cwd, conversation: entry.session, model: arrived?.offer.model, effort: arrived?.offer.effort, mode: arrived?.mode)
        start.environment = logins.seat(account)
        start.account = account
        do { _ = try await engine.tmux.start(start) } catch { DaemonLog.line("move \(entry.id): the session couldn't be started here again: \(error)") }
        await engine.refresh(force: true)
    }

    private func gone(_ row: LiveRow) async -> Bool {
        let end = ContinuousClock.now + patience
        while ContinuousClock.now < end {
            if !Self.alive(row.pid) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    static func alive(_ pid: Int) -> Bool { Run.running(pid) }

    /// Turns the other computer's "no" into a `refused`, and anything else (it couldn't be reached) too: nothing has
    /// been stopped yet.
    func refusing<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch let failure as MoveFailure { throw failure } catch { throw MoveFailure.refused(Self.sentence(error, peer: nil)) }
    }

    static func sentence(_ error: any Error, peer: String?) -> String {
        if let failure = error as? MoveFailure { return failure.description }
        if let hosted = error as? HostedTmux.Failure {
            switch hosted {
            case .refused(let message), .failed(let message): return message
            case .unavailable: return "Hosted sessions need tmux 3.4 or newer there."
            case .waiting: return "It's waiting for an answer on the screen."
            }
        }
        if let bridge = error as? BridgeFailure { return bridge.message }
        return peer.map { "\($0) couldn't be reached, so the session stayed here." } ?? "The other computer couldn't be reached."
    }

    static func slug(_ name: String) -> String {
        let slug = name.lowercased().unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "session" : String(slug.prefix(24)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// `path` with every link resolved, as `getcwd` reports it. Not `resolvingSymlinksInPath`, which on a Mac turns
    /// `/private/tmp` back into `/tmp`.
    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func size(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What `SessionServices` asks of moves: whether to offer the `move` ability, and where a conversation is when it is not
/// here. Set once the moves service exists, which needs the sessions first.
public final class MoveHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var moves: DaemonMoves?

    public init() {}

    func attach(_ moves: DaemonMoves) { lock.lock(); self.moves = moves; lock.unlock() }
    private var current: DaemonMoves? { lock.lock(); defer { lock.unlock() }; return moves }

    func movable() async -> Bool { await current?.movable() ?? false }
    func elsewhere(_ conversation: String) async -> (id: String, name: String)? { await current?.elsewhere(conversation) }

    /// A session finished a turn: a checkpoint of it may go to the standby. Not waited for, since the session list that
    /// says so is what the checkpoint reads.
    func turnEnded(_ conversation: String?) {
        guard let conversation, let moves = current else { return }
        Task { await moves.checkpointSoon(conversation) }
    }
}

extension HTTPResponse {
    /// 409 `moved`: the conversation is on another computer now; `details.host` names it.
    static func moved(to away: (id: String, name: String)) -> HTTPResponse {
        .apiError(409, .moved, "It's on \(away.name) now.", details: ["host": away.id])
    }
}

extension LiveBuilder {
    /// A hosted session that has finished its turn can go to a linked computer.
    static func offerMove(_ session: inout RemoteSession) {
        guard session.hosted != nil, session.conversationID != nil, session.cwd != nil, session.status == .idle else { return }
        session.abilities.insert(.move)
    }
}

extension SessionEngine {
    /// What is running now, read fresh.
    func live() async -> [LiveRow] {
        await refresh(force: true)
        return rows
    }

    /// A running session by its id, its conversation or its hosted name.
    func row(_ id: String) async -> LiveRow? {
        let rows = await live()
        return rows.first { $0.key == id } ?? rows.first { $0.id == id } ?? rows.first { $0.hosted == id }
    }
}

extension HostedTmux {
    /// The account a hosted session was started on (`@sidea_account`); empty for this computer's own login.
    func account(of name: String) async -> String? {
        let result = await run(["show-options", "-v", "-t", Self.target(name), "@sidea_account"], timeout: 5)
        guard result.status == 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension SideADaemon {
    /// A piece of a moved session or a checkpoint: the receiver accepts the same piece twice and ignores the second, so it
    /// is not kept in the idempotency ledger, which would otherwise hold a record for every half megabyte of a repository.
    static func idempotentByItself(_ request: HTTPRequest) -> Bool {
        request.method == "POST" && request.path.count == 6 && request.path[0] == "v1" && ["moves", "standby"].contains(request.path[1])
            && request.path[3] == "parts"
    }
}
