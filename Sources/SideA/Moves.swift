import CryptoKit
import Foundation
import SideACore
import SideAProtocol

/// Another computer running Side A, as a move talks to it. A `MoveFailure.refused` is the other computer's
/// answer; any other error means the request may or may not have arrived.
protocol MovePeer: Sendable {
    var id: String { get }
    var name: String { get }
    func offer(_ offer: MoveOffer) async throws -> MoveAnswer
    func part(_ move: String, _ name: String, _ index: Int, _ data: Data) async throws
    func stage(_ move: String, _ stage: MoveStage) async throws -> MoveState
    func commit(_ move: String, _ commit: MoveCommit) async throws -> MoveState
    func abort(_ move: String) async throws -> MoveState
    func state(_ move: String) async throws -> MoveState
}

enum MoveFailure: LocalizedError, Equatable {
    /// Nothing moved, and the session is running here as it was (or was never stopped).
    case refused(String)
    /// The other computer was asked to start the session and did not answer. It may be running there.
    case unknown(peer: String)

    var errorDescription: String? {
        switch self {
        case .refused(let message): message
        case .unknown(let peer): "\(peer) was asked to start the session and didn't answer. It may be running there."
        }
    }
}

/// Sends hosted sessions to another computer and receives them (docs/moving-sessions-prd.md).
///
/// The files are the bridge's work (`bridge/move.py`) and the order of events is `MoveJournal`'s. This class
/// stops and starts the hosted sessions, carries the files, and writes the journal down before each step that the
/// other computer could act on.
@MainActor @Observable
final class Moves {
    struct Places: Sendable {
        /// Claude Code's `projects` folder and the Codex `sessions` folders, as the CLIs on this computer read them.
        var claudeProjects: URL
        var codexStores: [URL]
        /// Where a repository this computer does not have yet is cloned.
        var landing: URL
        /// Folders to look for the repository in, besides the ones sessions here have run in.
        var repositories: [String] = []
    }

    /// The account a session runs on, so one that has to start here again starts on the same one.
    struct Seat: Sendable {
        var pin: String?
        var codexAccount: String?
    }

    static let chunk = 512 << 10
    static let partNames: Set<String> = ["manifest.json", "conversation.json", "workspace.bundle", "conversation.tar", "extras.tar"]

    let root: URL
    @ObservationIgnored let hosted: HostedSessions
    @ObservationIgnored let places: Places
    @ObservationIgnored let me: @MainActor () -> MacInfo
    @ObservationIgnored let bridge: @MainActor (Data) async throws -> Data
    @ObservationIgnored let live: @MainActor () async -> [LiveSession]?
    @ObservationIgnored var seat: @MainActor (LiveSession) -> Seat = { _ in Seat() }
    @ObservationIgnored var peer: @MainActor (String) -> (any MovePeer)? = { _ in nil }
    @ObservationIgnored var logins: any MoveLogins = NoLogins()
    /// Whether ignored `.env` files go with a session (Settings > Remote > Computers).
    @ObservationIgnored var includesEnv: @MainActor () -> Bool = { false }
    /// Whether this computer takes sessions from the computers linked to it.
    @ObservationIgnored var accepts: @MainActor () -> Bool = { true }
    /// Moves that did not happen, kept a while for whoever asked from another device.
    struct Failed { let entry: MoveJournal.Entry?; let message: String; let at: Double }
    var failures: [String: Failed] = [:]
    /// The move the person at this computer is being asked to confirm.
    struct Proposal: Identifiable {
        let session: LiveSession
        let computer: LinkedComputer
        var id: String { "\(session.pid)-\(computer.id)" }
    }
    var proposal: Proposal?
    /// Move and Sleep, asking how the working sessions go.
    var sleepProposal: LinkedComputer?
    /// Moves this computer is carrying out right now. A pass that finishes what a restart left open leaves these alone.
    @ObservationIgnored var inFlight: Set<String> = []
    /// Arriving moves whose session this computer is starting right now.
    @ObservationIgnored var starting: Set<String> = []
    /// Conversations a move has been agreed for and not finished: no second move of one starts meanwhile.
    @ObservationIgnored var claimed: Set<String> = []
    /// Moves started for another device, which watches `records()`.
    @ObservationIgnored var running: [String: Task<Void, Never>] = [:]
    /// Called when a move started with `start` ends either way, so lists can be read again.
    @ObservationIgnored var finished: @MainActor () async -> Void = {}
    @ObservationIgnored var now: @MainActor () -> Double = { Date().timeIntervalSince1970 }
    /// How long a stopped session gets to leave the process list, and a started one to appear in it.
    @ObservationIgnored var patience = Duration.seconds(20)
    private(set) var journal = MoveJournal()
    /// Incoming moves: what was offered and where it was put, by move id.
    @ObservationIgnored var incoming: [String: Incoming] = [:]
    @ObservationIgnored var received: [String: [String: Int]] = [:]
    /// Standby: the computer checkpoints go to, what was last sent of each conversation, and what is kept here for others.
    @ObservationIgnored var standbyPeer: @MainActor () -> String? = { nil }
    @ObservationIgnored var checkpointed: [String: Checkpointed] = [:]
    var kept: [String: Kept] = [:]
    @ObservationIgnored var upkeep: Task<Void, Never>?
    /// Moves asked for while the session works (Moves+When.swift), by move id; `firing` ones have begun.
    var waiting: [String: Waiting] = [:]
    var firing: Set<String> = []
    @ObservationIgnored var awaiting: [String: [CheckedContinuation<String?, Never>]] = [:]
    @ObservationIgnored var watcher: Task<Void, Never>?
    @ObservationIgnored var watchEvery = Duration.seconds(2)
    /// How long an interrupted turn gets to end before a move Now gives up and leaves the session here.
    @ObservationIgnored var stopsWithin = Duration.seconds(30)
    /// Stops a hosted session's turn as the Sessions window and the phone do; the bare Esc when unset.
    @ObservationIgnored var interrupt: (@MainActor (LiveSession) async throws -> Void)?
    /// Move and Sleep: puts the Mac to sleep, and says what stayed behind.
    @ObservationIgnored var sleep: @MainActor () async -> Void = {}
    @ObservationIgnored var tell: @MainActor (String) -> Void = { _ in }
    /// Move and Sleep: the computer the sessions are leaving for, until the Mac sleeps; and what stayed working.
    var sleepsAfter: String?
    var leftWorking: [Stayed]?

    var folder: URL { root.appendingPathComponent("runtime/moves") }
    private var journalURL: URL { folder.appendingPathComponent("journal.json") }

    init(root: URL, hosted: HostedSessions, places: Places, me: @escaping @MainActor () -> MacInfo,
         bridge: @escaping @MainActor (Data) async throws -> Data, live: @escaping @MainActor () async -> [LiveSession]?) {
        self.root = root; self.hosted = hosted; self.places = places; self.me = me; self.bridge = bridge; self.live = live
        if let data = FileManager.default.contents(atPath: journalURL.path), let saved = try? JSONDecoder().decode(MoveJournal.self, from: data) {
            journal = saved
        }
        loadIncoming()
        loadKept()
        loadWaiting()
    }

    /// Changes the journal and writes it down. A step is not taken until its record is on disk.
    @discardableResult
    func record<T>(_ change: (inout MoveJournal) -> T) throws -> T {
        let result = change(&journal)
        try PrivateFile.write(journal, to: journalURL)
        return result
    }

    /// Records a step on a path that must go on to its end whether or not the disk took the record.
    func note(_ change: (inout MoveJournal) -> Void) {
        do { try record(change) } catch { RemoteLog.shared("couldn't save the move journal: \(error.localizedDescription)") }
    }

    /// One request to `bridge/move.py`. A refusal is thrown with the sentence the bridge gave.
    func ask(_ request: [String: Any]) async throws -> [String: Any] {
        let answer = try JSONSerialization.jsonObject(with: try await bridge(try JSONSerialization.data(withJSONObject: request))) as? [String: Any] ?? [:]
        if let refused = answer["refused"] as? String { throw MoveFailure.refused(refused) }
        return answer
    }

    func ownership(of conversation: String) -> MoveJournal.Ownership { journal.ownership(of: conversation) }

    // MARK: Sending

    /// Why this session cannot be moved right now, or nil.
    static func refusal(_ session: LiveSession) -> String? {
        if let refusal = unmovable(session) { return refusal }
        guard session.status == "idle" else { return "It's working. Move it when it has finished its turn." }
        return nil
    }

    /// Why this session can never move from here, working or not.
    static func unmovable(_ session: LiveSession) -> String? {
        guard session.hosted != nil else { return "Only sessions Side A hosts can move. Use Continue on phone first." }
        guard session.sessionID != nil, session.cwd != nil else { return "That session has no conversation to move yet." }
        return nil
    }

    /// A move both computers have agreed to and nothing has been stopped for.
    struct Plan {
        let session: LiveSession
        let conversation: String
        let cwd: String
        let name: String
        let agent: Hosting.Agent
        let offer: MoveOffer
        let answer: MoveAnswer
        let account: String?
        /// The account's login goes with the session.
        let hands: Bool
        /// The move it arrived here under, when its agent has exited since: nothing is stopped (Moves+Ended.swift).
        var ended: String?
    }

    /// Checks the session and asks `peer` whether it will take it. Nothing is stopped. The offer stays open on the
    /// other computer until `run` or `withdraw`. `when` other than `idle` lets a working session be asked about, for a
    /// preview; `id` is the one a waiting move was given, which it keeps.
    func prepare(_ session: LiveSession, to peer: any MovePeer, id: String? = nil, when: MoveRequest.When = .idle) async throws -> Plan {
        let ended = try await endedArrival(of: session)
        let session = ended?.session ?? session
        if let refusal = Self.refusal(session, when: when) { throw MoveFailure.refused(refusal) }
        // A stand-in whose arrival has since run again or moved on names no process to stop.
        guard ended != nil || session.pid > 0 else { throw MoveFailure.refused("That session isn't running on \(me().name).") }
        guard let conversation = session.sessionID, let cwd = session.cwd, let name = session.hosted else { throw MoveFailure.refused("That session can't move.") }
        // Checked and claimed in one step, before anything is awaited, so two moves of one session can't both go on.
        guard journal.ownership(of: conversation).mayRun, claimed.insert(conversation).inserted else { throw MoveFailure.refused("That session is already moving.") }
        do {
            return try await agree(session, conversation: conversation, cwd: cwd, name: name, with: peer, id: id ?? Self.moveID(), ended: ended?.id)
        } catch {
            claimed.remove(conversation)
            throw error
        }
    }

    static func moveID() -> String { "mv-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20) }

    private func agree(_ session: LiveSession, conversation: String, cwd: String, name: String, with peer: any MovePeer, id: String,
                       ended: String?) async throws -> Plan {
        let agent: Hosting.Agent = session.provider == .codex ? .codex : .claude
        let checked = try await ask(["action": "inspect", "folder": cwd])
        if let first = (checked["refusals"] as? [String])?.first { throw MoveFailure.refused(first) }
        let project = URL(fileURLWithPath: checked["top"] as? String ?? cwd).lastPathComponent
        let account = ended.map(arrivalAccount) ?? logins.account(of: session)
        let offer = MoveOffer(id: id, conversationID: conversation, agent: session.provider, project: Self.slug(project), title: session.title ?? session.name,
                              commits: checked["candidates"] as? [String] ?? [], model: session.model, effort: session.effort,
                              permissionMode: session.mode.map(PermissionMode.init(rawValue:)), from: me(), account: account?.wire)
        let answer = try await refusing { try await peer.offer(offer) }
        var hands = false
        if let account, answer.account == .wanted || answer.account == .missing {
            let staying = await logins.staying(account.id, besides: session)
            hands = staying == nil
            if let staying, answer.account == .missing {
                _ = try? await peer.abort(id)
                throw MoveFailure.refused("\(peer.name) isn't signed in to \(session.provider.title), and \(staying).")
            }
        }
        return Plan(session: session, conversation: conversation, cwd: cwd, name: name, agent: agent, offer: offer, answer: answer,
                    account: account?.id, hands: hands, ended: ended)
    }

    /// Tells the other computer a prepared move will not happen.
    func withdraw(_ plan: Plan, from peer: any MovePeer) async {
        claimed.remove(plan.conversation)
        _ = try? await peer.abort(plan.offer.id)
    }

    /// Moves a hosted, idle session to `peer`. Returns once it runs there. Throws `refused` when nothing moved
    /// (the session runs here again if it was stopped) and `unknown` when the other computer did not answer the
    /// request to start it.
    @discardableResult
    func send(_ session: LiveSession, to peer: any MovePeer) async throws -> MoveState {
        try await run(try await prepare(session, to: peer), to: peer)
    }

    func run(_ plan: Plan, to peer: any MovePeer) async throws -> MoveState {
        let id = plan.offer.id
        inFlight.insert(id)
        defer { inFlight.remove(id); claimed.remove(plan.conversation) }
        do {
            return try await carry(plan, to: peer)
        } catch {
            if case MoveFailure.refused(let message) = error { failures[id] = Failed(entry: journal[id], message: message, at: now()) }
            throw error
        }
    }

    private func carry(_ plan: Plan, to peer: any MovePeer) async throws -> MoveState {
        let id = plan.offer.id, session = plan.session, agent = plan.agent
        let seat = plan.ended.map(arrivalSeat) ?? seat(session)
        do {
            var entry = MoveJournal.Entry(id: id, role: .source, session: plan.conversation, agent: agent.rawValue, peer: peer.id, peerName: peer.name,
                                          step: .prepared, at: now(), folder: plan.cwd, name: plan.name)
            entry.restart = Self.restart(of: session, seat: seat)
            entry.ended = plan.ended
            try record {
                $0.begin(entry)
                $0.describe(id, title: plan.offer.title, project: plan.offer.project)
            }
            if plan.ended != nil {
                try await stillEnded(plan)
            } else {
                // It was idle when the move was agreed; a turn started since then is not cut off.
                guard await live()?.first(where: { $0.pid == session.pid })?.status ?? "idle" == "idle" else { throw MoveFailure.refused("It started working. Move it when it has finished its turn.") }
                try await hosted.end(plan.name)
                guard await gone(session) else { throw MoveFailure.refused("It didn't quit, so it's still running here.") }
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
            let parts = try await pack(id: id, agent: agent, conversation: plan.conversation, cwd: plan.cwd, have: plan.answer.have, into: work)
            for part in parts { try await upload(part, from: work, move: id, to: peer) }
            let staged = try await peer.stage(id, MoveStage(parts: parts))
            guard staged.status == .staged else { throw MoveFailure.refused("\(peer.name) didn't accept the session.") }
            try record { $0.advance(id, to: .sent, at: now()) }
            // The login leaves its slot only now, when the other computer holds everything else and has checked it.
            if plan.hands, let account = plan.account {
                // Asked again now: minutes may have passed since the move was agreed.
                if let staying = await logins.staying(account, besides: session) {
                    if plan.answer.account == .missing { throw MoveFailure.refused("\(peer.name) isn't signed in to \(session.provider.title), and \(staying).") }
                } else {
                    try record { $0.carry(id, login: account) }
                    do { login = try await logins.hold(account) } catch {
                        // Whatever a failed hold left aside goes back into its slot before the record is cleared.
                        await logins.restore(account)
                        note { $0.carry(id, login: nil) }
                        if plan.answer.account == .missing { throw error }
                    }
                }
            }
            try record { $0.advance(id, to: .committing, at: now()) }
        } catch {
            // Nothing asked so far can start the session there, so it starts here again whatever went wrong.
            _ = try? await peer.abort(id)
            await comeBack(id, session: session, agent: agent, seat: seat)
            throw MoveFailure.refused(Self.sentence(error, peer: peer.name))
        }
        do {
            let state = try await peer.commit(id, MoveCommit(login: login))
            guard state.status == .live else { throw MoveFailure.refused("\(peer.name) didn't start the session.") }
            note { $0.runs(id, in: state.session) }
            await handed(id, stored: state.account != nil, to: peer.name)
            await left(id, agent: agent, conversation: plan.conversation, cwd: plan.cwd)
            return state
        } catch let failure as MoveFailure {
            // The other computer's own word that it did not start.
            _ = try? await peer.abort(id)
            await comeBack(id, session: session, agent: agent, seat: seat)
            throw failure
        } catch {
            note { $0.advance(id, to: .unknown, at: now()) }
            throw MoveFailure.unknown(peer: peer.name)
        }
    }

    /// The other computer started the session: the login that went with it is deleted here if it is stored there,
    /// and put back if it is not.
    private func handed(_ id: String, stored: Bool, to peer: String) async {
        guard let account = journal[id]?.login else { return }
        if stored { await logins.release(account, to: peer) } else { await logins.restore(account) }
        note { $0.carry(id, login: nil) }
    }

    /// The session stays here: a login taken out of use for the move goes back.
    private func kept(_ id: String) async {
        guard let account = journal[id]?.login else { return }
        await logins.restore(account)
        note { $0.carry(id, login: nil) }
    }

    /// Captures the workspace and the conversation into `work` and says what is there to send.
    func pack(id: String, agent: Hosting.Agent, conversation: String, cwd: String, have: [String], into work: URL) async throws -> [MovePart] {
        var capture: [String: Any] = ["action": "capture", "folder": cwd, "move": id, "out": work.path, "have": have]
        if includesEnv() { capture["env"] = true }
        let manifest = try await ask(capture)
        let exported = try await ask(["action": "export", "agent": agent.rawValue, "session": conversation, "out": work.path, "folder": cwd,
                                      "projects": places.claudeProjects.path, "stores": places.codexStores.map(\.path)])
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: work.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: exported, options: [.sortedKeys]).write(to: work.appendingPathComponent("conversation.json"))
        return try ["manifest.json", "conversation.json", "workspace.bundle", "conversation.tar", "extras.tar"].compactMap { name in
            let url = work.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return MovePart(name: name, sha256: try Self.sha256(url), size: try Self.size(url))
        }
    }

    func upload(_ part: MovePart, from work: URL, move: String, to peer: any MovePeer) async throws {
        let handle = try FileHandle(forReadingFrom: work.appendingPathComponent(part.name))
        defer { try? handle.close() }
        var index = 0
        while let data = try handle.read(upToCount: Self.chunk), !data.isEmpty {
            try await peer.part(move, part.name, index, data)
            index += 1
        }
        if index == 0 { try await peer.part(move, part.name, 0, Data()) }
    }

    /// The session runs on the other computer: its transcript goes out of the CLI's reach here.
    private func left(_ id: String, agent: Hosting.Agent, conversation: String, cwd: String) async {
        note { $0.advance(id, to: .away, at: now()) }
        // If it arrived here from another computer, that arrival is over.
        for entry in journal.all where entry.session == conversation && entry.role == .destination && entry.step == .live {
            note { $0.ended(entry.id, at: now()) }
            incoming[entry.id] = nil
        }
        _ = try? await ask(["action": "park", "agent": agent.rawValue, "session": conversation, "away": folder.appendingPathComponent("away").path,
                            "projects": places.claudeProjects.path, "stores": places.codexStores.map(\.path)])
        _ = try? await ask(["action": "release", "folder": cwd, "move": id])
    }

    /// Starts the session here again after a move that did not happen.
    private func comeBack(_ id: String, session: LiveSession, agent: Hosting.Agent, seat: Seat) async {
        await kept(id)
        note { $0.returned(id, at: now()) }
        guard let conversation = session.sessionID, let cwd = session.cwd else { return }
        _ = try? await ask(["action": "release", "folder": cwd, "move": id])
        // Nothing was running when it began, so nothing starts.
        guard journal[id]?.ended == nil else { return }
        _ = try? await hosted.start(Self.restart(conversation, as: journal[id]?.restart ?? Self.restart(of: session, seat: seat), agent: agent, cwd: cwd))
    }

    /// Finishes what an app restart or a lost answer left open. Safe to call at any time.
    func settle() async {
        await resolveStarting()
        for entry in journal.all where entry.role == .source && !inFlight.contains(entry.id) {
            switch journal.recovery(entry.id) {
            case .nothing: continue
            case .rollBack:
                _ = try? await peer(entry.peer)?.abort(entry.id)
                await restore(entry)
            case .ask:
                if entry.step == .committing { note { $0.advance(entry.id, to: .unknown, at: now()) } }
                guard let peer = peer(entry.peer), var state = try? await peer.state(entry.id) else { continue }
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
                    await handed(entry.id, stored: state.account != nil, to: entry.peerName)
                    await left(entry.id, agent: agent, conversation: entry.session, cwd: entry.folder ?? "")
                }
            }
        }
        await expire()
    }

    /// Starts a journal entry's session here again, unless it is running already. One whose agent had exited before it
    /// left starts only when the person asks for it here (`ranHere`).
    private func restore(_ entry: MoveJournal.Entry, recorded: Bool = false, ranHere: Bool = false) async {
        await kept(entry.id)
        if !recorded { note { $0.returned(entry.id, at: now()) } }
        if let folder = entry.folder { _ = try? await ask(["action": "release", "folder": folder, "move": entry.id]) }
        guard entry.ended == nil || ranHere, let cwd = entry.folder, let agent = Hosting.Agent(rawValue: entry.agent),
              await live()?.contains(where: { $0.sessionID == entry.session }) == false else { return }
        _ = try? await hosted.start(Self.restart(entry.session, as: entry.role == .source ? entry.restart : nil, agent: agent, cwd: cwd))
    }

    func bringHome(_ entry: MoveJournal.Entry) async { await restore(entry, ranHere: true) }

    private func gone(_ session: LiveSession) async -> Bool {
        let end = ContinuousClock.now + patience
        while ContinuousClock.now < end {
            if !ProcessCheck.maySignal(pid: session.pid, started: session.started) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Turns the other computer's "no" into a `refused`, and leaves every other error as it is.
    func refusing<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch let failure as MoveFailure { throw failure } catch { throw MoveFailure.refused(Self.sentence(error, peer: nil)) }
    }

    static func sentence(_ error: any Error, peer: String?) -> String {
        if case MoveFailure.refused(let message) = error { return message }
        if let hosted = error as? HostedError, let message = hosted.errorDescription { return message }
        return peer.map { "\($0) couldn't be reached, so the session stayed here." } ?? "The other computer couldn't be reached."
    }

    static func slug(_ name: String) -> String {
        let slug = name.lowercased().unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "session" : String(slug.prefix(24)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func size(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
