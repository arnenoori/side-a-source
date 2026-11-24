import Foundation
import SideACore
import SideAProtocol

/// What a Codex terminal session runs with: the models its daemon offers, and changing model, effort and mode.
extension CodexTerminals {
    /// The models the session's daemon offers, read once per connection.
    func models(_ live: LiveSession) async throws(Failure) -> [CodexAppServer.Model] {
        guard let (link, client, _) = link(of: live) else { throw .notAttached }
        if let models = link.models { return models }
        var models: [CodexAppServer.Model] = []
        var cursor: CodexAppServer.JSON = .null
        do {
            repeat {
                let page = try await client.call("model/list", .object(["cursor": cursor]))
                models += page["data"]?.array?.compactMap(CodexAppServer.Model.init) ?? []
                cursor = page["nextCursor"] ?? .null
            } while cursor != .null
        } catch {
            throw Self.failure(error)
        }
        if link.client === client { link.models = models }
        return models
    }

    /// Changes what the session's next turns run with; the TUI's footer follows. A model without the effort the
    /// session has takes the model's default, as the TUI's own picker does.
    func change(_ live: LiveSession, model: String? = nil, effort: String? = nil, mode: String? = nil) async throws(Failure) {
        guard let (link, client, thread) = link(of: live) else { throw .notAttached }
        guard link.settable else { throw .unsupported }
        guard let current = link.threads[thread]?.settings else { throw .notAttached }
        let raises = [CodexAppServer.Settings.neverMode, CodexAppServer.Settings.fullAccessMode]
        if let mode, !CodexAppServer.modes.contains(mode), !raises.contains(mode) { throw .invalid("Codex has no \(mode) mode.") }
        var effort = effort
        if model != nil || effort != nil {
            let models = try await models(live)
            let name = model ?? current.model
            // A model the account doesn't list (a custom provider's) takes any effort the user picks.
            if let chosen = models.first(where: { $0.id == name }) {
                if let wanted = effort, !chosen.efforts.contains(wanted) { throw .invalid("\(chosen.name) has no \(wanted) effort.") }
                if effort == nil, let had = current.effort, !chosen.efforts.contains(had) { effort = chosen.defaultEffort }
            } else if model != nil {
                throw .invalid("This Codex account doesn't offer \(name).")
            }
        }
        // A raise sets the approval or sandbox policy; default lowers one back to what the session ran with before it.
        var updates: [CodexAppServer.JSON] = []
        if let mode, raises.contains(mode) {
            updates.append(current.raise(thread: thread, to: mode))
            if model != nil || effort != nil { updates.append(current.update(thread: thread, model: model, effort: effort, mode: nil)) }
        } else {
            if mode == "default", current.raised {
                guard let base = link.threads[thread]?.base else {
                    throw .invalid("Side A doesn't know what this session ran with before full access. Change it in the terminal.")
                }
                updates.append(CodexAppServer.Settings.lower(thread: thread, to: base))
            }
            if model != nil || effort != nil || mode != nil {
                updates.append(current.update(thread: thread, model: model, effort: effort, mode: mode))
            }
        }
        do {
            for update in updates { _ = try await client.call("thread/settings/update", update) }
        } catch AppServerClient.Failure.rpc(let error) where error.unknownMethod {
            link.settable = false
            RemoteLog.shared("codex app server at \(link.home): no thread/settings/update")
            store?.remote.events?.liveChanged()
            throw .unsupported
        } catch {
            throw Self.failure(error)
        }
    }
}
