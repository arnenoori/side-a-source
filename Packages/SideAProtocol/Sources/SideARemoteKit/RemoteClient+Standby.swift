import Foundation
import SideAProtocol

extension RemoteClient {
    /// The host answers a copy only once it runs: the work is put in place and the agent started before the 201.
    public static let copyWaits: TimeInterval = 120

    /// The checkpoints this host keeps of other computers' sessions (capability `standby`).
    public func standby() async throws -> StandbyList { try await get("/v1/standby") }

    /// Continues the checkpoint of `conversationID` here as a copy: a fork with a new conversation id, because the computer
    /// it came from cannot be told and may still be running the original. `confirm` signs `ConfirmMessage.subject(action:
    /// .copyStandby, target: conversationID)` with the confirm key after Face ID; the unlock key is refused. 201 with the
    /// state `live`, the hosted session's name and its folder; 409 `move_refused`, whose message is the sentence to show.
    public func continueCopy(_ conversationID: String, confirm: String,
                             idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> MoveState {
        var request = try await request("POST", "/v1/standby/\(conversationID)/copy", idempotencyKey: idempotencyKey)
        request.setValue(confirm, forHTTPHeaderField: ConfirmSignature.header)
        request.timeoutInterval = Self.copyWaits
        return try JSONDecoder().decode(MoveState.self, from: try await send(request).0)
    }
}
