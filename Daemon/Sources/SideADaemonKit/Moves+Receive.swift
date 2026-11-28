import Foundation
import SideACore
import SideAProtocol

/// The receiving side of a move: take the offer, collect the files, put them in place, and start the session only when
/// asked (the Mac's `Moves+Receive`).
extension DaemonMoves {
    struct Incoming: Codable, Sendable {
        var offer: MoveOffer
        /// The repository here the work lands beside; nil for a new clone.
        var repository: String?
        var mode: String
        var name: String?
        var folder: String?
        var tree: String?
        var created = false
        /// Conversation files the import created, removed again if the move is dropped.
        var written: [String]?
        var session: String?
        /// The account here the session starts on; nil for whichever is signed in.
        var account: String?
        /// The account whose login arrived with this move, its email, and whether the account was new here.
        var stored: String?
        var storedEmail: String?
        var storedNew: String?
        /// What the sender was told about the account, so `commit` holds it to that.
        var promised: String?
        /// The `projects` folder the conversation was filed in: an account's own with `CLAUDE_CONFIG_DIR`, so a login
        /// that arrives with `commit` means filing it again in the new account's.
        var filedIn: String?
    }

    private func place(_ id: String) -> URL { folder.appendingPathComponent(id) }
    private func inbox(_ id: String) -> URL { place(id).appendingPathComponent("in") }

    private func keep(_ id: String, _ value: Incoming) {
        incoming[id] = value
        saveIncoming()
    }

    /// Ids arrive from the other computer and name folders here, so only the shapes Side A makes are taken (the Mac's
    /// `Moves.wellFormed`): `mv-` and lowercase hex for a move.
    static func wellFormed(move id: String) -> Bool {
        id.hasPrefix("mv-") && (9...40).contains(id.count) && id.dropFirst(3).allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    static func wellFormed(conversation id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// What a session may run with on arrival. Modes that ask before acting arrive as they were; anything that lets the
    /// agent act unasked arrives asking, because the sender does not decide that for this computer.
    static func arrival(_ mode: PermissionMode?, agent: AgentProvider) -> String {
        guard agent == .claude, let mode, [.default, .plan, .acceptEdits].contains(mode) else { return "default" }
        return mode.rawValue
    }

    /// Accept Sessions is off (`sidead config accept-sessions off`): the Mac's sentence, and how to turn it on here.
    func refusesSessions() -> String {
        "\(me().name) isn't accepting sessions. Turn that on there with sidead config accept-sessions on."
    }

    func offered(_ offer: MoveOffer, from device: String) async throws -> MoveAnswer {
        guard Self.wellFormed(move: offer.id), Self.wellFormed(conversation: offer.conversationID) else { throw MoveFailure.refused("That move can't be received here.") }
        guard settings().accepts else { throw MoveFailure.refused(refusesSessions()) }
        guard await engine.tmux.available else { throw MoveFailure.refused("\(me().name) can't host sessions: it needs tmux 3.4 or newer.") }
        // A session this computer sent to the one now offering it is coming back, which is the one case where a
        // conversation that is away may be received.
        let sent = journal.open(for: offer.conversationID)
        let comingBack = sent?.step == .away && sent?.peer == offer.from.id
        guard journal.ownership(of: offer.conversationID).mayRun || comingBack, !(await engine.live()).contains(where: { $0.id == offer.conversationID }) else {
            throw MoveFailure.refused("That session is already running on \(me().name).")
        }
        // It lands beside the checkout it left from, when it left from here.
        let before = journal.all.filter { $0.session == offer.conversationID && $0.role == .source }.compactMap(\.folder)
        let found = try await ask(["action": "find", "root": places.root.path, "commits": offer.commits, "origin": offer.origin ?? "",
                                   "folders": before + places.repositories, "landing": places.landing.path])
        let mode = Self.arrival(offer.permissionMode, agent: offer.agent)
        let entry = MoveJournal.Entry(id: offer.id, role: .destination, session: offer.conversationID, agent: offer.agent.rawValue,
                                      peer: offer.from.id.isEmpty ? device : offer.from.id, peerName: offer.from.name, step: .staging, at: now())
        guard try record({ $0.receive(entry) }) else { throw MoveFailure.refused("That move was already dropped here.") }
        let repository = found["repo"] as? String
        var account: MoveAnswer.Account?, local: String?
        if let wanted = offer.account {
            local = logins.signedIn(offer.agent, email: wanted.email)
            account = local != nil ? .here : logins.hasAny(offer.agent) ? .wanted : .missing
        } else if !logins.hasAny(offer.agent) {
            note { _ = $0.abort(offer.id, session: offer.conversationID, agent: offer.agent.rawValue, peer: entry.peer, peerName: entry.peerName, at: now()) }
            throw MoveFailure.refused("Sign in to \(offer.agent.title) on \(me().name) first.")
        }
        keep(offer.id, Incoming(offer: offer, repository: repository, mode: mode, account: local, promised: account?.rawValue))
        try? FileManager.default.removeItem(at: inbox(offer.id))
        received[offer.id] = [:]
        return MoveAnswer(have: found["have"] as? [String] ?? [], permissionMode: mode == offer.permissionMode?.rawValue ? nil : PermissionMode(rawValue: mode),
                          landing: repository ?? places.landing.appendingPathComponent(offer.project).path, account: account)
    }

    /// One piece of a file, in order. The piece just written may arrive again (a retried request) and is ignored.
    func part(_ id: String, _ name: String, _ index: Int, _ data: Data) throws {
        guard Self.wellFormed(move: id), journal.status(id) == .staging else { throw MoveFailure.refused("That move isn't being received here.") }
        try write(data, piece: index, of: name, for: id, into: inbox(id))
    }

    /// Piece `index` of the part `name` of the move or checkpoint `id`, into `folder`. `id` has been checked already.
    func write(_ data: Data, piece index: Int, of name: String, for id: String, into folder: URL) throws {
        guard Self.partNames.contains(name), data.count <= Self.chunk, index >= 0 else { throw MoveFailure.refused("That move isn't being received here.") }
        let next = received[id]?[name] ?? 0
        if index == next - 1 { return }
        guard index == next else { throw MoveFailure.refused("A piece of the session arrived out of order.") }
        guard index * Self.chunk + data.count <= Self.maxPart else { throw MoveFailure.refused("The session is larger than \(me().name) takes.") }
        let url = folder.appendingPathComponent(name)
        if index == 0 {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw MoveFailure.refused("\(me().name) couldn't store the session.")
            }
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        received[id, default: [:]][name] = next + 1
    }

    /// Checks what arrived and puts it in place: the workspace in a new checkout and the conversation where the CLI finds
    /// it. Nothing is started. On any failure everything it made is removed and the move is dropped.
    func stage(_ id: String, _ stage: MoveStage) async throws -> MoveState {
        if journal.status(id) == .staged, let known = incoming[id] { return MoveState(id: id, status: .staged, folder: known.folder) }
        guard Self.wellFormed(move: id), journal.status(id) == .staging, var known = incoming[id] else { throw MoveFailure.refused("That move isn't being received here.") }
        do {
            guard Self.intact(stage, in: inbox(id)) else { throw MoveFailure.refused("The session was damaged on the way.") }
            let manifest = try json(inbox(id).appendingPathComponent("manifest.json")), expected = try json(inbox(id).appendingPathComponent("conversation.json"))
            guard manifest["move"] as? String == id, expected["session"] as? String == known.offer.conversationID,
                  expected["agent"] as? String == known.offer.agent.rawValue else { throw MoveFailure.refused("The session that arrived is not the one that was offered.") }
            let name = "sa-\(known.offer.project)-\(String(format: "%04x", UInt16.random(in: 0...UInt16.max)))"
            var land: [String: Any] = ["action": "land", "bundle": inbox(id).appendingPathComponent("workspace.bundle").path, "manifest": manifest, "name": name]
            if let repository = known.repository { land["repo"] = repository } else { land["landing"] = places.landing.path }
            if stage.parts.contains(where: { $0.name == "extras.tar" }) { land["extras"] = inbox(id).appendingPathComponent("extras.tar").path }
            try FileManager.default.createDirectory(at: places.landing, withIntermediateDirectories: true)
            let landed = try await ask(land)
            known.name = name
            // The CLI files a conversation under the folder it runs in with links resolved (its getcwd), so the import
            // names it the same way.
            known.folder = (landed["folder"] as? String).map(Self.real)
            known.tree = landed["tree"] as? String
            known.repository = landed["repo"] as? String ?? known.repository
            known.created = landed["created"] as? Bool ?? false
            // Dropped while the work was landing (the sender gave up waiting): what landed is removed below.
            guard journal.status(id) == .staging else { throw MoveFailure.refused("That move was dropped.") }
            keep(id, known)
            let projects = logins.projects(for: known.account ?? logins.fallback(known.offer.agent))
            let imported = try await ask(["action": "import", "agent": known.offer.agent.rawValue, "session": known.offer.conversationID,
                                          "archive": inbox(id).appendingPathComponent("conversation.tar").path, "expected": expected,
                                          "projects": projects.path, "store": logins.codexStores.first?.path ?? "", "folder": known.folder ?? ""])
            known.written = imported["created"] as? [String]
            known.filedIn = projects.path
            guard journal.status(id) == .staging else { throw MoveFailure.refused("That move was dropped.") }
            keep(id, known)
            guard let folder = known.folder, try record({ $0.staged(id, folder: folder, name: name, at: now()) }) else {
                throw MoveFailure.refused("\(me().name) couldn't put the session in place.")
            }
            // The conversation stays until the start, in case a login that comes with it files it under another account.
            for kept in ["conversation.tar", "conversation.json"] {
                try FileManager.default.moveItem(at: inbox(id).appendingPathComponent(kept), to: place(id).appendingPathComponent(kept))
            }
            try? FileManager.default.removeItem(at: inbox(id))
            return MoveState(id: id, status: .staged, folder: folder)
        } catch {
            // With what this call made, whether or not the record of the move is still open.
            if await !drop(id) { _ = await remove(known, id) }
            throw MoveFailure.refused(Self.sentence(error, peer: nil))
        }
    }

    func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    /// Whether the files in `folder` are the ones `stage` lists, by size and hash.
    static func intact(_ stage: MoveStage, in folder: URL) -> Bool {
        stage.parts.allSatisfy { part in
            let url = folder.appendingPathComponent(part.name)
            return partNames.contains(part.name) && (try? size(url)) == part.size && (try? sha256(url)) == part.sha256
        }
    }

    /// Starts the session, once. A repeated request after it started gets the same answer and starts nothing.
    func commit(_ id: String, _ commit: MoveCommit = MoveCommit()) async throws -> MoveState {
        guard Self.wellFormed(move: id) else { throw MoveFailure.refused("That move isn't waiting here.") }
        // The journal answers first: a session that started here and has since gone on to another computer has no
        // record of its arrival left, and must still be "live" to the computer that sent it.
        let saved = incoming[id]
        switch try record({ $0.commit(id, at: now()) }) {
        case .refused: throw MoveFailure.refused("That move isn't waiting here.")
        case .alreadyLive: return MoveState(id: id, status: .live, session: saved?.session, folder: saved?.folder, account: saved?.storedEmail)
        // Neither a yes nor a no: the first request is still starting it, and the sender asks again.
        case .starting: throw MoveFailure.unknown(peer: me().name)
        case .start: break
        }
        guard var known = saved else {
            note { $0.failed(id, at: now()) }
            throw MoveFailure.refused("That move isn't waiting here.")
        }
        let agent: Hosting.Agent = known.offer.agent == .codex ? .codex : .claude
        starting.insert(id)
        defer { starting.remove(id) }
        do {
            if let login = commit.login, known.account == nil {
                // The login that came is the one the offer named, or it is not taken.
                guard login.email.caseInsensitiveCompare(known.offer.account?.email ?? "") == .orderedSame else {
                    throw MoveFailure.refused("The login that arrived is for another account.")
                }
                do {
                    let got = try logins.receive(login, agent: known.offer.agent)
                    known.account = got.id; known.stored = got.id; known.storedEmail = login.email; known.storedNew = got.added ? got.id : nil
                    keep(id, known)
                } catch where known.promised != MoveAnswer.Account.missing.rawValue {
                    // Another account here can run it, as the sender was told.
                    DaemonLog.line("move \(id): the login that came with it wasn't stored: \(Self.sentence(error, peer: nil))")
                }
            }
            guard known.account != nil || logins.hasAny(known.offer.agent) else {
                throw MoveFailure.refused("\(me().name) has no \(known.offer.agent.title) login to run it on.")
            }
            let seat = known.account ?? logins.fallback(known.offer.agent)
            if agent == .claude { try await refile(id, &known, for: seat) }
            var start = Self.launch(agent, cwd: known.folder ?? "", conversation: known.offer.conversationID, model: known.offer.model,
                                    effort: known.offer.effort, mode: known.mode)
            start.key = id
            start.environment = logins.seat(seat)
            start.account = seat.flatMap { $0.isEmpty || $0 == DaemonLogins.codex ? nil : $0 }
            let name = try await launch(start)
            // An agent that dies the moment it starts never ran: the same as not starting.
            guard await engine.tmux.list().contains(where: { $0.name == name && !$0.dead }) else {
                throw MoveFailure.refused("The session stopped as soon as it started.")
            }
            known.session = name
            keep(id, known)
            // Only now does this computer say it runs: an answer of "live" lets the sender delete its login.
            try record { $0.started(id, at: now()) }
            await engine.refresh(force: true)
            cameBack(known.offer.conversationID, from: known.offer.from.id)
            for kept in ["conversation.tar", "conversation.json"] { try? FileManager.default.removeItem(at: place(id).appendingPathComponent(kept)) }
            return MoveState(id: id, status: .live, session: known.session, folder: known.folder, account: known.storedEmail)
        } catch {
            // It did not start, and the sender starts it again on this answer: make sure nothing of it runs here, and that
            // the login it sent exists only there.
            for pane in await engine.tmux.list() where pane.session == known.offer.conversationID { _ = await engine.tmux.end(pane.name) }
            await engine.refresh(force: true)
            if let stored = known.stored { logins.remove(stored, agent: known.offer.agent, added: known.storedNew != nil) }
            note { $0.failed(id, at: now()) }
            _ = await remove(known, id)
            throw MoveFailure.refused("\(me().name) couldn't start the session: \(Self.sentence(error, peer: nil))")
        }
    }

    /// With `CLAUDE_CONFIG_DIR` each account has its own `projects` folder, so a session that starts on another account
    /// than the one its conversation was filed under at stage is filed again there, and the first filing removed.
    private func refile(_ id: String, _ known: inout Incoming, for seat: String?) async throws {
        let target = logins.projects(for: seat)
        guard let filed = known.filedIn, URL(fileURLWithPath: filed).standardizedFileURL.path != target.standardizedFileURL.path else { return }
        let expected = try json(place(id).appendingPathComponent("conversation.json"))
        let imported = try await ask(["action": "import", "agent": known.offer.agent.rawValue, "session": known.offer.conversationID,
                                      "archive": place(id).appendingPathComponent("conversation.tar").path, "expected": expected,
                                      "projects": target.path, "store": logins.codexStores.first?.path ?? "", "folder": known.folder ?? ""])
        if let written = known.written, !written.isEmpty { _ = try? await ask(["action": "forget", "paths": written, "roots": [filed]]) }
        known.written = imported["created"] as? [String]
        known.filedIn = target.path
        keep(id, known)
    }

    /// The session is running here again, so the record of it being away is closed and the copy kept out of the CLI's
    /// reach while it was gone is removed: what arrived continues it.
    private func cameBack(_ conversation: String, from peer: String) {
        for entry in journal.all where entry.session == conversation && entry.role == .source && entry.step == .away && entry.peer == peer {
            note { $0.returned(entry.id, at: now()) }
        }
        try? FileManager.default.removeItem(at: away.appendingPathComponent(conversation))
    }

    /// Drops a move that has not started. One this computer never saw is written down as dropped, so a request to start
    /// it that arrives late is refused.
    func abort(_ id: String, from device: String) async -> MoveState {
        guard Self.wellFormed(move: id) else { return MoveState(id: id, status: .none) }
        if journal.status(id) == .live || journal.status(id) == .starting { return state(id) }
        if journal[id] == nil {
            note { _ = $0.abort(id, session: "", agent: "", peer: device, peerName: "", at: now()) }
            return MoveState(id: id, status: .none)
        }
        return MoveState(id: id, status: await drop(id) ? .discarded : MoveState.Status(rawValue: journal.status(id).rawValue))
    }

    func state(_ id: String) -> MoveState {
        let known = incoming[id]
        return MoveState(id: id, status: MoveState.Status(rawValue: journal.status(id).rawValue), session: known?.session, folder: known?.folder,
                         account: journal.status(id) == .live ? known?.storedEmail : nil)
    }

    private func drop(_ id: String) async -> Bool {
        guard let entry = journal[id], entry.role == .destination, entry.step == .staging || entry.step == .staged else { return false }
        note { _ = $0.abort(id, session: entry.session, agent: entry.agent, peer: entry.peer, peerName: entry.peerName, at: now()) }
        if let known = incoming[id] { _ = await remove(known, id) } else { try? FileManager.default.removeItem(at: place(id)) }
        return true
    }

    /// Removes what staging made here: the checkout, the conversation files it created, and the files received.
    private func remove(_ known: Incoming, _ id: String) async -> Bool {
        if let name = known.name, let repository = known.repository {
            _ = try? await ask(["action": "discard", "repo": repository, "name": name, "move": id, "created": known.created])
        }
        if let written = known.written, !written.isEmpty {
            _ = try? await ask(["action": "forget", "paths": written, "roots": logins.allProjects(first: nil).map(\.path) + logins.codexStores.map(\.path)])
        }
        incoming[id] = nil
        received[id] = nil
        saveIncoming()
        if Self.wellFormed(move: id) { try? FileManager.default.removeItem(at: place(id)) }
        return true
    }

    /// Moves this computer was starting when the daemon stopped: each runs, or nothing of it is left and the sender is
    /// told so when it asks.
    func resolveStarting() async {
        let open = journal.all.filter { $0.role == .destination && $0.step == .starting && !starting.contains($0.id) }
        guard !open.isEmpty else { return }
        let rows = await engine.live(), panes = await engine.tmux.list()
        for entry in open {
            if rows.contains(where: { $0.id == entry.session }) || panes.contains(where: { $0.session == entry.session && !$0.dead }) {
                note { $0.started(entry.id, at: now()) }
                continue
            }
            if let known = incoming[entry.id] {
                if let stored = known.stored { logins.remove(stored, agent: known.offer.agent, added: known.storedNew != nil) }
                _ = await remove(known, entry.id)
            }
            note { $0.failed(entry.id, at: now()) }
        }
    }

    /// Drops staged copies nobody asked to start, and forgets old entries.
    func expire() async {
        guard let stale = try? record({ $0.expire(now: now()) }) else { return }
        for entry in stale { if let known = incoming[entry.id] { _ = await remove(known, entry.id) } }
    }
}
