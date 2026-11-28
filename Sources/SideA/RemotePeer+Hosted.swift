import Foundation
import SideAProtocol
import SideARemoteKit

/// Start There: the routes a phone uses to see and start hosted sessions, called on a linked computer by the person at
/// this one. Each signature is made at the level the other computer asks a phone for.
extension RemotePeer {
    func options() async throws -> [AgentOptions] { try await client.options().agents }

    func projects() async throws -> [RemoteProject] { try await client.projects().projects }

    /// Its hosted sessions; none when it has no tmux, as a computer with hosting off answers.
    func hosted() async throws -> [HostedSession] {
        do {
            return try await client.hosted().hosted
        } catch let failure as RemoteFailure where failure.error.code == .tmuxMissing {
            return []
        }
    }

    func startHosted(_ start: StartHosted) async throws -> HostedSession {
        let confirm = try signature(.settings, subject: try ConfirmMessage.subject(start: start), faceID: ConfirmPolicy.start(start) == .biometric)
        return try await client.post("/v1/hosted", json: start, confirm: confirm)
    }

    func endHosted(_ name: String) async throws {
        try await client.endHosted(name, confirm: try signature(.action, subject: ConfirmMessage.subject(action: .endHosted, target: name), faceID: false))
    }

    /// The terminal stream of `name`. Opening it needs the key that stands for the person at this computer, which a
    /// terminal always takes because keys typed there run as the user.
    func terminal(_ name: String, viewer: String, outbox: Outbox) -> TerminalSession {
        let peer = self
        return TerminalSession(client: client, name: name, viewer: viewer, outbox: outbox) { name in
            do {
                return try peer.signature(.terminal, subject: ConfirmMessage.subject(terminal: name), faceID: true)
            } catch {
                RemoteLog.shared("terminal: no key to open \(name) on \(peer.name)")
                return nil
            }
        }
    }

    /// What to tell the person at this Mac when a call to the other computer failed: its own words when it answered.
    func sentence(_ error: any Error) -> String {
        if case MoveFailure.refused(let message) = error { return message }
        guard let failure = error as? RemoteFailure else { return "\(name) can’t be reached." }
        if [.unauthorized, .confirmRequired, .confirmInvalid].contains(failure.error.code) || failure.status == 401 {
            return "\(name) didn’t let this Mac in. Link it again in Remote settings."
        }
        return failure.error.message
    }
}
