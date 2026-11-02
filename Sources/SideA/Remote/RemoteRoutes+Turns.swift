import Foundation
import SideACore
import SideAProtocol

extension RemoteRoutes {
    /// `GET /v1/sessions/{id}/turns/{turnID}/diff`.
    @Sendable static func turnDiff(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? "", turn = context.params["turnID"] ?? ""
        return await command(context) { commands throws(SessionCommands.Failure) in try await commands.turnDiff(id, turn: turn) }
    }

    /// `POST /v1/sessions/{id}/compact`: 204 once Codex has started it.
    @Sendable static func compact(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        if let refused = await refusal(context, .compact, target: id) { return refused }
        return empty(await command(context, status: 204) { commands throws(SessionCommands.Failure) in try await commands.compact(id); return Empty() })
    }

    /// `POST /v1/sessions/{id}/review {target}`.
    @Sendable static func review(_ context: Context) async -> HTTPResponse {
        guard let request = context.body(ReviewRequest.self) else { return badJSON }
        let id = context.params["id"] ?? ""
        if let refused = await refusal(context, .review, target: id, body: request) { return refused }
        return empty(await command(context, status: 204) { commands throws(SessionCommands.Failure) in try await commands.review(id, request); return Empty() })
    }

    struct Empty: Encodable, Sendable {}

    /// A 204 has no body.
    private static func empty(_ response: HTTPResponse) -> HTTPResponse { response.status == 204 ? HTTPResponse(status: 204) : response }
}
