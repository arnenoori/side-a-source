import CryptoKit
import Foundation
import SideACore
import SideAProtocol

/// The REST routes. The server has already checked Host, Origin, rate limits, the token and the idempotency key;
/// handlers hop to the main actor only for app state and return wire values.
enum RemoteRoutes {
    struct Context: Sendable {
        let request: HTTPRequest
        let caller: RemoteServer.Caller
        let params: [String: String]
        let controller: RemoteController

        var device: String { caller.device ?? "" }

        func body<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: request.body) }
    }

    typealias Handle = @Sendable (Context) async -> HTTPResponse

    /// Nil when the request proves `needs`; otherwise what to answer. Every route that needs a signature asks here before
    /// it has any effect.
    static func refusal(_ context: Context, _ purpose: ConfirmPurpose, subject: String, needs: ConfirmProof) async -> HTTPResponse? {
        #if DEBUG
        if let check = await MainActor.run(body: { context.controller.confirmCheck }) { return check(context.request, context.device, purpose, subject, needs) }
        #endif
        guard let server = await MainActor.run(body: { context.controller.server }) else { return notReady }
        return server.confirm(context.request, device: context.device, purpose: purpose, subject: subject, needs: needs)
    }

    static func refusal(_ context: Context, _ action: ConfirmAction, target: String = "", needs: ConfirmProof = .unlock) async -> HTTPResponse? {
        await refusal(context, .action, subject: ConfirmMessage.subject(action: action, target: target), needs: needs)
    }

    static func refusal(_ context: Context, _ action: ConfirmAction, target: String = "", body: some Encodable, needs: ConfirmProof = .unlock) async -> HTTPResponse? {
        guard let subject = try? ConfirmMessage.subject(action: action, target: target, body: body) else { return badJSON }
        return await refusal(context, .action, subject: subject, needs: needs)
    }

    /// What a session's own mode asks for, or the answer when there's no session to ask: nothing goes on unsigned.
    static func sessionProof(_ context: Context, _ id: String) async -> Result<ConfirmProof, Unproven> {
        await MainActor.run {
            guard let store = context.controller.store else { return .failure(Unproven(response: notReady)) }
            guard let mode = SessionCommands(store: store).permissionMode(id) else { return .failure(Unproven(response: noSession)) }
            return .success(ConfirmProof(ConfirmPolicy.session(mode: mode)))
        }
    }

    struct Unproven: Error { let response: HTTPResponse }

    struct Route: Sendable {
        let method: String
        let pattern: [String]
        let handle: Handle
        init(_ method: String, _ path: String, _ handle: @escaping Handle) {
            self.method = method; pattern = path.split(separator: "/").map(String.init); self.handle = handle
        }
    }

    static func handler(_ controller: RemoteController) -> RemoteServer.Handler {
        { [weak controller] request, caller in
            guard let controller else { return RemoteServer.error(503, "remote_off", "Remote is off.", retryAfter: 5) }
            return await route(request, caller, controller)
        }
    }

    static func route(_ request: HTTPRequest, _ caller: RemoteServer.Caller, _ controller: RemoteController) async -> HTTPResponse {
        var methods: [String] = []
        for route in routes {
            guard let params = match(route.pattern, request.path) else { continue }
            guard route.method == request.method else { methods.append(route.method); continue }
            return tagged(await route.handle(Context(request: request, caller: caller, params: params, controller: controller)), request)
        }
        guard methods.isEmpty else {
            var response = RemoteServer.error(405, "bad_request", "\(request.method) isn't served here.")
            response.headers.add("Allow", methods.joined(separator: ", "))
            return response
        }
        return RemoteServer.error(404, "not_found", "There's nothing at \(request.path.joined(separator: "/")).")
    }

    /// A JSON GET carries its body's hash as an ETag; a phone that already has that body gets a 304 and no bytes.
    static func tagged(_ response: HTTPResponse, _ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET", response.status == 200, response.headers["ETag"] == nil,
              response.headers["Content-Type"] == "application/json" else { return response }
        let tag = "\"\(Data(SHA256.hash(data: response.body).prefix(16)).base64URL)\""
        var headers = HTTPHeaders([("ETag", tag), ("Cache-Control", "private, no-cache")])
        let known = request.headers["If-None-Match"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        if known.contains(where: { $0 == "*" || $0 == tag || $0 == "W/" + tag }) { return HTTPResponse(status: 304, headers: headers) }
        for field in response.headers.fields { headers.add(field.name, field.value) }
        return HTTPResponse(status: 200, headers: headers, body: response.body)
    }

    static func match(_ pattern: [String], _ path: [String]) -> [String: String]? {
        guard pattern.count == path.count else { return nil }
        var params: [String: String] = [:]
        for (part, segment) in zip(pattern, path) {
            if part.hasPrefix("{") { params[String(part.dropFirst().dropLast())] = segment } else if part != segment { return nil }
        }
        return params
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        guard let data = try? encoder.encode(value) else { return RemoteServer.error(500, "internal", "Side A couldn't encode the answer.") }
        return .json(status, data)
    }

    static let badJSON = RemoteServer.error(400, "bad_json", "The request body isn't what this route takes.")

    // MARK: Table

    static let routes: [Route] = [
        Route("GET", "v1/hello") { context in
            let caller = context.caller
            return json(200, await MainActor.run { context.controller.hello(paired: caller.device != nil ? true : caller.rejected ? false : nil) })
        },
        Route("POST", "v1/pair", pair),
        Route("POST", "v1/pair/{attempt}/wait", wait),
        Route("DELETE", "v1/pair/{attempt}", cancelPairing),
        Route("DELETE", "v1/devices/self") { context in
            await MainActor.run { context.controller.revoke(context.device) }
            return HTTPResponse(status: 204)
        },
    ] + RemoteRoutes.appRoutes + RemoteRoutes.rotationRoutes

    // MARK: Pairing

    @Sendable static func pair(_ context: Context) async -> HTTPResponse {
        guard let request = context.body(PairRequest.self) else { return badJSON }
        return await MainActor.run {
            guard let session = context.controller.pairing, let spki = context.controller.spki else {
                return RemoteServer.error(404, "no_pairing", "Open Settings > iPhone on the Mac and click Pair iPhone.")
            }
            let source = RemotePolicy.budget(context.caller.source)
            switch session.submit(request, spki: spki, source: source) {
            case .success(let pending): return json(202, pending)
            case .failure(.wrong):
                return RemoteServer.error(401, "bad_code", "That code isn't right. Check it on the Mac.",
                                          details: ["triesLeft": String(session.code.triesLeft(source))])
            case .failure(.expired): return RemoteServer.error(410, "code_expired", "That code has expired. Start again on the Mac.")
            case .failure(.busy): return RemoteServer.error(409, "code_busy", "Two devices used this code. Start again on the Mac.")
            }
        }
    }

    @Sendable static func wait(_ context: Context) async -> HTTPResponse {
        let id = context.params["attempt"] ?? ""
        guard let session = await MainActor.run(body: { context.controller.pairing }), await session.knows(id) else {
            return RemoteServer.error(404, "no_pairing", "This pairing attempt isn't open on the Mac.")
        }
        switch await session.wait(id, connection: context.caller.connection) {
        case .pair:
            guard let response = await MainActor.run(body: { context.controller.completePairing(id) }) else {
                return RemoteServer.error(410, "code_expired", "This pairing attempt was already used. Start again on the Mac.")
            }
            return json(201, response)
        case .cancel: return RemoteServer.error(403, "declined", "Pairing was cancelled on the Mac.")
        case .mismatch: return RemoteServer.error(403, "sas_mismatch", "The codes didn't match, so pairing stopped.")
        case .timeout: return RemoteServer.error(408, "confirm_timeout", "Nobody clicked Pair on the Mac in time.")
        }
    }

    /// The phone's Cancel. 204 whatever the attempt, so the answer says nothing about which exist.
    @Sendable static func cancelPairing(_ context: Context) async -> HTTPResponse {
        let id = context.params["attempt"] ?? ""
        await MainActor.run { context.controller.pairing?.cancel(id) }
        return HTTPResponse(status: 204)
    }
}
