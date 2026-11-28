import Foundation
import SideACore
import SideAProtocol

/// Standby (docs/moving-sessions-prd.md 4.8; the Mac's `Moves+Standby`): checkpoints of this computer's hosted sessions
/// are kept on one linked computer, which runs nothing. If this computer disappears, a checkpoint can be continued there
/// as a copy. This computer can be either end: `sidead config standby COMPUTER` sends, and any linked computer may keep
/// its checkpoints here.
extension DaemonMoves {
    /// What was last sent of a conversation, so an unchanged session is not sent again.
    struct Checkpointed: Codable, Sendable {
        var fingerprint: String
        var at: Double
        var peer: String
    }

    /// Where checkpoints went, kept across restarts so that turning Standby off, or pointing it elsewhere, still
    /// deletes them there.
    struct Sent: Codable, Sendable {
        var checkpoints: [String: Checkpointed] = [:]
        /// Computers to be told to delete everything this one sent them, which couldn't be told yet.
        var owed: Set<String> = []
    }

    /// A checkpoint kept here for another computer.
    struct Kept: Codable, Sendable {
        var id: String
        var offer: StandbyOffer
        var repository: String?
        /// The device that sent it, which alone may add to it, replace it or delete it.
        var device: String
        var complete = false
        /// When it arrived, by this computer's clock: what its age is counted from.
        var received: Double?
    }

    static let checkpointEvery = 60.0
    static let keptFor = 30 * 86_400.0
    /// What a checkpoint needs to be continued: `extras.tar` is the only part that may be missing.
    static let checkpointParts = ["manifest.json", "conversation.json", "workspace.bundle", "conversation.tar"]

    var standbyFolder: URL { folder.appendingPathComponent("standby") }
    private func holding(_ id: String) -> URL { standbyFolder.appendingPathComponent(id) }

    /// Checkpoint ids arrive from the other computer and name a folder here: `sb-` and lowercase hex, as Side A makes them.
    static func wellFormed(checkpoint id: String) -> Bool {
        id.hasPrefix("sb-") && (9...40).contains(id.count) && id.dropFirst(3).allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    /// The checkpoints kept for other computers, as the daemon starts: only whole ones. One that was still arriving
    /// when it stopped has its files removed, as does anything left over from taking one here.
    static func keptAtStart(_ record: JSONRecord<[String: Kept]>, folder: URL) -> [String: Kept] {
        let kept = ((try? record.load(default: [:])) ?? [:]).filter { $0.value.complete && wellFormed(checkpoint: $0.key) }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in folders where name.hasPrefix("sb-") && kept[name] == nil { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("out"))
        return kept
    }

    private func saveSent() {
        do { try sentRecord.save(sent) } catch { DaemonLog.line("couldn't save where checkpoints went: \(error)") }
    }

    private func saveKept() {
        do { try keptRecord.save(kept.filter(\.value.complete)) } catch { DaemonLog.line("couldn't save the standby list: \(error)") }
    }

    // MARK: The computer the sessions run on

    /// The linked computer checkpoints go to, when one is chosen and still linked.
    func standbyPeer() async -> (any StandbyPeer)? {
        guard let id = settings().standby, let link = await links.computer(id) else { return nil }
        return peerFor(link) as? any StandbyPeer
    }

    /// Sends a checkpoint of `row` to `peer` when it is idle and something changed since the last one, at most once a
    /// minute. Returns whether one was sent. The session is not touched.
    @discardableResult
    func checkpoint(_ row: LiveRow, to peer: any StandbyPeer) async throws -> Bool {
        guard Self.refusal(row) == nil, let conversation = row.id, let cwd = row.cwd, let name = row.hosted, journal.ownership(of: conversation).mayRun,
              !claimed.contains(conversation), checkpointing.insert(conversation).inserted else { return false }
        defer { checkpointing.remove(conversation) }
        if let last = sent.checkpoints[conversation], last.peer == peer.id, now() - last.at < Self.checkpointEvery { return false }
        let agent: Hosting.Agent = row.agent == .codex ? .codex : .claude
        let checked = try await ask(["action": "inspect", "folder": cwd])
        if let first = (checked["refusals"] as? [String])?.first { throw MoveFailure.refused(first) }
        let id = "sb-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
        let work = standbyFolder.appendingPathComponent("out/\(id)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let slot = await engine.tmux.account(of: name)
        // The conversation first, by itself: with the three trees it says whether anything changed, before the other
        // computer is asked anything.
        let exported = try await ask(["action": "export", "agent": agent.rawValue, "session": conversation, "out": work.path, "folder": cwd,
                                      "projects": filed(conversation, slot: slot).path, "stores": logins.codexStores.map(\.path)])
        let files = (exported["members"] as? [[String: Any]] ?? []).compactMap { $0["sha256"] as? String }.joined()
        let fingerprint = [checked["base"], checked["index"], checked["work"]].map { $0 as? String ?? "" }.joined(separator: ":") + ":" + files
        if sent.checkpoints[conversation]?.fingerprint == fingerprint, sent.checkpoints[conversation]?.peer == peer.id {
            sent.checkpoints[conversation]?.at = now()
            return false
        }
        let project = URL(fileURLWithPath: checked["top"] as? String ?? cwd).lastPathComponent
        let offer = StandbyOffer(id: id, conversationID: conversation, agent: row.agent, project: Self.slug(project), title: row.title ?? row.name,
                                 commits: checked["candidates"] as? [String] ?? [], model: row.model, effort: row.effort,
                                 permissionMode: row.mode.map(PermissionMode.init(rawValue:)), from: me(), at: now())
        let answer = try await refusing { try await peer.standby(offer) }
        let outcome: Result<Bool, any Error>
        do {
            let parts = try await pack(id: id, agent: agent, conversation: conversation, cwd: cwd, have: answer.have, slot: slot, into: work)
            // A session that started working again while this was read is not one consistent point: leave it for next time.
            if (await engine.live()).first(where: { $0.pid == row.pid })?.status == "idle" {
                for part in parts {
                    try await Self.pieces(of: part, from: work) { index, data in try await peer.standbyPart(id, part.name, index, data) }
                }
                try await peer.keep(id, MoveStage(parts: parts))
                sent.checkpoints[conversation] = Checkpointed(fingerprint: fingerprint, at: now(), peer: peer.id)
                saveSent()
                outcome = .success(true)
            } else {
                outcome = .success(false)
            }
        } catch {
            outcome = .failure(error)
        }
        // The private ref the capture made in the user's repository goes whatever happened.
        _ = try? await ask(["action": "release", "folder": cwd, "move": id])
        return try outcome.get()
    }

    /// One pass: computers that aren't the standby any more are told to delete what they hold, then a checkpoint of every
    /// hosted, idle session that changed goes to the one that is, and sessions that ended or moved have theirs removed there.
    func checkpointAll() async {
        let peer = await standbyPeer()
        for (conversation, went) in sent.checkpoints where went.peer != peer?.id {
            sent.owed.insert(went.peer)
            sent.checkpoints[conversation] = nil
        }
        for computer in sent.owed {
            guard let link = await links.computer(computer), let old = peerFor(link) as? any StandbyPeer else {
                sent.owed.remove(computer)
                continue
            }
            do {
                try await old.forget("all")
                sent.owed.remove(computer)
            } catch { DaemonLog.line("standby: \(old.name) couldn't be told to delete its checkpoints yet: \(Self.sentence(error, peer: old.name))") }
        }
        saveSent()
        guard let peer else { return }
        let sessions = await engine.live()
        for row in sessions where row.hosted != nil {
            do { try await checkpoint(row, to: peer) } catch { DaemonLog.line("standby: no checkpoint this time: \(Self.sentence(error, peer: peer.name))") }
        }
        let running = Set(sessions.compactMap(\.id))
        for (conversation, went) in sent.checkpoints where !running.contains(conversation) && went.peer == peer.id {
            do {
                try await peer.forget(conversation)
                sent.checkpoints[conversation] = nil
            } catch { DaemonLog.line("standby: \(peer.name) couldn't be told a session ended: \(Self.sentence(error, peer: peer.name))") }
        }
        saveSent()
    }

    /// A session finished a turn: its checkpoint goes now rather than at the next pass, within the same limits.
    func checkpointSoon(_ conversation: String) async {
        guard let peer = await standbyPeer(), let row = await engine.rows.first(where: { $0.id == conversation && $0.hosted != nil }) else { return }
        do { try await checkpoint(row, to: peer) } catch { DaemonLog.line("standby: no checkpoint this time: \(Self.sentence(error, peer: peer.name))") }
    }

    // MARK: The standby

    func standbyOffered(_ offer: StandbyOffer, from device: String) async throws -> MoveAnswer {
        guard settings().accepts else { throw MoveFailure.refused("\(me().name) isn't accepting sessions.") }
        guard Self.wellFormed(checkpoint: offer.id), Self.wellFormed(conversation: offer.conversationID), kept[offer.id] == nil else {
            throw MoveFailure.refused("That checkpoint can't be kept.")
        }
        let found = try await ask(["action": "find", "root": places.root.path, "commits": offer.commits, "origin": offer.origin ?? "", "folders": places.repositories])
        // An unfinished one from the same computer for the same conversation is replaced.
        for (id, old) in kept where !old.complete && old.device == device && old.offer.conversationID == offer.conversationID { discard(id) }
        try? FileManager.default.removeItem(at: holding(offer.id))
        kept[offer.id] = Kept(id: offer.id, offer: offer, repository: found["repo"] as? String, device: device)
        received[offer.id] = [:]
        return MoveAnswer(have: found["have"] as? [String] ?? [])
    }

    func standbyPart(_ id: String, _ name: String, _ index: Int, _ data: Data, from device: String) throws {
        guard Self.wellFormed(checkpoint: id), let pending = kept[id], !pending.complete, pending.device == device else {
            throw MoveFailure.refused("That checkpoint isn't being received here.")
        }
        try write(data, piece: index, of: name, for: id, into: holding(id))
    }

    /// Checks the files and keeps the checkpoint; the older one of the same conversation from the same computer goes.
    func keep(_ id: String, _ stage: MoveStage, from device: String) throws {
        guard Self.wellFormed(checkpoint: id), var pending = kept[id], pending.device == device else {
            throw MoveFailure.refused("That checkpoint isn't being received here.")
        }
        if pending.complete { return }
        let files = holding(id)
        let manifest = try? json(files.appendingPathComponent("manifest.json")), expected = try? json(files.appendingPathComponent("conversation.json"))
        guard Self.intact(stage, in: files), Self.checkpointParts.allSatisfy({ name in stage.parts.contains { $0.name == name } }),
              manifest?["move"] as? String == id, expected?["session"] as? String == pending.offer.conversationID,
              expected?["agent"] as? String == pending.offer.agent.rawValue else {
            discard(id)
            throw MoveFailure.refused("The checkpoint was damaged on the way.")
        }
        pending.complete = true
        pending.received = now()
        kept[id] = pending
        received[id] = nil
        for (other, old) in kept where other != id && old.device == device && old.offer.conversationID == pending.offer.conversationID { discard(other) }
        saveKept()
    }

    /// Deletes the checkpoints `device` sent of `conversation`, or all it sent. One it doesn't hold is already gone.
    func forget(_ conversation: String, from device: String) {
        let gone = kept.filter { $0.value.device == device && (conversation == "all" || $0.value.offer.conversationID == conversation) }.keys
        guard !gone.isEmpty else { return }
        for id in gone { discard(id) }
        saveKept()
    }

    private func discard(_ id: String) {
        kept[id] = nil
        received[id] = nil
        if Self.wellFormed(checkpoint: id) { try? FileManager.default.removeItem(at: holding(id)) }
    }

    /// Checkpoints older than thirty days, by when they arrived here, are deleted.
    func dropOldCheckpoints() {
        let old = kept.filter { now() - ($0.value.received ?? $0.value.offer.at) >= Self.keptFor }.keys
        guard !old.isEmpty else { return }
        for id in old { discard(id) }
        saveKept()
    }

    /// What is kept here for other computers, newest first.
    func copies() -> [StandbyCopy] {
        kept.values.filter(\.complete).map {
            StandbyCopy(conversationID: $0.offer.conversationID, agent: $0.offer.agent, title: $0.offer.title, project: $0.offer.project,
                        computer: $0.offer.from.id, computerName: $0.offer.from.name, at: $0.offer.at)
        }.sorted { $0.at > $1.at }
    }

    /// Continues a checkpoint here as a copy: the work lands in a new checkout and the agent forks the conversation, so
    /// the copy has its own id and the original, wherever it still runs, is not this one.
    func continueCopy(of conversation: String) async throws -> MoveState {
        guard Self.wellFormed(conversation: conversation),
              let found = kept.values.filter({ $0.complete && $0.offer.conversationID == conversation }).max(by: { ($0.received ?? 0) < ($1.received ?? 0) }) else {
            throw MoveFailure.refused("There is no checkpoint of that session here.")
        }
        let offer = found.offer
        guard await engine.tmux.available else { throw MoveFailure.refused("\(me().name) can't host sessions: it needs tmux 3.4 or newer.") }
        guard journal.ownership(of: conversation).mayRun, !(await engine.live()).contains(where: { $0.id == conversation }), copying.insert(conversation).inserted else {
            throw MoveFailure.refused("That session is already running on \(me().name).")
        }
        defer { copying.remove(conversation) }
        guard logins.hasAny(offer.agent) else { throw MoveFailure.refused("Sign in to \(offer.agent.title) on \(me().name) first.") }
        let files = holding(found.id)
        let manifest = try json(files.appendingPathComponent("manifest.json")), expected = try json(files.appendingPathComponent("conversation.json"))
        let name = "sa-\(Self.slug(offer.project))-\(String(format: "%04x", UInt16.random(in: 0...UInt16.max)))"
        var land: [String: Any] = ["action": "land", "bundle": files.appendingPathComponent("workspace.bundle").path, "manifest": manifest, "name": name]
        if let repository = found.repository { land["repo"] = repository } else { land["landing"] = places.landing.path }
        try FileManager.default.createDirectory(at: places.landing, withIntermediateDirectories: true)
        let landed = try await ask(land)
        guard let folder = (landed["folder"] as? String).map(Self.real) else { throw MoveFailure.refused("\(me().name) couldn't put the work in place.") }
        let seat = logins.fallback(offer.agent)
        var written: [String] = []
        do {
            let imported = try await ask(["action": "import", "agent": offer.agent.rawValue, "session": conversation,
                                          "archive": files.appendingPathComponent("conversation.tar").path, "expected": expected,
                                          "projects": logins.projects(for: seat).path, "store": logins.codexStores.first?.path ?? "", "folder": folder])
            written = imported["created"] as? [String] ?? []
            let agent: Hosting.Agent = offer.agent == .codex ? .codex : .claude
            var start = Self.launch(agent, cwd: folder, conversation: conversation, model: nil, effort: offer.effort,
                                    mode: Self.arrival(offer.permissionMode, agent: offer.agent), fork: true)
            start.origin = "standby"
            start.key = "copy-\(found.id)"
            start.environment = logins.seat(seat)
            start.account = seat.flatMap { $0.isEmpty || $0 == DaemonLogins.codex ? nil : $0 }
            let session = try await launch(start)
            guard await engine.tmux.list().contains(where: { $0.name == session && !$0.dead }) else {
                throw MoveFailure.refused("The copy stopped as soon as it started.")
            }
            await engine.refresh(force: true)
            return MoveState(id: found.id, status: .live, session: session, folder: folder)
        } catch {
            if let repository = landed["repo"] as? String {
                _ = try? await ask(["action": "discard", "repo": repository, "name": name, "move": found.id, "created": landed["created"] as? Bool ?? false])
            }
            if !written.isEmpty {
                _ = try? await ask(["action": "forget", "paths": written, "roots": logins.allProjects(first: nil).map(\.path) + logins.codexStores.map(\.path)])
            }
            throw MoveFailure.refused("\(me().name) couldn't start the copy: \(Self.sentence(error, peer: nil))")
        }
    }
}

/// What a move's peer also answers when it can keep a standby.
protocol StandbyPeer: MovePeer {
    func standby(_ offer: StandbyOffer) async throws -> MoveAnswer
    func standbyPart(_ id: String, _ name: String, _ index: Int, _ data: Data) async throws
    func keep(_ id: String, _ stage: MoveStage) async throws
    func forget(_ conversation: String) async throws
}

extension LinkedPeer: StandbyPeer {
    func standby(_ offer: StandbyOffer) async throws -> MoveAnswer {
        try await answered(MoveAnswer.self) { try await call("POST", "/v1/standby", body: try json(offer), key: "\(offer.id)-offer", timeout: .seconds(120)) }
    }

    func standbyPart(_ id: String, _ name: String, _ index: Int, _ data: Data) async throws {
        try await Self.refusing {
            try await call("POST", "/v1/standby/\(Self.segment(id))/parts/\(Self.segment(name))/\(index)", body: data, contentType: "application/octet-stream",
                           key: "\(id)-\(name)-\(index)", timeout: .seconds(120))
        }
    }

    func keep(_ id: String, _ stage: MoveStage) async throws {
        try await Self.refusing { try await call("POST", "/v1/standby/\(Self.segment(id))/keep", body: try json(stage), key: "\(id)-keep", timeout: .seconds(600)) }
    }

    func forget(_ conversation: String) async throws {
        try await Self.refusing { try await call("DELETE", "/v1/standby/\(Self.segment(conversation))", key: UUID().uuidString.lowercased()) }
    }
}
