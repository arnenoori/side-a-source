import Foundation
import SideACore
import SideAProtocol

/// Moving sessions between the user's computers (docs/remote/protocol.md, "Moves: a session goes to another computer"):
/// receiving one from a linked computer, linking, and sending one from the phone or `sidead move`. Host-to-host routes
/// answer only a device that paired as a computer.
public final class MoveServices: DaemonServices {
    let moves: DaemonMoves
    private let loop = AccountServices.TaskBox()
    /// How often a move whose outcome is open is asked about again.
    private let settleEvery: Duration
    /// How often checkpoints go to the standby, besides when a turn ends, and old ones kept here are dropped.
    private let standbyEvery: Duration
    private let standbyLoop = AccountServices.TaskBox()

    /// `state` is the daemon's state folder (the journal and the links go there, 0600); `landing` is where a repository
    /// this computer lacks is cloned; `repositories` are folders to look for one in first. `hooks` must be the ones the
    /// sessions' settings carry.
    public init(state: URL, sessions: SessionServices, book: AccountBook, selector: AccountSelector = .configDir, landing: URL, repositories: [String],
                location: BridgeLocation, links: ComputerLinks? = nil, hooks: MoveHooks? = nil, settleEvery: Duration = .seconds(60),
                standbyEvery: Duration = .seconds(60)) {
        self.settleEvery = settleEvery
        self.standbyEvery = standbyEvery
        let engine = sessions.engine
        let settings = engine.settings
        let store = FileSecretStore(directory: state)
        let places = DaemonMoves.Places(root: settings.root, landing: landing, repositories: repositories, environment: settings.environment)
        let home = settings.environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? book.home
        let logins = DaemonLogins(book: book, selector: selector, home: home, environment: settings.environment,
                                  held: settings.root.appendingPathComponent("runtime/moves/logins"))
        moves = DaemonMoves(places: places, engine: engine, links: links ?? ComputerLinks(store: store), logins: logins, location: location, store: store)
        (hooks ?? settings.moves)?.attach(moves)
    }

    public var capabilities: Set<Capability> { [.moves, .standby] }

    public func snapshot(into parts: StateParts) async -> StateParts { parts }

    public func start(_ daemon: SideADaemon) async {
        await moves.attach(daemon)
        let moves = moves, every = settleEvery
        // What a restart or a lost answer left open is finished first, then asked about again now and then.
        loop.set(Task {
            await moves.settle()
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                if Task.isCancelled { return }
                await moves.settle()
            }
        })
        let standbyEvery = standbyEvery
        standbyLoop.set(Task {
            await moves.dropOldCheckpoints()
            while !Task.isCancelled {
                try? await Task.sleep(for: standbyEvery)
                if Task.isCancelled { return }
                await moves.checkpointAll()
                await moves.dropOldCheckpoints()
            }
        })
    }

    public func stop() async {
        loop.cancel()
        standbyLoop.cancel()
    }

    static let notComputer = HTTPResponse.apiError(403, .notComputer, "Only a linked computer can do that.")

    static func isComputer(_ context: RouteContext) async -> Bool {
        await context.daemon.devices.device(id: context.device)?.isComputer == true
    }

    static func refused(_ error: any Error) -> HTTPResponse {
        let known = error is MoveFailure || error is BridgeFailure || error is HostedTmux.Failure
        return .apiError(409, .moveRefused, known ? DaemonMoves.sentence(error, peer: nil) : "The session couldn't be received: \(error.localizedDescription)")
    }

    /// A route for linked computers only, answering `work`'s value or 409 `move_refused`.
    private static func computerOnly<T: Encodable & Sendable>(_ context: RouteContext, _ work: () async throws -> T) async -> HTTPResponse {
        guard await isComputer(context) else { return notComputer }
        do { return Wire.json(200, try await work()) } catch MoveFailure.unknown {
            // Not a refusal: the caller must not conclude the session did not start.
            return .apiError(503, .inProgress, "The session is starting.", retryAfter: 2)
        } catch { return refused(error) }
    }

    /// A standby call from a linked computer: `work`'s answer, or 409 `move_refused`.
    private static func standing(_ context: RouteContext, _ work: () async throws -> HTTPResponse) async -> HTTPResponse {
        guard await isComputer(context) else { return notComputer }
        do { return try await work() } catch { return refused(error) }
    }

    /// The computer the calling device is linked as; empty for one that paired as a computer and has not linked yet.
    static func linkedAs(_ context: RouteContext) async -> String? {
        guard let device = await context.daemon.devices.device(id: context.device), device.isComputer else { return nil }
        return device.computer ?? ""
    }

    public var routes: [DaemonRoute] {
        let moves = moves
        return [
            // Receiving, from a linked computer.
            DaemonRoute("POST", "v1/moves") { context in
                guard let offer = context.body(MoveOffer.self) else { return .badJSON }
                // Who is sending is what its link says, not what the offer claims.
                let linked = await Self.linkedAs(context) ?? ""
                return await Self.computerOnly(context) {
                    guard linked.isEmpty || linked == offer.from.id else { throw MoveFailure.refused("That move names another computer as its sender.") }
                    return try await moves.offered(offer, from: context.device)
                }
            },
            DaemonRoute("POST", "v1/moves/{id}/parts/{name}/{index}") { context in
                guard await Self.isComputer(context) else { return Self.notComputer }
                guard let id = context.params["id"], let name = context.params["name"], let index = context.params["index"].flatMap(Int.init) else { return .badJSON }
                do {
                    try await moves.part(id, name, index, context.request.body)
                    return HTTPResponse(status: 204)
                } catch { return Self.refused(error) }
            },
            DaemonRoute("POST", "v1/moves/{id}/stage") { context in
                guard let stage = context.body(MoveStage.self) else { return .badJSON }
                return await Self.computerOnly(context) { try await moves.stage(context.params["id"] ?? "", stage) }
            },
            DaemonRoute("POST", "v1/moves/{id}/commit") { context in
                let commit = context.request.body.isEmpty ? MoveCommit() : context.body(MoveCommit.self)
                guard let commit else { return .badJSON }
                return await Self.computerOnly(context) { try await moves.commit(context.params["id"] ?? "", commit) }
            },
            DaemonRoute("POST", "v1/moves/{id}/abort") { context in
                await Self.computerOnly(context) { await moves.abort(context.params["id"] ?? "", from: context.device) }
            },
            DaemonRoute("GET", "v1/moves/{id}") { context in
                await Self.computerOnly(context) { await moves.state(context.params["id"] ?? "") }
            },
            // Standby: checkpoints another computer keeps here.
            DaemonRoute("POST", "v1/standby") { context in
                guard let offer = context.body(StandbyOffer.self) else { return .badJSON }
                let linked = await Self.linkedAs(context) ?? ""
                return await Self.standing(context) {
                    guard linked.isEmpty || linked == offer.from.id else { throw MoveFailure.refused("That checkpoint names another computer as its sender.") }
                    return Wire.json(200, try await moves.standbyOffered(offer, from: context.device))
                }
            },
            DaemonRoute("POST", "v1/standby/{id}/parts/{name}/{index}") { context in
                guard let id = context.params["id"], let name = context.params["name"], let index = context.params["index"].flatMap(Int.init) else { return .badJSON }
                return await Self.standing(context) {
                    try await moves.standbyPart(id, name, index, context.request.body, from: context.device)
                    return HTTPResponse(status: 204)
                }
            },
            DaemonRoute("POST", "v1/standby/{id}/keep") { context in
                guard let stage = context.body(MoveStage.self) else { return .badJSON }
                return await Self.standing(context) {
                    try await moves.keep(context.params["id"] ?? "", stage, from: context.device)
                    return HTTPResponse(status: 204)
                }
            },
            DaemonRoute("DELETE", "v1/standby/{id}") { context in
                await Self.standing(context) {
                    await moves.forget(context.params["id"] ?? "", from: context.device)
                    return HTTPResponse(status: 204)
                }
            },
            DaemonRoute("GET", "v1/standby") { _ in Wire.json(200, StandbyList(copies: await moves.copies())) },
            DaemonRoute("POST", "v1/standby/{id}/copy") { context in
                let id = context.params["id"] ?? ""
                // It starts an agent here with another computer's work: Face ID, as a move is.
                let subject = ConfirmMessage.subject(action: .copyStandby, target: id)
                if let refused = await context.daemon.confirm(context.request, device: context.device, purpose: .action, subject: subject, needs: .biometric) {
                    return refused
                }
                do { return Wire.json(201, try await moves.continueCopy(of: id)) } catch { return Self.refused(error) }
            },
            // Linking.
            DaemonRoute("POST", "v1/computers") { context in
                guard let link = context.body(ComputerLink.self) else { return .badJSON }
                // A device speaks for one computer: the one it first named, and never this one.
                guard let named = await Self.linkedAs(context), named.isEmpty || named == link.mac.id, link.mac.id != context.daemon.config.hostID else {
                    return Self.notComputer
                }
                do { return Wire.json(200, try await moves.accept(link, device: context.device)) } catch { return Self.refused(error) }
            },
            DaemonRoute("DELETE", "v1/computers/{id}") { context in
                guard await Self.isComputer(context) else { return Self.notComputer }
                let device = context.device, daemon = context.daemon
                if await moves.unlinked(context.params["id"] ?? "", by: device) {
                    // After the answer: the caller's own token is what it was sent with.
                    Task { await daemon.revoke(device) }
                }
                return HTTPResponse(status: 204)
            },
            DaemonRoute("GET", "v1/computers") { _ in
                Wire.json(200, ComputerList(computers: await moves.computers().map(\.wire)))
            },
            // The phone's.
            DaemonRoute("GET", "v1/moves") { _ in Wire.json(200, MoveList(moves: await moves.records())) },
            DaemonRoute("POST", "v1/moves/{id}/check") { context in
                guard let record = await moves.check(context.params["id"] ?? "") else { return .apiError(404, .noMove, "This computer isn't sending that session.") }
                return Wire.json(200, record)
            },
            DaemonRoute("POST", "v1/sessions/{id}/move/preview") { context in
                guard let request = context.body(MoveRequest.self) else { return .badJSON }
                do { return Wire.json(200, try await moves.preview(context.params["id"] ?? "", to: request.computer)) } catch { return Self.refused(error) }
            },
            DaemonRoute("POST", "v1/sessions/{id}/move") { context in
                guard let request = context.body(MoveRequest.self) else { return .badJSON }
                let id = context.params["id"] ?? ""
                guard let subject = try? ConfirmMessage.subject(action: .moveSession, target: id, body: request) else { return .badJSON }
                // The session leaves this computer and may take its login with it: Face ID, never the unlock key.
                if let refused = await context.daemon.confirm(context.request, device: context.device, purpose: .action, subject: subject, needs: .biometric) {
                    return refused
                }
                do { return Wire.json(202, try await moves.begin(id, to: request.computer)) } catch { return Self.refused(error) }
            },
        ]
    }

    // MARK: The control socket

    public func control(_ command: String, _ arguments: [String: String]) async -> Data? {
        let answer: [String: Any]
        switch command {
        case "computers":
            let list = await moves.computers().map { computer -> [String: Any] in
                ["id": computer.id, "name": computer.name, "os": computer.os?.rawValue ?? "", "address": computer.endpoints.tailnet, "linked": computer.linked]
            }
            answer = ["ok": true, "computers": list]
        case "unlink":
            do {
                let gone = try await moves.unlink(arguments["computer"] ?? "")
                answer = ["ok": true, "unlinked": gone.name]
            } catch { answer = ["ok": false, "error": DaemonMoves.sentence(error, peer: nil)] }
        case "move":
            do {
                let state = try await moves.move(arguments["session"] ?? "", to: arguments["computer"] ?? "")
                answer = ["ok": true, "session": state.session ?? "", "folder": state.folder ?? "", "account": state.account ?? ""]
            } catch MoveFailure.unknown(let peer) {
                answer = ["ok": false, "unknown": true, "error": MoveFailure.unknown(peer: peer).description]
            } catch { answer = ["ok": false, "error": DaemonMoves.sentence(error, peer: nil)] }
        case "moves":
            let list = await moves.records().map { record -> [String: Any] in
                ["id": record.id, "state": record.state.rawValue, "computer": record.computerName, "title": record.title ?? "", "message": record.message ?? ""]
            }
            answer = ["ok": true, "moves": list]
        case "move-all":
            do {
                let (moved, stayed) = try await moves.moveAll(to: arguments["computer"] ?? "")
                answer = ["ok": true, "moved": moved, "stayed": stayed.map { ["title": $0.title, "reason": $0.reason] }]
            } catch { answer = ["ok": false, "error": DaemonMoves.sentence(error, peer: nil)] }
        case "run-here":
            do {
                let conversation = try await moves.runHere(arguments["move"] ?? "")
                answer = ["ok": true, "conversation": conversation]
            } catch { answer = ["ok": false, "error": DaemonMoves.sentence(error, peer: nil)] }
        case "config":
            do {
                let key = arguments["key"] ?? "", computers = await moves.computers()
                var settings = await moves.settings()
                if !key.isEmpty {
                    settings = try await moves.configure(key, arguments["value"] ?? "")
                    // Standby pointed elsewhere or turned off: what the old one holds is deleted now, not in a minute.
                    if key == "standby" { Task { [moves] in await moves.checkpointAll() } }
                }
                answer = ["ok": true, "settings": settings.lines(computers: computers)]
            } catch { answer = ["ok": false, "error": DaemonMoves.sentence(error, peer: nil)] }
        default:
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
    }
}
