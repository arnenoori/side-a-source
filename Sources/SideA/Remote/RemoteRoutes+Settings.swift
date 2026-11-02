import Foundation
import SideACore
import SideAProtocol

extension RemoteRoutes {
    /// `POST /v1/sessions/{id}/settings`, signed: unlocked for a model, effort or mode, Face ID for a mode that raises.
    @Sendable static func changeSettings(_ context: Context) async -> HTTPResponse {
        guard let change = context.body(SettingsChange.self) else { return badJSON }
        let id = context.params["id"] ?? ""
        let subject: String
        do { subject = try ConfirmMessage.subject(sessionID: id, settings: change) } catch { return noSession }
        guard let server = await MainActor.run(body: { context.controller.server }) else { return notReady }
        if let refusal = server.confirm(context.request, device: context.device, purpose: .settings, subject: subject,
                                        needs: change.raises ? .biometric : .unlock) {
            return refusal
        }
        return await command(context) { commands throws(SessionCommands.Failure) in try await commands.settings(id, change) }
    }

    /// `GET /v1/models?kind=claude|codex[&session=<id>]`: a Codex session's own daemon lists its account's models;
    /// otherwise what `/v1/options` offers.
    @Sendable static func models(_ context: Context) async -> HTTPResponse {
        guard let agent = AgentProvider(rawValue: context.request.query["kind"] ?? "claude") else {
            return RemoteServer.error(400, "bad_request", "kind is claude or codex.")
        }
        let session = context.request.query["session"]
        let live = await command(context) { commands throws(SessionCommands.Failure) in try await commands.models(agent, session: session) }
        // A list from the daemon, or a failure; null falls through to the catalog.
        if live.status != 200 || live.body != Data("null".utf8) { return live }
        guard let options = await agentOptions(context) else { return notReady }
        return json(200, ModelList(agent: agent, models: options.first { $0.agent == agent }?.models ?? []))
    }
}
