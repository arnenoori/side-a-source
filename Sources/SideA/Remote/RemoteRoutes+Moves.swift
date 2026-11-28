import Foundation
import SideACore
import SideAProtocol

/// A session arriving from another of the user's computers (docs/remote/protocol.md, "Moves").
extension RemoteRoutes {
    static let moveRoutes: [Route] = [
        Route("POST", "v1/moves", offerMove),
        Route("POST", "v1/moves/{id}/parts/{name}/{index}", movePart),
        Route("POST", "v1/moves/{id}/stage", stageMove),
        Route("POST", "v1/moves/{id}/commit", commitMove),
        Route("POST", "v1/moves/{id}/abort", abortMove),
        Route("GET", "v1/moves/{id}", moveState),
        Route("GET", "v1/moves", listMoves),
        Route("POST", "v1/moves/{id}/check", checkMove),
        Route("DELETE", "v1/moves/{id}", cancelMove),
        Route("POST", "v1/sessions/{id}/move/preview", previewMove),
        Route("POST", "v1/sessions/{id}/move", startMove),
        Route("POST", "v1/standby", offerStandby),
        Route("POST", "v1/standby/{id}/parts/{name}/{index}", standbyPart),
        Route("POST", "v1/standby/{id}/keep", keepStandby),
        Route("POST", "v1/standby/{id}/copy", copyStandby),
        Route("DELETE", "v1/standby/{id}", forgetStandby),
        Route("GET", "v1/standby", listStandby),
    ]

    private static func moving<T: Encodable & Sendable>(_ context: Context, _ work: @escaping @MainActor (Moves) async throws -> T) async -> HTTPResponse {
        await onMainAsync(context) { _ in
            guard isComputer(context) else { return notComputer }
            do {
                return json(200, try await work(context.controller.moves))
            } catch MoveFailure.unknown {
                // Not a refusal: the caller must not conclude the session did not start.
                return RemoteServer.error(503, .inProgress, "The session is starting.", retryAfter: 2)
            } catch let failure as MoveFailure {
                return RemoteServer.error(409, .moveRefused, failure.errorDescription ?? "The session can't move here.")
            } catch {
                return RemoteServer.error(409, .moveRefused, "The session couldn't be received: \(error.localizedDescription)")
            }
        }
    }

    @Sendable static func offerMove(_ context: Context) async -> HTTPResponse {
        guard let offer = context.body(MoveOffer.self) else { return badJSON }
        return await moving(context) {
            // Who is sending is what its link says, not what the offer claims.
            let linked = context.controller.devices.devices.first { $0.id == context.device }?.computer ?? ""
            guard linked.isEmpty || linked == offer.from.id else { throw MoveFailure.refused("That move names another computer as its sender.") }
            return try await $0.offered(offer, from: context.device)
        }
    }

    @Sendable static func movePart(_ context: Context) async -> HTTPResponse {
        guard let id = context.params["id"], let name = context.params["name"], let index = context.params["index"].flatMap(Int.init) else { return badJSON }
        let data = context.request.body
        return await onMainAsync(context) { _ in
            guard isComputer(context) else { return notComputer }
            do {
                try context.controller.moves.part(id, name, index, data)
                return HTTPResponse(status: 204)
            } catch {
                return RemoteServer.error(409, .moveRefused, Moves.sentence(error, peer: nil))
            }
        }
    }

    @Sendable static func stageMove(_ context: Context) async -> HTTPResponse {
        guard let stage = context.body(MoveStage.self) else { return badJSON }
        let id = context.params["id"] ?? ""
        return await moving(context) { try await $0.stage(id, stage) }
    }

    @Sendable static func commitMove(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        let commit = context.request.body.isEmpty ? MoveCommit() : context.body(MoveCommit.self)
        guard let commit else { return badJSON }
        return await moving(context) { try await $0.commit(id, commit) }
    }

    @Sendable static func abortMove(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        return await moving(context) { await $0.abort(id, from: context.device) }
    }

    @Sendable static func moveState(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        return await moving(context) { $0.state(id) }
    }

    // MARK: From the phone

    @Sendable static func listMoves(_ context: Context) async -> HTTPResponse {
        await onMainAsync(context) { _ in json(200, MoveList(moves: context.controller.moves.records())) }
    }

    @Sendable static func checkMove(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        return await onMainAsync(context) { _ in
            guard let record = await context.controller.moves.check(id) else { return RemoteServer.error(404, .noMove, "That move is over.") }
            return json(200, record)
        }
    }

    /// Cancels a move that is waiting for its session's turn to end. It only keeps a session here, so it needs no signature.
    @Sendable static func cancelMove(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        return await onMainAsync(context) { _ in
            switch context.controller.moves.cancel(id) {
            case .cancelled: return HTTPResponse(status: 204)
            case .started: return RemoteServer.error(409, .moveRefused, "It has started moving, so it can't be cancelled.")
            case .none: return RemoteServer.error(404, .noMove, "That move is over.")
            }
        }
    }

    /// The session and the linked computer a phone's move names, or the answer when either is missing.
    @MainActor private static func moveTarget(_ context: Context, _ store: AccountStore, _ request: MoveRequest) async -> Result<(LiveSession, RemotePeer, HostOS?), Unproven> {
        let id = context.params["id"] ?? ""
        let controller = context.controller
        // One that arrived here and whose agent has exited since is still this Mac's to move: Bring Back names its conversation.
        var live = Target(id, store: store)?.live
        if live == nil { live = await controller.moves.ended(id) }
        guard let live else { return .failure(Unproven(response: noSession)) }
        guard let peer = controller.computers.peer(request.computer, me: controller.mac) else {
            return .failure(Unproven(response: RemoteServer.error(404, .notFound, "That computer isn't linked to this Mac.")))
        }
        return .success((live, peer, controller.computers.all.first { $0.id == request.computer }?.endpoint.os))
    }

    @MainActor private static func refused(_ error: any Error) -> HTTPResponse {
        RemoteServer.error(409, .moveRefused, Moves.sentence(error, peer: nil))
    }

    @Sendable static func previewMove(_ context: Context) async -> HTTPResponse {
        guard let request = context.body(MoveRequest.self) else { return badJSON }
        return await onMainAsync(context) { store in
            switch await moveTarget(context, store, request) {
            case .failure(let missing): return missing.response
            case .success(let (live, peer, os)):
                do { return json(200, try await context.controller.moves.preview(live, to: peer, os: os, when: request.when ?? .idle)) } catch { return refused(error) }
            }
        }
    }

    @Sendable static func startMove(_ context: Context) async -> HTTPResponse {
        guard let request = context.body(MoveRequest.self) else { return badJSON }
        // A move stops a session here and starts it on another computer, with whatever it may do there: Face ID.
        if let refused = await refusal(context, .moveSession, target: context.params["id"] ?? "", body: request, needs: .biometric) { return refused }
        return await onMainAsync(context) { store in
            switch await moveTarget(context, store, request) {
            case .failure(let missing): return missing.response
            case .success(let (live, peer, _)):
                do { return json(202, try await context.controller.moves.request(live, to: peer, when: request.when ?? .idle)) } catch { return refused(error) }
            }
        }
    }

    // MARK: Standby

    /// A standby call from a linked computer: 204, or the refusal.
    private static func standing(_ context: Context, _ work: @escaping @MainActor (Moves) async throws -> HTTPResponse) async -> HTTPResponse {
        await onMainAsync(context) { _ in
            guard isComputer(context) else { return notComputer }
            do { return try await work(context.controller.moves) } catch { return refused(error) }
        }
    }

    @Sendable static func offerStandby(_ context: Context) async -> HTTPResponse {
        guard let offer = context.body(StandbyOffer.self) else { return badJSON }
        return await standing(context) { json(200, try await $0.standbyOffered(offer, from: context.device)) }
    }

    @Sendable static func standbyPart(_ context: Context) async -> HTTPResponse {
        guard let id = context.params["id"], let name = context.params["name"], let index = context.params["index"].flatMap(Int.init) else { return badJSON }
        let data = context.request.body
        return await standing(context) { try $0.standbyPart(id, name, index, data, from: context.device); return HTTPResponse(status: 204) }
    }

    @Sendable static func keepStandby(_ context: Context) async -> HTTPResponse {
        guard let stage = context.body(MoveStage.self) else { return badJSON }
        let id = context.params["id"] ?? ""
        return await standing(context) { try $0.keep(id, stage, from: context.device); return HTTPResponse(status: 204) }
    }

    @Sendable static func forgetStandby(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        return await standing(context) { $0.forget(id, from: context.device); return HTTPResponse(status: 204) }
    }

    @Sendable static func listStandby(_ context: Context) async -> HTTPResponse {
        await onMainAsync(context) { _ in json(200, StandbyList(copies: context.controller.moves.copies())) }
    }

    @Sendable static func copyStandby(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        // It starts an agent here with another computer's work: Face ID, as a move is.
        if let refused = await refusal(context, .copyStandby, target: id, needs: .biometric) { return refused }
        return await onMainAsync(context) { _ in
            do { return json(201, try await context.controller.moves.continueCopy(of: id)) } catch { return refused(error) }
        }
    }
}
