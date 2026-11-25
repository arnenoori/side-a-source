import Foundation
import SideACore
import SideAProtocol

/// The routes every host serves: hello, the pairing exchange, the device's own revoke, push registration and the state
/// snapshot. What the daemon adds on top (sessions, hosting, accounts) comes from its `DaemonServices`.
extension SideADaemon {
    func coreRoutes(connection: DaemonServer.Connection, rejected: Bool) -> [DaemonRoute] {
        [
            DaemonRoute("GET", "v1/hello") { context in
                let known = !context.device.isEmpty
                return Wire.json(200, context.daemon.hello(paired: known ? true : rejected ? false : nil))
            },
            DaemonRoute("POST", "v1/pair") { [connection] context in await context.daemon.pair(context, source: RemotePolicy.budget(connection.source)) },
            DaemonRoute("POST", "v1/pair/{attempt}/wait") { context in await context.daemon.wait(context) },
            DaemonRoute("DELETE", "v1/pair/{attempt}") { context in
                await context.daemon.pairing.cancel(context.params["attempt"] ?? "")
                return HTTPResponse(status: 204)
            },
            DaemonRoute("DELETE", "v1/devices/self") { context in
                await context.daemon.revoke(context.device)
                return HTTPResponse(status: 204)
            },
            DaemonRoute("POST", "v1/devices/push") { context in
                guard let registration = context.body(PushRegistration.self) else { return .apiError(400, .badJSON, "The request body isn't what this route takes.") }
                _ = try? await context.daemon.devices.update(context.device) { $0.push = registration }
                if let relay = context.daemon.relay, let device = await context.daemon.devices.device(id: context.device) {
                    let daemon = context.daemon
                    Task { await relay.register(device, registration, daemon: daemon) }
                }
                return HTTPResponse(status: 204)
            },
            DaemonRoute("POST", "v1/diagnostics/push") { context in
                guard let relay = context.daemon.relay else { return .apiError(503, .relayUnavailable, "This computer has no notification relay set up.", retryAfter: 60) }
                return Wire.json(200, await relay.test(context.device, daemon: context.daemon))
            },
            DaemonRoute("POST", "v1/diagnostics/push/{id}/received") { context in
                let known = context.daemon.relay?.received(context.params["id"] ?? "", from: context.device) ?? false
                return known ? HTTPResponse(status: 204) : .apiError(404, .notFound, "Side A didn't send that test.")
            },
            DaemonRoute("GET", "v1/state") { context in
                let parts = await context.daemon.parts()
                let hub = context.daemon.hub
                let snapshot = StateSnapshot(seq: await hub.seq, epoch: context.daemon.epoch, sessions: parts.sessions, finished: parts.finished,
                                             requests: parts.requests, hosted: parts.hosted, accounts: parts.accounts)
                return Wire.json(200, snapshot.scoped(to: context.device))
            },
        ]
    }

    func parts() async -> StateParts { await servicesSnapshot() }

    func pair(_ context: RouteContext, source: String) async -> HTTPResponse {
        guard let request = context.body(PairRequest.self) else { return .apiError(400, .badJSON, "The request body isn't what this route takes.") }
        let spki = Secret.base64url(identity.spkiHash) ?? Data()
        switch await pairing.submit(request, spki: spki, source: source) {
        case .success(let pending): return Wire.json(202, pending)
        case .failure(.closed): return .apiError(404, .noPairing, "Run `sidead pair` on the computer first.")
        case .failure(.wrong(let left)):
            return .apiError(401, .badCode, "That code isn't right. Check it on the computer.", details: ["triesLeft": String(left)])
        case .failure(.expired): return .apiError(410, .codeExpired, "That code has expired. Start again on the computer.")
        case .failure(.busy): return .apiError(409, .codeBusy, "Two devices used this code. Start again on the computer.")
        }
    }

    func wait(_ context: RouteContext) async -> HTTPResponse {
        let id = context.params["attempt"] ?? ""
        guard await pairing.knows(id) else { return .apiError(404, .noPairing, "This pairing attempt isn't open on the computer.") }
        switch await pairing.wait(id) {
        case .pair:
            guard let response = await completePairing(id) else {
                return .apiError(410, .codeExpired, "This pairing attempt was already used. Start again on the computer.")
            }
            return Wire.json(201, response)
        case .cancel: return .apiError(403, .declined, "Pairing was cancelled on the computer.")
        case .mismatch: return .apiError(403, .sasMismatch, "The codes didn't match, so pairing stopped.")
        case .timeout: return .apiError(408, .confirmTimeout, "Nobody confirmed on the computer in time.")
        }
    }
}
