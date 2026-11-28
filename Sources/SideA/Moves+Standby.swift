import Foundation
import SideACore
import SideAProtocol

/// Standby (docs/moving-sessions-prd.md, 4.8): checkpoints of this computer's hosted sessions are kept on one linked
/// computer, which runs nothing. If this computer disappears, a checkpoint can be continued there as a copy.
extension Moves {
    /// What was last sent of a conversation, so an unchanged session is not sent again.
    struct Checkpointed: Codable, Sendable {
        var fingerprint: String
        var at: Double
        var peer: String
    }

    /// A checkpoint kept here for another computer.
    struct Kept: Codable, Sendable {
        var id: String
        var offer: StandbyOffer
        var repository: String?
        /// The device that sent it, which alone may replace or delete it.
        var device: String
        var complete = false
        /// When it arrived, by this computer's clock: what its age is counted from.
        var received: Double?
    }

    static let checkpointEvery = 60.0
    static let keptFor = 30 * 86_400.0

    var standbyFolder: URL { folder.appendingPathComponent("standby") }
    private var keptURL: URL { standbyFolder.appendingPathComponent("kept.json") }
    private func holding(_ id: String) -> URL { standbyFolder.appendingPathComponent(id) }

    private var sentURL: URL { standbyFolder.appendingPathComponent("sent.json") }

    func loadKept() {
        if let data = FileManager.default.contents(atPath: keptURL.path), let saved = try? JSONDecoder().decode([String: Kept].self, from: data) {
            kept = saved.filter { $0.value.complete }
        }
        if let data = FileManager.default.contents(atPath: sentURL.path), let saved = try? JSONDecoder().decode([String: Checkpointed].self, from: data) {
            checkpointed = saved
        }
        // A checkpoint that was still arriving when the app quit is not in the list: its files go.
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: standbyFolder.path)) ?? []
        for name in folders where name.hasPrefix("sb-") && kept[name] == nil { try? FileManager.default.removeItem(at: holding(name)) }
        try? FileManager.default.removeItem(at: standbyFolder.appendingPathComponent("out"))
    }

    /// Where checkpoints went is remembered across launches, so turning Standby off later still deletes them there.
    private func saveSent() {
        do { try PrivateFile.write(checkpointed, to: sentURL) } catch { RemoteLog.shared("couldn't save where checkpoints went: \(error.localizedDescription)") }
    }

    private func saveKept() {
        do { try PrivateFile.write(kept, to: keptURL) } catch { RemoteLog.shared("couldn't save the standby list: \(error.localizedDescription)") }
    }

    // MARK: The computer the sessions run on

    /// Sends a checkpoint of `session` to `peer` when it is idle and something changed since the last one.
    /// Returns whether one was sent. The session is not touched.
    @discardableResult
    func checkpoint(_ session: LiveSession, to peer: any MovePeer & StandbyPeer) async throws -> Bool {
        guard Self.refusal(session) == nil, let conversation = session.sessionID, let cwd = session.cwd, journal.ownership(of: conversation).mayRun,
              !claimed.contains(conversation) else { return false }
        if let last = checkpointed[conversation], last.peer == peer.id, now() - last.at < Self.checkpointEvery { return false }
        let agent: Hosting.Agent = session.provider == .codex ? .codex : .claude
        let checked = try await ask(["action": "inspect", "folder": cwd])
        if let first = (checked["refusals"] as? [String])?.first { throw MoveFailure.refused(first) }
        let id = "sb-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
        let work = standbyFolder.appendingPathComponent("out/\(id)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The conversation first, by itself: with the three trees it says whether anything changed, before the
        // other computer is asked anything.
        let exported = try await ask(["action": "export", "agent": agent.rawValue, "session": conversation, "out": work.path, "folder": cwd,
                                      "projects": places.claudeProjects.path, "stores": places.codexStores.map(\.path)])
        let files = (exported["members"] as? [[String: Any]] ?? []).compactMap { $0["sha256"] as? String }.joined()
        let fingerprint = [checked["base"], checked["index"], checked["work"]].map { $0 as? String ?? "" }.joined(separator: ":") + ":" + files
        if checkpointed[conversation]?.fingerprint == fingerprint, checkpointed[conversation]?.peer == peer.id {
            checkpointed[conversation]?.at = now()
            return false
        }
        let project = URL(fileURLWithPath: checked["top"] as? String ?? cwd).lastPathComponent
        let offer = StandbyOffer(id: id, conversationID: conversation, agent: session.provider, project: Self.slug(project), title: session.title ?? session.name,
                                 commits: checked["candidates"] as? [String] ?? [], model: session.model, effort: session.effort,
                                 permissionMode: session.mode.map(PermissionMode.init(rawValue:)), from: me(), at: now())
        let answer = try await refusing { try await peer.standby(offer) }
        let sent: Result<Bool, any Error>
        do {
            let parts = try await pack(id: id, agent: agent, conversation: conversation, cwd: cwd, have: answer.have, into: work)
            // A session that started working again while this was read is not one consistent point: leave it for next time.
            if await live()?.first(where: { $0.pid == session.pid })?.status == "idle" {
                for part in parts {
                    try await sendPieces(of: part, from: work) { index, data in try await peer.standbyPart(id, part.name, index, data) }
                }
                try await peer.keep(id, MoveStage(parts: parts))
                checkpointed[conversation] = Checkpointed(fingerprint: fingerprint, at: now(), peer: peer.id)
                saveSent()
                sent = .success(true)
            } else {
                sent = .success(false)
            }
        } catch {
            sent = .failure(error)
        }
        // The private ref the capture made in the user's repository goes whatever happened.
        _ = try? await ask(["action": "release", "folder": cwd, "move": id])
        return try sent.get()
    }

    private func sendPieces(of part: MovePart, from work: URL, _ send: (Int, Data) async throws -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: work.appendingPathComponent(part.name))
        defer { try? handle.close() }
        var index = 0
        while let data = try handle.read(upToCount: Self.chunk), !data.isEmpty {
            try await send(index, data)
            index += 1
        }
        if index == 0 { try await send(0, Data()) }
    }

    /// One pass: a checkpoint of every hosted, idle session that changed, to the chosen computer. Sessions that are
    /// gone, or that moved, have their checkpoints removed there.
    func checkpointAll() async {
        guard let id = standbyPeer(), let peer = peer(id) as? (any MovePeer & StandbyPeer) else {
            await forgetCheckpoints()
            return
        }
        let sessions = await live() ?? []
        for session in sessions where session.hosted != nil {
            do { try await checkpoint(session, to: peer) } catch { RemoteLog.shared("standby: no checkpoint this time: \(Self.sentence(error, peer: peer.name))") }
        }
        let alive = Set(sessions.compactMap(\.sessionID))
        for (conversation, sent) in checkpointed where !alive.contains(conversation) || sent.peer != id {
            if let old = self.peer(sent.peer) as? (any MovePeer & StandbyPeer) { try? await old.forget(conversation) }
            checkpointed[conversation] = nil
        }
        saveSent()
    }

    /// Standby was turned off, or pointed elsewhere: what was sent is deleted where it went.
    func forgetCheckpoints() async {
        for peer in Set(checkpointed.values.map(\.peer)) {
            if let old = self.peer(peer) as? (any MovePeer & StandbyPeer) { try? await old.forget("all") }
        }
        guard !checkpointed.isEmpty else { return }
        checkpointed = [:]
        saveSent()
    }

    /// Finishes what a restart left open, then keeps the standby current for as long as the app runs.
    func begin() {
        guard upkeep == nil else { return }
        upkeep = Task { [weak self] in
            await self?.settle()
            self?.watchWaiting()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(Self.checkpointEvery)) } catch { return }
                guard let self else { return }
                await self.checkpointAll()
                await self.dropOldCheckpoints()
                // Staged copies nobody started are dropped here too, on a computer that only ever receives.
                await self.expire()
                if self.journal.all.contains(where: { $0.role == .source && !self.inFlight.contains($0.id) && self.journal.recovery($0.id) != .nothing }) { await self.settle() }
            }
        }
    }

    // MARK: The standby

    func standbyOffered(_ offer: StandbyOffer, from device: String) async throws -> MoveAnswer {
        guard accepts() else { throw MoveFailure.refused("\(me().name) isn't accepting sessions.") }
        guard offer.id.hasPrefix("sb-"), offer.id.count <= 64, offer.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), kept[offer.id] == nil else {
            throw MoveFailure.refused("That checkpoint can't be kept.")
        }
        let found = try await ask(["action": "find", "root": root.path, "commits": offer.commits, "origin": offer.origin ?? "", "folders": places.repositories])
        // An unfinished one from the same computer for the same conversation is replaced.
        for (id, old) in kept where !old.complete && old.device == device && old.offer.conversationID == offer.conversationID { discard(id) }
        kept[offer.id] = Kept(id: offer.id, offer: offer, repository: found["repo"] as? String, device: device)
        received[offer.id] = [:]
        return MoveAnswer(have: found["have"] as? [String] ?? [])
    }

    func standbyPart(_ id: String, _ name: String, _ index: Int, _ data: Data, from device: String) throws {
        guard let pending = kept[id], !pending.complete, pending.device == device else { throw MoveFailure.refused("That checkpoint isn't being received here.") }
        try write(data, piece: index, of: name, for: id, into: holding(id))
    }

    /// Checks the files and keeps the checkpoint; the older one of the same conversation from the same computer goes.
    func keep(_ id: String, _ stage: MoveStage, from device: String) throws {
        guard var pending = kept[id], pending.device == device else { throw MoveFailure.refused("That checkpoint isn't being received here.") }
        if pending.complete { return }
        guard intact(stage, in: holding(id)), ["manifest.json", "conversation.json", "workspace.bundle", "conversation.tar"].allSatisfy({ name in stage.parts.contains { $0.name == name } }) else {
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

    /// Deletes the checkpoints `device` sent of `conversation`, or all it sent.
    func forget(_ conversation: String, from device: String) {
        for (id, old) in kept where old.device == device && (conversation == "all" || old.offer.conversationID == conversation) { discard(id) }
        saveKept()
    }

    private func discard(_ id: String) {
        kept[id] = nil
        received[id] = nil
        try? FileManager.default.removeItem(at: holding(id))
    }

    func dropOldCheckpoints() async {
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

    /// Continues a checkpoint here as a copy: the work lands in a new checkout and the agent forks the conversation,
    /// so the copy has its own id and the original, wherever it still runs, is not this one.
    func continueCopy(of conversation: String) async throws -> MoveState {
        guard let found = kept.values.filter({ $0.complete && $0.offer.conversationID == conversation }).max(by: { ($0.received ?? 0) < ($1.received ?? 0) }) else {
            throw MoveFailure.refused("There is no checkpoint of that session here.")
        }
        guard hosted.available else { throw MoveFailure.refused("\(me().name) can't host sessions yet.") }
        guard journal.ownership(of: conversation).mayRun, await live()?.contains(where: { $0.sessionID == conversation }) != true else {
            throw MoveFailure.refused("That session is already running on \(me().name).")
        }
        let files = holding(found.id), offer = found.offer
        func json(_ name: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: files.appendingPathComponent(name))) as? [String: Any] ?? [:]
        }
        let manifest = try json("manifest.json"), expected = try json("conversation.json")
        let name = "sa-\(offer.project)-\(String(format: "%04x", UInt16.random(in: 0...UInt16.max)))"
        var land: [String: Any] = ["action": "land", "bundle": files.appendingPathComponent("workspace.bundle").path, "manifest": manifest, "name": name]
        if let repository = found.repository { land["repo"] = repository } else { land["landing"] = places.landing.path }
        let landed = try await ask(land)
        guard let folder = landed["folder"] as? String else { throw MoveFailure.refused("\(me().name) couldn't put the work in place.") }
        var written: [String] = []
        do {
            let imported = try await ask(["action": "import", "agent": offer.agent.rawValue, "session": conversation, "archive": files.appendingPathComponent("conversation.tar").path,
                                          "expected": expected, "projects": places.claudeProjects.path, "store": places.codexStores.first?.path ?? "", "folder": folder,
                                          "copy": true])
            written = imported["created"] as? [String] ?? []
            let agent: Hosting.Agent = offer.agent == .codex ? .codex : .claude
            var start = HostedSessions.Start(agent: agent, cwd: folder, mode: .fork(conversation))
            start.origin = "standby"
            start.effort = offer.effort
            start.permissionMode = Self.arrival(offer.permissionMode, agent: offer.agent)
            start.key = "copy-\(found.id)"
            let session = try await hosted.start(start)
            await unfile(imported["resumable"] as? [String] ?? [], once: session, forks: conversation)
            return MoveState(id: found.id, status: .live, session: session, folder: folder)
        } catch {
            if let repository = landed["repo"] as? String {
                _ = try? await ask(["action": "discard", "repo": repository, "name": name, "move": found.id, "created": landed["created"] as? Bool ?? false])
            }
            if !written.isEmpty { _ = try? await ask(["action": "forget", "paths": written, "roots": [places.claudeProjects.path] + places.codexStores.map(\.path)]) }
            throw MoveFailure.refused("\(me().name) couldn't start the copy: \(Self.sentence(error, peer: nil))")
        }
    }
}

extension Moves {
    /// The original conversation may still run on the computer the checkpoint came from, so a copy must not leave it
    /// resumable here by its id: `claude --resume` finds a transcript from any folder. The fork reads the original as
    /// it starts, so the file the import created for that goes once the fork shows under its pane with an id of its own,
    /// or when that has not happened within `patience`. What the fork still reads (tool results, subagents, the
    /// rollouts a Codex thread continues) stays, and so does anything that was here before.
    func unfile(_ paths: [String], once hosted: String, forks conversation: String) async {
        guard !paths.isEmpty else { return }
        let end = ContinuousClock.now + patience
        while ContinuousClock.now < end {
            if await live()?.contains(where: { $0.hosted == hosted && $0.sessionID != nil && $0.sessionID != conversation }) == true { break }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
        }
        do {
            _ = try await ask(["action": "forget", "paths": paths, "roots": [places.claudeProjects.path] + places.codexStores.map(\.path)])
        } catch {
            RemoteLog.shared("standby: the copy's original transcript couldn't be removed: \(Self.sentence(error, peer: nil))")
        }
    }
}

/// What a move's peer also answers when it can be a standby.
protocol StandbyPeer: Sendable {
    func standby(_ offer: StandbyOffer) async throws -> MoveAnswer
    func standbyPart(_ id: String, _ name: String, _ index: Int, _ data: Data) async throws
    func keep(_ id: String, _ stage: MoveStage) async throws
    func forget(_ conversation: String) async throws
}
