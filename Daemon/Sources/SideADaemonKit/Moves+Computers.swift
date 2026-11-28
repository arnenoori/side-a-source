import Crypto
import Foundation
import SideACore
import SideAProtocol

/// Linking two computers (docs/remote/protocol.md, "Linking two computers"), and what a phone and `sidead move` ask.
extension DaemonMoves {
    // MARK: Linking

    /// The other computer paired here as a client and sent the way back to it. Answers with the keys this computer will
    /// sign its calls there with.
    func accept(_ link: ComputerLink, device: String) async throws -> ComputerLinked {
        guard let daemon else { throw MoveFailure.refused("\(me().name) is still starting.") }
        guard link.mac.id != daemon.config.hostID, !link.mac.id.isEmpty, !link.token.isEmpty, Data(base64URL: link.serverKeyHash)?.count == 32 else {
            throw MoveFailure.refused("That isn't a link this computer can keep.")
        }
        let confirm = P256.Signing.PrivateKey(), unlock = P256.Signing.PrivateKey()
        let computer = LinkedComputer(id: link.mac.id, name: String(link.mac.name.prefix(100)), os: link.mac.os, endpoints: link.endpoints,
                                      pin: link.serverKeyHash, token: link.token, relay: link.relay, deviceID: link.deviceID,
                                      deviceSecret: link.deviceSecret, device: device, confirm: confirm.rawRepresentation, unlock: unlock.rawRepresentation,
                                      linked: now())
        guard !computer.addresses.isEmpty || computer.route != nil else { throw MoveFailure.refused("That link names no address this computer can dial.") }
        let replaced = try await links.keep(computer)
        try await daemon.devices.update(device) { $0.computer = link.mac.id; $0.name = String(link.mac.name.prefix(100)) }
        // One link per computer: the device an older one let in goes.
        for old in replaced { await daemon.revoke(old) }
        await engine.refresh(force: true)
        return ComputerLinked(confirmKey: confirm.publicKey.x963Representation.base64URL, unlockKey: unlock.publicKey.x963Representation.base64URL)
    }

    /// `DELETE /v1/computers/{id}` from the device `device`. True when that device is to be revoked: it was the way that
    /// computer came in, or it names that computer.
    func unlinked(_ id: String, by device: String) async -> Bool {
        let named = await daemon?.devices.device(id: device)?.computer == id
        let dropped: Bool
        do { dropped = try await links.dropped(id, by: device) } catch {
            DaemonLog.line("couldn't save the linked computers: \(error)")
            dropped = false
        }
        if dropped { await engine.refresh(force: true) }
        return dropped || named
    }

    /// `sidead unlink`: forgets the computer here at once, tells it so it forgets this one too, then closes its way in.
    func unlink(_ text: String) async throws -> LinkedComputer {
        guard let computer = await links.find(text) else { throw MoveFailure.refused("No linked computer is called \(text).") }
        try await links.remove(computer.id)
        await engine.refresh(force: true)
        // Its own token is what lets it be told, so the device is revoked only after.
        do { try await LinkedPeer(computer).unlink(daemon?.config.hostID ?? "") } catch { DaemonLog.line("unlink: \(computer.name) couldn't be told") }
        if let device = computer.device { await daemon?.revoke(device) }
        return computer
    }

    /// The second half of a link made from this side (the Mac's `LinkedComputers.finish`), once this computer has paired
    /// with the other as a client: keep its token, make it a device here, and send it the way back. `sidead` itself
    /// is linked to from the other computer (`sidead pair`), so only a client that paired on its behalf calls this.
    func link(paired: PairResponse, endpoints: Endpoints, pin: String, secret: Data, confirm: Data, unlock: Data) async throws -> LinkedComputer {
        guard let daemon else { throw MoveFailure.refused("\(me().name) is still starting.") }
        let token = DeviceToken.make()
        let device = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64URL
        let back = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let row = PairedDevice(id: device, name: String(paired.mac.name.prefix(100)), model: paired.mac.kind == .macos ? "Mac" : "Computer", system: "", app: "",
                               build: 0, hash: DeviceToken.hash(token), secretHash: Data(SHA256.hash(data: back)).base64URL, pushKey: nil, pushKeyID: nil,
                               confirmKey: nil, unlockKey: nil, push: nil, capabilities: [.computer, .moves], created: now(), lastSeen: nil, computer: paired.mac.id)
        try await daemon.devices.add(row, replacing: nil)
        daemon.relay?.devicesChanged(await daemon.devices.devices)
        let relay = daemon.relay.map { RelayInfo(url: $0.url.absoluteString, installID: $0.installID, keyID: "") }
        let link = ComputerLink(mac: daemon.me, endpoints: daemon.hello(paired: true).endpoints, serverKeyHash: daemon.identity.spkiHash, relay: relay,
                                token: token, deviceID: device, deviceSecret: back.base64URL)
        let computer = LinkedComputer(id: paired.mac.id, name: paired.mac.name, os: paired.mac.os, endpoints: endpoints, pin: pin, token: paired.token,
                                      relay: paired.relay, deviceID: paired.deviceID, deviceSecret: secret.base64URL, device: device, confirm: confirm,
                                      unlock: unlock, linked: now())
        do {
            let keys = try await LinkedPeer(computer).link(link)
            try await daemon.devices.update(device) { $0.confirmKey = SideADaemon.p256(keys.confirmKey); $0.unlockKey = SideADaemon.p256(keys.unlockKey) }
        } catch {
            await daemon.revoke(device)
            throw MoveFailure.refused("\(computer.name) didn't finish the link.")
        }
        for old in try await links.keep(computer) { await daemon.revoke(old) }
        await engine.refresh(force: true)
        return computer
    }

    func computers() async -> [LinkedComputer] { await links.all }

    // MARK: Moving from the phone and from `sidead move`

    /// The session and the computer a phone or the command named. One that arrived here and whose agent has exited since
    /// is still this computer's to move: Bring Back names its conversation.
    private func target(_ session: String, _ computer: String) async throws -> (row: LiveRow, peer: any MovePeer) {
        guard let link = await links.find(computer) else { throw MoveFailure.refused("That computer isn't linked to \(me().name).") }
        var row = await engine.row(session)
        if row == nil { row = await ended(session) }
        guard let row else { throw MoveFailure.refused("That session isn't running on \(me().name).") }
        return (row, peerFor(link))
    }

    /// What a move would do, asked of both computers before anything is stopped.
    func preview(_ session: String, to computer: String) async throws -> MovePreview {
        let (row, peer) = try await target(session, computer)
        let plan = try await prepare(row, to: peer)
        await withdraw(plan, from: peer)
        let login: MovePreview.Login? = switch (plan.answer.account, plan.hands) {
        case (.here?, _): .there
        case (_, true): .sent
        case (.wanted?, false), (.missing?, false): .other
        default: nil
        }
        let wire = await links.computer(peer.id)?.wire ?? RemoteComputer(id: peer.id, name: peer.name)
        return MovePreview(computer: wire, landing: plan.answer.landing, permissionMode: plan.answer.permissionMode, account: plan.offer.account?.name, login: login)
    }

    /// Starts a move and returns as soon as both computers have agreed: the rest runs on, and `GET /v1/moves` follows it.
    func begin(_ session: String, to computer: String) async throws -> MoveRecord {
        let (row, peer) = try await target(session, computer)
        let plan = try await prepare(row, to: peer)
        let record = MoveRecord(id: plan.offer.id, conversationID: plan.conversation, agent: row.agent, title: plan.offer.title, project: plan.offer.project,
                                state: .moving, computer: peer.id, computerName: peer.name, at: now())
        sending[plan.offer.id] = record
        Task { [self] in
            do { _ = try await run(plan, to: peer) } catch { DaemonLog.line("move \(plan.offer.id): \(Self.sentence(error, peer: peer.name))") }
        }
        return record
    }

    /// `sidead move`: the whole move, to its end.
    func move(_ session: String, to computer: String) async throws -> MoveState {
        let (row, peer) = try await target(session, computer)
        return try await run(try await prepare(row, to: peer), to: peer)
    }

    /// Sessions this host is sending, has sent and not got back, or lost track of, newest first, and moves that failed in
    /// the last ten minutes.
    func records() -> [MoveRecord] {
        var out: [MoveRecord] = [], seen = Set<String>()
        for entry in journal.all where entry.role == .source {
            guard let state = Self.state(of: entry) else { continue }
            out.append(Self.record(entry, state))
            seen.insert(entry.id)
        }
        for (id, pending) in sending where seen.insert(id).inserted { out.append(pending) }
        let since = now() - 600
        for (id, failed) in failures where failed.at >= since && seen.insert(id).inserted {
            guard let entry = failed.entry ?? journal[id] else { continue }
            out.append(Self.record(entry, .failed, message: failed.message, at: failed.at))
        }
        return out.sorted { $0.at > $1.at }
    }

    func moveRecord(_ id: String) -> MoveRecord? { records().first { $0.id == id } }

    /// `sidead move --all`: every hosted session that has finished its turn goes to `computer`, one at a time (the Mac's
    /// Move All). Says which went and, for each that stayed, why.
    func moveAll(to computer: String) async throws -> (moved: [String], stayed: [(title: String, reason: String)]) {
        guard let link = await links.find(computer) else { throw MoveFailure.refused("That computer isn't linked to \(me().name).") }
        let peer = peerFor(link)
        let ready = await engine.live().filter { Self.refusal($0) == nil }
        guard !ready.isEmpty else { throw MoveFailure.refused("No hosted session here has finished its turn.") }
        var moved: [String] = [], stayed: [(title: String, reason: String)] = []
        for listed in ready {
            let title = listed.title ?? listed.name ?? "One session"
            // Read again: the moves before this one took minutes, and the session may have started a turn meanwhile.
            guard let row = await engine.row(listed.key) else { continue }
            do {
                _ = try await run(try await prepare(row, to: peer), to: peer)
                moved.append(title)
            } catch { stayed.append((title, Self.sentence(error, peer: peer.name))) }
        }
        return (moved, stayed)
    }

    /// Run Here: a move whose start the other computer never confirmed is started here again (the Mac's Run Here). The
    /// other computer is asked to drop it first; when it answers that the session runs there, or is starting, nothing
    /// starts here, which is where this differs from the Mac, which starts it anyway. Returns the conversation id.
    func runHere(_ id: String) async throws -> String {
        guard let entry = journal[id], entry.role == .source, entry.step == .unknown || entry.step == .committing, !inFlight.contains(id) else {
            throw MoveFailure.refused("That isn't a move whose outcome is unknown.")
        }
        if let link = await links.computer(entry.peer), let there = try? await peerFor(link).abort(id) {
            switch there.status {
            case .live:
                await settle(only: id)
                throw MoveFailure.refused("It's running on \(entry.peerName).")
            case .starting:
                throw MoveFailure.refused("It's starting on \(entry.peerName). Ask again in a moment.")
            default: break
            }
        }
        guard journal[id]?.step == .unknown || journal[id]?.step == .committing else {
            throw MoveFailure.refused(journal[id]?.step == .away ? "It's running on \(entry.peerName)." : "It's running here again.")
        }
        await restore(entry, ranHere: true)
        return entry.session
    }

    /// Asks the other computer again about a move whose outcome is open, then says where it stands.
    func check(_ id: String) async -> MoveRecord? {
        if !inFlight.contains(id) { await settle(only: id) }
        if let record = moveRecord(id) { return record }
        guard let entry = journal[id], entry.role == .source, entry.step == .returned else { return nil }
        return Self.record(entry, .failed, message: "It's running here again.", at: entry.updatedAt)
    }

    static func state(of entry: MoveJournal.Entry) -> MoveRecord.State? {
        switch entry.step {
        case .prepared, .held, .sent, .committing: .moving
        case .away: .away
        case .unknown: .unknown
        default: nil
        }
    }

    static func record(_ entry: MoveJournal.Entry, _ state: MoveRecord.State, message: String? = nil, at: Double? = nil) -> MoveRecord {
        MoveRecord(id: entry.id, conversationID: entry.session, agent: AgentProvider(rawValue: entry.agent) ?? .claude, title: entry.title,
                   project: entry.project, state: state, computer: entry.peer, computerName: entry.peerName, at: at ?? entry.updatedAt,
                   session: entry.remote, message: message)
    }
}
