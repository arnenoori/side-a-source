import Foundation
import SideAProtocol

extension RemoteClient {
    /// Unsigned, as a pin is: it changes only where the session is listed. 409 `session_waiting` while it asks something.
    public func snooze(_ session: SessionKey, _ snooze: SnoozeRequest) async throws -> RemoteSession {
        try await post("/v1/sessions/\(session)/snooze", json: snooze)
    }
}
