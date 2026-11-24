import Foundation
import SideACore
import SideAProtocol

extension RemoteRoutes {
    /// Pairing auth only, like a transcript: the prompt is what the phone could already read in the new session.
    @Sendable static func handoffPrompt(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        guard HandoffLinks.valid(id) else { return RemoteServer.error(404, .notFound, "There's no handoff by that id.") }
        return await onMainAsync(context) { store in
            let links = HandoffLinks.of(store)
            await links.loaded(store)
            guard let text = links.sentPrompt(id) else {
                return RemoteServer.error(404, .notFound, "The Mac no longer has that handoff. It keeps them 30 days.")
            }
            return json(200, HandoffPrompt(id: id, text: text))
        }
    }

    /// The paths of the photos a handoff names, among what this phone uploaded itself, or the refusal that starts nothing.
    @Sendable static func handoffImages(_ context: Context, _ body: RestartRequest) async -> (paths: [String], refusal: HTTPResponse?) {
        let ids = body.attachments ?? []
        if ids.isEmpty { return ([], nil) }
        if ids.count > 10 { return ([], invalidReply("Attach at most ten photos.", "too_many")) }
        guard let root = await MainActor.run(body: { context.controller.store?.root }),
              let images = RemoteUploads.paths(ids, root: root, device: context.device) else {
            return ([], invalidReply("A photo for this handoff is no longer on the Mac. Attach it again.", "unknown_upload"))
        }
        return (images, nil)
    }

    /// Before anything is signed or started, the answers that need no session.
    static func handoffRefusal(_ body: RestartRequest) -> HTTPResponse? {
        if (body.message ?? "").count > SessionCommands.maxReply {
            return invalidReply("Your message alone is longer than a reply can be. Shorten it first.", "too_long")
        }
        return nil
    }
}
