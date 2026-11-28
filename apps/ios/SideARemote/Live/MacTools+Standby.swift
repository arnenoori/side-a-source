import Foundation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared

extension MacTools {
    func loadStandby() async {
        guard isLive, can(.standby), let client = try? await client() else { return }
        do { standby.set(try await client.standby().copies) } catch { RemoteLog.log(.sync, "standby not read: \(MacTools.message(error))") }
    }

    /// Face ID only: the host takes nothing else for a copy, so the unlock key is never tried first. The host answers once the
    /// copy runs, naming its hosted session, which opens here as soon as the host lists it.
    func continueCopy(_ copy: StandbyCopy) async throws -> HostedSession {
        let state: MoveState
        if isDemo {
            guard let demo = standby.demo else { throw ToolError.demo }
            state = try await demo.continueCopy(copy.conversationID)
        } else {
            let confirm = try await faceID(.action, subject: ConfirmMessage.subject(action: .copyStandby, target: copy.conversationID),
                                           reason: "Continue \u{201C}\(StandbyText.title(copy))\u{201D} as a copy")
            let key = standby.key.sending(copy.conversationID)
            do {
                state = try await signed {
                    let client = try await client()
                    return try await client.reaching { try await client.continueCopy(copy.conversationID, confirm: confirm, idempotencyKey: key) }
                }
            } catch let failure as RemoteFailure {
                standby.key.answered()
                throw failure
            }
            standby.key.answered()
        }
        guard let name = state.session else { throw ToolError.gone }
        return HostedSession(name: name, agent: copy.agent, cwd: state.folder ?? "", project: copy.project ?? StandbyText.title(copy),
                             createdAt: Date.now.timeIntervalSince1970)
    }
}

extension AppModel {
    /// The checkpoints this host's list shows: only from a host that keeps them.
    var standbyRows: [StandbyCopy] { tools.can(.standby) ? tools.standby.copies : [] }
}
