import Foundation
import SideAProtocol

extension RemoteClient {
    /// Continue on iPhone: the Mac ends its process and resumes the conversation in tmux. Already hosted
    /// answers with that session. 404 `session_not_found`; 409 `cannot_deliver` (working, unknown) or
    /// `tmux_missing`; 502 `not_resumed` when the agent isn't back in 20 seconds.
    public func continueOnPhone(_ session: SessionKey, idempotencyKey: String = UUID().uuidString.lowercased(), confirm: String? = nil) async throws -> HostedSession {
        var request = try await request("POST", "/v1/sessions/\(session)/continue", idempotencyKey: idempotencyKey)
        if let confirm { request.setValue(confirm, forHTTPHeaderField: ConfirmSignature.header) }
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(HostedSession.self, from: data)
    }

    /// Trust and Start: answers the folder-trust dialog of `hosted`, which starts the agent. `confirm` signs
    /// `ConfirmMessage.subject(trust:cwd:)` with the confirm key after Face ID; nothing else is accepted.
    /// 401 `confirm_required` (`details.level = biometric`), 404, 409 `cannot_deliver` when no trust dialog is showing.
    public func trust(_ hosted: HostedSession, confirm: String, idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> HostedSession {
        var request = try await request("POST", "/v1/hosted/\(hosted.name)/trust", idempotencyKey: idempotencyKey)
        request.setValue(confirm, forHTTPHeaderField: ConfirmSignature.header)
        return try JSONDecoder().decode(HostedSession.self, from: try await send(request).0)
    }

    /// Ends a hosted session (`DELETE /v1/hosted/{name}`).
    public func endHosted(_ name: String, confirm: String? = nil) async throws {
        try await signedSend("DELETE", "/v1/hosted/\(name)", confirm: confirm)
    }
}
