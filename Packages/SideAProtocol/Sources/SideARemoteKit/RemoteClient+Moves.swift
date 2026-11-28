import Foundation
import SideAProtocol

extension RemoteClient {
    /// The computers this host can send a session to (capability `moves`).
    public func computers() async throws -> ComputerList { try await get("/v1/computers") }

    /// What moving `session` to `move.computer` would do, asked of both computers; nothing is stopped. 409 `move_refused`,
    /// whose message is the sentence to show.
    public func movePreview(_ session: SessionKey, _ move: MoveRequest) async throws -> MovePreview {
        try await post("/v1/sessions/\(session)/move/preview", json: move)
    }

    /// Sends `session` to `move.computer`. `confirm` signs `ConfirmMessage.subject(action: .moveSession, target: session,
    /// body: move)` with the confirm key after Face ID; the unlock key is refused. 202 with the record in `moving`: the
    /// move then runs on the host, and `moves()` follows it.
    public func move(_ session: SessionKey, _ move: MoveRequest, confirm: String,
                     idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> MoveRecord {
        try await post("/v1/sessions/\(session)/move", json: move, idempotencyKey: idempotencyKey, confirm: confirm)
    }

    /// Sessions this host is sending, has sent and not got back, or lost track of, and moves that failed in the last ten minutes.
    public func moves() async throws -> MoveList { try await get("/v1/moves") }

    /// Cancels a move that is `waiting` for its session's turn to end (capability `moves.when`). 404 `no_move` when it is
    /// over; 409 `move_refused` once it has started.
    public func cancelMove(_ id: String) async throws {
        _ = try await send(try await request("DELETE", "/v1/moves/\(id)", idempotencyKey: UUID().uuidString.lowercased()))
    }

    /// Asks the other computer again where a move stands, for one whose outcome is `unknown`.
    public func checkMove(_ id: String) async throws -> MoveRecord {
        let request = try await request("POST", "/v1/moves/\(id)/check", idempotencyKey: UUID().uuidString.lowercased())
        return try JSONDecoder().decode(MoveRecord.self, from: try await send(request).0)
    }
}
