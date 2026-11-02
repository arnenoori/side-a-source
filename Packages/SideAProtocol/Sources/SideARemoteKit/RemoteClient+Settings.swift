import Foundation
import SideAProtocol

extension RemoteClient {
    /// Changes a session's model, effort, mode or fast mode. `confirm` signs `ConfirmMessage.subject(sessionID:settings:)`:
    /// the unlock key, or the confirm key after Face ID when the change `raises`. 409 `cannot_deliver` when the session
    /// can't take it now (a hosted Claude mid-turn), with the reason as the message.
    public func settings(_ session: SessionKey, _ change: SettingsChange, confirm: String?,
                         idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> SettingsResult {
        try await post("/v1/sessions/\(session)/settings", json: change, idempotencyKey: idempotencyKey, confirm: confirm)
    }

    /// The models one agent offers; `session` scopes a Codex list to that session's Codex home.
    public func models(_ agent: AgentProvider, session: SessionKey? = nil) async throws -> ModelList {
        try await get("/v1/models", query: [URLQueryItem(name: "kind", value: agent.rawValue)]
                      + (session.map { [URLQueryItem(name: "session", value: $0)] } ?? []))
    }

    /// Everything one turn changed.
    public func turnDiff(_ session: SessionKey, turn: String) async throws -> TurnDiff {
        try await get("/v1/sessions/\(session)/turns/\(turn)/diff")
    }

    /// Compacts an idle session's context.
    public func compact(_ session: SessionKey, confirm: String? = nil) async throws {
        try await signedSend("POST", "/v1/sessions/\(session)/compact", confirm: confirm)
    }

    /// Starts a review of an idle session's changes.
    public func review(_ session: SessionKey, _ review: ReviewRequest = ReviewRequest(), confirm: String? = nil) async throws {
        var request = try await request("POST", "/v1/sessions/\(session)/review", body: try Self.encoder.encode(review),
                                        idempotencyKey: UUID().uuidString.lowercased())
        if let confirm { request.setValue(confirm, forHTTPHeaderField: ConfirmSignature.header) }
        _ = try await send(request)
    }
}
