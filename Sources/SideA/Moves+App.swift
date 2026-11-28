import CryptoKit
import Foundation
import SideACore
import SideAProtocol
import SideARemoteKit

/// Another computer running Side A that this one may send sessions to and take them from. Linking gives each a
/// token for the other's server, which is the standing a paired phone has: it can start sessions, so a linked
/// computer can run commands on the other. Tokens and keys are kept in the Keychain with the paired devices.
struct LinkedComputer: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var endpoint: Endpoint
    let token: String
    let linked: Double
    /// What this computer shows the relay to reach the other through its tunnel, when no address answers.
    var secret: Data?
    /// This computer's signing keys for calls to the other (P-256, raw): the stand-ins for a phone's two keys.
    var confirm: Data?
    var unlock: Data?
    /// The device here that the other computer calls in as.
    var device: String?
    /// The device id this computer is known by there, which its signatures name.
    var me: String?
}

/// The two switches under Settings > Remote > Computers.
enum MoveSettings {
    static let acceptsKey = "moves.accepts", envKey = "moves.includesEnv", standbyKey = "moves.standby"
    // swiftlint:disable:next user_defaults_standard -- this type owns the two settings
    private static var defaults: UserDefaults { UserDefaults.standard }
    static var accepts: Bool { defaults.object(forKey: acceptsKey) as? Bool ?? true }
    static var includesEnv: Bool { defaults.bool(forKey: envKey) }
    /// The linked computer checkpoints go to; empty for none.
    static var standby: String? { defaults.string(forKey: standbyKey).flatMap { $0.isEmpty ? nil : $0 } }
}

@MainActor @Observable
final class LinkedComputers {
    /// A link waiting for the person at the other computer to compare the digits and click Pair.
    struct Pending: Sendable {
        let code: String
        let name: String
        fileprivate let client: PairingClient
        fileprivate let attempt: PairingClient.Attempt
        fileprivate let confirm: Data
        fileprivate let unlock: Data
    }

    enum Failure: LocalizedError {
        case badLink, oneWay(String), off
        var errorDescription: String? {
            switch self {
            case .badLink: "That isn't a Side A pairing link. Copy it from Remote settings on the other computer."
            case .oneWay(let name): "\(name) didn't finish the link. Update Side A there and link again."
            case .off: "Turn on Remote on this Mac first, so the other computer can reach it."
            }
        }
    }

    private(set) var all: [LinkedComputer] = []
    @ObservationIgnored private let keychain: RemoteKeychain

    init(keychain: RemoteKeychain) {
        self.keychain = keychain
        do {
            if let data = try keychain.readComputers() { all = try JSONDecoder().decode([LinkedComputer].self, from: data) }
        } catch { RemoteLog.shared("couldn't read the linked computers: \(error.localizedDescription)") }
    }

    private func save() throws { try keychain.writeComputers(try JSONEncoder().encode(all)) }

    /// A computer speaks the protocol its own server serves, so it is never too old a client for a host of the
    /// same or an older release; the build gate exists for phone releases.
    static func client(_ me: MacInfo) -> ClientInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ClientInfo(version: info["CFBundleShortVersionString"] as? String ?? "0",
                          build: max(Int(info["CFBundleVersion"] as? String ?? "") ?? 0, RemotePolicy.minClientBuild),
                          system: "macOS \(os.majorVersion).\(os.minorVersion)", capabilities: [.computer, .moves, .gzip, .hosted])
    }

    /// Starts linking with the pairing link shown on the other computer. The digits in the answer are shown here
    /// too, for the person to compare there.
    func begin(link: String, me: MacInfo) async throws -> Pending {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), let invitation = PairingClient.Invitation(url: url) else { throw Failure.badLink }
        let info = Self.client(me)
        let device = DeviceInfo(name: me.name, model: "Mac", system: info.system, app: info.version, build: info.build, capabilities: info.capabilities)
        let confirm = P256.Signing.PrivateKey(), unlock = P256.Signing.PrivateKey()
        let client = PairingClient(invitation: invitation, device: device, replaces: nil, confirmKey: confirm.publicKey.x963Representation.base64URL,
                                   unlockKey: unlock.publicKey.x963Representation.base64URL)
        let attempt = try await client.start(info: info)
        return Pending(code: attempt.comparisonCode, name: invitation.macName ?? "the other computer", client: client, attempt: attempt,
                       confirm: confirm.rawRepresentation, unlock: unlock.rawRepresentation)
    }

    /// Waits for the other computer to accept, then gives it the same way back into this one and keeps the link.
    func finish(_ pending: Pending, controller: RemoteController) async throws -> LinkedComputer {
        let paired = try await pending.client.wait(pending.attempt)
        var computer = LinkedComputer(id: paired.response.mac.id, name: paired.response.mac.name, endpoint: paired.endpoint,
                                      token: paired.response.token, linked: Date().timeIntervalSince1970, secret: paired.deviceSecret,
                                      confirm: pending.confirm, unlock: pending.unlock, me: paired.response.deviceID)
        let back = try controller.admit(paired.response.mac)
        computer.device = back.device
        do {
            let keys = try await RemotePeer(computer, info: Self.client(controller.mac)).link(back.link)
            _ = try controller.devices.update(back.device) { $0.confirmKey = RemoteController.p256(keys.confirmKey); $0.unlockKey = RemoteController.p256(keys.unlockKey) }
            controller.devicesChanged()
        } catch {
            controller.revoke(back.device)
            throw Failure.oneWay(computer.name)
        }
        try keep(computer, controller: controller)
        return computer
    }

    /// The other computer linked to this one and sent the way back to it.
    func accept(_ link: ComputerLink, device: String, controller: RemoteController) throws -> ComputerLinked {
        guard let address = URL(string: "https://\(link.endpoints.tailnet)") else { throw Failure.badLink }
        let relay = link.relay.flatMap { relay in URL(string: relay.url).flatMap { RelayRoute.allowed($0) ? RelayRoute(url: $0, installID: relay.installID, deviceID: link.deviceID) : nil } }
        let endpoint = Endpoint(macID: link.mac.id, baseURL: address, serverKeyHash: link.serverKeyHash, name: link.mac.name, relay: relay, os: link.mac.os)
            .updated(with: link.endpoints)
        let confirm = P256.Signing.PrivateKey(), unlock = P256.Signing.PrivateKey()
        try keep(LinkedComputer(id: link.mac.id, name: link.mac.name, endpoint: endpoint, token: link.token, linked: Date().timeIntervalSince1970,
                                secret: Secret.base64url(link.deviceSecret), confirm: confirm.rawRepresentation, unlock: unlock.rawRepresentation, device: device, me: link.deviceID),
                 controller: controller)
        _ = try controller.devices.update(device) { $0.computer = link.mac.id; $0.name = String(link.mac.name.prefix(100)) }
        return ComputerLinked(confirmKey: confirm.publicKey.x963Representation.base64URL, unlockKey: unlock.publicKey.x963Representation.base64URL)
    }

    /// One link per computer: an older one, and the device it let in, are replaced.
    private func keep(_ computer: LinkedComputer, controller: RemoteController) throws {
        for old in all where old.id == computer.id { if let device = old.device, device != computer.device { controller.revoke(device) } }
        all.removeAll { $0.id == computer.id }
        all.append(computer)
        try save()
    }

    func cancel(_ pending: Pending) async { await pending.client.cancel(attempt: pending.attempt) }

    /// Unlinks here at once, and tells the other computer so it forgets this one too.
    func remove(_ id: String, controller: RemoteController) {
        guard let computer = all.first(where: { $0.id == id }) else { return }
        let peer = RemotePeer(computer, info: Self.client(controller.mac)), me = controller.mac.id
        all.removeAll { $0.id == id }
        do { try save() } catch { RemoteLog.shared("couldn't save the linked computers: \(error.localizedDescription)") }
        Task {
            // Its own token is what lets it be told, so the device is revoked only after.
            do { try await peer.unlink(me) } catch { RemoteLog.shared("unlink: \(computer.name) couldn't be told") }
            if let device = computer.device { controller.revoke(device) }
        }
    }

    /// The other computer unlinked: forget it. True when `device` was its way in here.
    func dropped(_ id: String, by device: String) -> Bool {
        guard all.contains(where: { $0.id == id && $0.device == device }) else { return false }
        all.removeAll { $0.id == id }
        do { try save() } catch { RemoteLog.shared("couldn't save the linked computers: \(error.localizedDescription)") }
        return true
    }

    func peer(_ id: String, me: MacInfo) -> RemotePeer? {
        all.first { $0.id == id }.map { RemotePeer($0, info: Self.client(me)) }
    }
}

extension RemoteController {
    /// Makes the other computer a device of this one and says how it reaches this one: the second half of a link.
    func admit(_ computer: MacInfo) throws -> (link: ComputerLink, device: String) {
        guard let spki, let endpoints else { throw LinkedComputers.Failure.off }
        let relay = installID.flatMap { install in relayURL.map { RelayInfo(url: $0.absoluteString, installID: install, keyID: "") } }
        let made = Self.invitation(for: computer, from: mac, endpoints: endpoints, spki: spki, relay: relay)
        try devices.add(made.device, replacing: nil)
        devicesChanged()
        return (made.link, made.device.id)
    }

    /// A fresh token, device id and relay secret for `computer`, as the device row kept here and the link sent there.
    static func invitation(for computer: MacInfo, from me: MacInfo, endpoints: Endpoints, spki: Data, relay: RelayInfo?) -> (link: ComputerLink, device: RemoteDevice) {
        let token = DeviceToken.make(), id = Data(Secret.bytes(16)).base64URL, secret = Data(Secret.bytes(32))
        let row = RemoteDevice(id: id, name: String(computer.name.prefix(100)), model: computer.kind == .macos ? "Mac" : "Computer", system: "", app: "", build: 0,
                               hash: DeviceToken.hash(token), secretHash: Data(SHA256.hash(data: secret)).base64URL,
                               created: Date().timeIntervalSince1970, lastSeen: nil, computer: computer.id)
        return (ComputerLink(mac: me, endpoints: endpoints, serverKeyHash: spki.base64URL, relay: relay, token: token, deviceID: id, deviceSecret: secret.base64URL), row)
    }
}

/// A linked computer reached over its Remote server: pinned TLS on the tailnet, the LAN or the relay tunnel.
struct RemotePeer: MovePeer {
    private struct Token: CredentialStore {
        let token: String
        let secret: Data?
        func token(for macID: String) async throws -> String? { token }
        func setToken(_ token: String?, for macID: String) async throws {}
        func relaySecret(for macID: String) async throws -> Data? { secret }
    }
    private struct Nothing: Encodable {}

    let id: String
    let name: String
    let client: RemoteClient
    private let computer: LinkedComputer

    init(_ computer: LinkedComputer, info: ClientInfo, transport: (any Transport)? = nil) {
        id = computer.id; name = computer.name; self.computer = computer
        client = RemoteClient(endpoint: computer.endpoint, credentials: Token(token: computer.token, secret: computer.secret), transport: transport, info: info)
    }

    /// An answer from the other computer that says no is a refusal; anything else (no answer, a busy server, a
    /// reply this build can't read) leaves the outcome open and is thrown as it came.
    func answered<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let failure as RemoteFailure where failure.error.code == .moveRefused || [400, 401, 403, 404, 405, 413, 426].contains(failure.status) {
            throw MoveFailure.refused(failure.error.message)
        }
    }

    /// A signature for a call the other computer wants one on, made with this computer's keys for it. `faceID`
    /// stands for the person at this computer having asked for exactly this.
    func signature(_ purpose: ConfirmPurpose, subject: String, faceID: Bool) throws -> String {
        guard let raw = faceID ? computer.confirm : computer.unlock, let device = computer.me else {
            throw MoveFailure.refused("Link \(name) again to do that.")
        }
        let at = Int(Date().timeIntervalSince1970)
        let text = try ConfirmMessage.text(macID: id, deviceID: device, purpose: purpose, subject: subject, at: at)
        let signature = try P256.Signing.PrivateKey(rawRepresentation: raw).signature(for: Data(text.utf8))
        return ConfirmSignature(at: at, signer: faceID ? .confirm : .unlock, signature: signature.derRepresentation).headerValue
    }

    /// Asks the other computer to send a session it is running to `me`, as the person at this computer.
    func bring(_ conversation: String, to me: String) async throws -> MoveRecord {
        let request = MoveRequest(computer: me)
        let confirm = try signature(.action, subject: ConfirmMessage.subject(action: .moveSession, target: conversation, body: request), faceID: true)
        return try await answered { try await client.post("/v1/sessions/\(RemoteClient.segment(conversation))/move", json: request, confirm: confirm) }
    }

    func link(_ link: ComputerLink) async throws -> ComputerLinked {
        try await client.post("/v1/computers", json: link, idempotencyKey: "link-\(link.deviceID)")
    }

    func unlink(_ me: String) async throws {
        let request = try await client.request("DELETE", "/v1/computers/\(RemoteClient.segment(me))", idempotencyKey: UUID().uuidString.lowercased())
        _ = try await client.send(request)
    }

    private func path(_ move: String, _ rest: String = "") -> String { "/v1/moves/\(RemoteClient.segment(move))\(rest)" }

    // Each request carries a key made from the move, so one sent twice is answered once.
    func offer(_ offer: MoveOffer) async throws -> MoveAnswer {
        try await answered { try await client.post("/v1/moves", json: offer, idempotencyKey: "\(offer.id)-offer") }
    }
    func part(_ move: String, _ name: String, _ index: Int, _ data: Data) async throws {
        try await answered {
            let request = try await client.request("POST", path(move, "/parts/\(RemoteClient.segment(name))/\(index)"), body: data,
                                                   contentType: "application/octet-stream", idempotencyKey: "\(move)-\(name)-\(index)")
            _ = try await client.send(request)
        }
    }
    func stage(_ move: String, _ stage: MoveStage) async throws -> MoveState {
        try await answered { try await client.post(path(move, "/stage"), json: stage, idempotencyKey: "\(move)-stage") }
    }
    func commit(_ move: String, _ commit: MoveCommit) async throws -> MoveState {
        try await answered { try await client.post(path(move, "/commit"), json: commit, idempotencyKey: "\(move)-commit") }
    }
    func abort(_ move: String) async throws -> MoveState {
        try await answered { try await client.post(path(move, "/abort"), json: Nothing(), idempotencyKey: "\(move)-abort") }
    }
    func state(_ move: String) async throws -> MoveState {
        try await answered { try await client.get(path(move)) }
    }
}

extension Moves {
    /// The app's own: its hosted sessions, its bridge, the CLIs' real folders, and its linked computers.
    static func forApp(_ controller: RemoteController) -> Moves {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = controller.store?.root ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let hosted = controller.store?.hosted ?? HostedSessions(root: root, bridge: { _ in Data() })
        let places = Places(claudeProjects: home.appendingPathComponent(".claude/projects"),
                            codexStores: [home.appendingPathComponent(".codex/sessions"), root.appendingPathComponent("codex-conversations/sessions")],
                            landing: home.appendingPathComponent("Side A"))
        let moves = Moves(root: root, hosted: hosted, places: places, me: { [weak controller] in controller?.mac ?? MacInfo(id: "", name: "This Mac") },
                          bridge: { [weak controller] request in
                              guard let store = controller?.store, let python = store.python, let script = store.bridgeURL else {
                                  throw BridgeFailure(message: "Install Python 3 to move sessions.")
                              }
                              let run = await ProcessRunner.run(python, [script.path, "--root", store.root.path, "move"], input: request,
                                                                timeout: BridgeDeadline.current(300), group: true)
                              if let failure = run.launchError { throw failure }
                              guard run.status == 0 else { throw BridgeFailure(stderr: String(decoding: run.errors, as: UTF8.self)) }
                              return run.output
                          }, live: { [weak controller] in await controller?.store?.sessions.freshLive() })
        moves.peer = { [weak controller] id in controller.flatMap { $0.computers.peer(id, me: $0.mac) } }
        if let store = controller.store { moves.logins = AppLogins(store: store, folder: moves.folder) { [weak moves] request in try await moves?.ask(request) ?? [:] } }
        moves.includesEnv = { MoveSettings.includesEnv }
        moves.accepts = { MoveSettings.accepts }
        moves.standbyPeer = { MoveSettings.standby }
        // Stop Now's own path, so a phone's replies the turn hadn't read go back to it unsent.
        moves.interrupt = { [weak controller] session in
            guard let store = controller?.store else { throw MoveFailure.refused("Side A isn't ready yet.") }
            await store.sessions.refreshLive()
            do throws(SessionCommands.Failure) { _ = try await SessionCommands(store: store).interrupt(WireBuilders.key(session), when: .now) } catch {
                throw MoveFailure.refused(error.message)
            }
        }
        moves.sleep = { [weak controller] in controller?.store?.keepAwake.sleepNow() }
        moves.tell = { [weak controller] message in controller?.store?.error = message }
        moves.seat = { [weak controller] session in
            guard let store = controller?.store, let environment = ProcessEnvironment.read(pid: pid_t(session.pid)) else { return Seat() }
            if session.provider == .codex {
                return Seat(codexAccount: store.accountID(codexHome: ProcessEnvironment.codexHome(environment, root: store.root.path, home: home.path)))
            }
            return Seat(pin: environment["SIDE_A_PIN"].flatMap { $0.isEmpty ? nil : $0 })
        }
        return moves
    }
}

extension RemotePeer: StandbyPeer {
    private func standbyPath(_ rest: String) -> String { "/v1/standby/\(rest)" }

    func standby(_ offer: StandbyOffer) async throws -> MoveAnswer {
        try await answered { try await client.post("/v1/standby", json: offer, idempotencyKey: "\(offer.id)-offer") }
    }

    func standbyPart(_ id: String, _ name: String, _ index: Int, _ data: Data) async throws {
        try await answered {
            let request = try await client.request("POST", standbyPath("\(RemoteClient.segment(id))/parts/\(RemoteClient.segment(name))/\(index)"), body: data,
                                                   contentType: "application/octet-stream", idempotencyKey: "\(id)-\(name)-\(index)")
            _ = try await client.send(request)
        }
    }

    func keep(_ id: String, _ stage: MoveStage) async throws {
        try await answered {
            let request = try await client.request("POST", standbyPath("\(RemoteClient.segment(id))/keep"), body: try JSONEncoder().encode(stage),
                                                   contentType: "application/json", idempotencyKey: "\(id)-keep")
            _ = try await client.send(request)
        }
    }

    func forget(_ conversation: String) async throws {
        try await answered {
            let request = try await client.request("DELETE", standbyPath(RemoteClient.segment(conversation)), idempotencyKey: UUID().uuidString.lowercased())
            _ = try await client.send(request)
        }
    }
}
