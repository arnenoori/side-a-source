import Foundation
import SideACore
import SideAProtocol

/// A session's model, effort and mode, and the models to pick from. Each agent has its own driver: a Claude session
/// Side A hosts types into its own pickers, for this session only; a Codex session on its app server changes them for
/// its next turns. Anything else says why not.
extension SessionCommands {
    /// Fast mode: Claude Code saves every mid-session toggle as the user's default (2.1.303).
    nonisolated static let fastRefusal = "Fast mode can't change for one session without becoming your default. Start a session with it instead."

    func settings(_ id: String, _ change: SettingsChange) async throws(Failure) -> SettingsResult {
        guard let target = Target(id, store: store), let live = target.live else { throw .noSession }
        if live.provider == .claude, let name = live.hosted { return try await claudeSettings(target, name: name, change) }
        if live.provider == .codex, store.remote.codex.row(live) != nil { return try await codexSettings(live, change) }
        throw Failure(status: 409, code: "cannot_deliver", message: Self.settingsRefusal(live))
    }

    /// What a Claude session Side A hosts takes typed into it while idle and asking nothing: model, effort and mode (its
    /// pickers, this session only) and compact; fast mode never, as Claude Code would save it as the default. Others
    /// say why.
    nonisolated static func claudeTyped(_ live: LiveSession, status: SessionStatus, asking: Bool) -> (abilities: Set<SessionAbility>, reasons: [String: String]) {
        let typed: [SessionAbility] = [.settingsModel, .settingsEffort, .settingsMode, .compact]
        var reasons = [SessionAbility.settingsFast.rawValue: fastRefusal]
        let busy: String? = asking ? "Answer the open request first."
            : status == .idle || status == .finished ? nil : "Claude is working. Try when it's idle."
        for ability in typed {
            let why = live.hosted == nil ? (ability == .compact ? compactRefusal : settingsRefusal(live)) : busy
            if let why { reasons[ability.rawValue] = why }
        }
        return (Set(typed.filter { reasons[$0.rawValue] == nil }), reasons)
    }

    nonisolated static func settingsRefusal(_ live: LiveSession) -> String {
        live.provider == .claude ? "Changing settings needs a session Side A hosts." : "Changing settings needs a Codex session on Codex's app server."
    }

    /// Hosted Claude, idle and asking nothing: Shift+Tab would answer an open request, and a pick made mid-turn
    /// would land in the middle of its output.
    private func claudeSettings(_ target: Target, name: String, _ change: SettingsChange) async throws(Failure) -> SettingsResult {
        if change.fast != nil { throw Failure(status: 422, code: "invalid_settings", message: Self.fastRefusal) }
        if let effort = change.effort, !Hosting.claudeEfforts.contains(effort.rawValue) {
            throw Failure(status: 422, code: "invalid_settings", message: "Claude can't set \(effort.rawValue) effort for one session.")
        }
        if let mode = change.mode, Hosting.permissionArguments(.claude, mode: mode.rawValue) == nil {
            throw Failure(status: 422, code: "invalid_settings", message: "Claude has no \(mode.rawValue) mode.")
        }
        switch target.state(store.island) {
        case .idle, .finishedWaiting: break
        case .waiting: throw Failure(status: 409, code: "session_waiting", message: "Answer the open request first.")
        default: throw Failure(status: 409, code: "cannot_deliver", message: "Claude is working. Try when it's idle.")
        }
        do {
            let done = try await store.hosted.change(name, model: change.model, effort: change.effort?.rawValue, mode: change.mode?.rawValue)
            return SettingsResult(settings: SessionSettings(model: done.model, effort: done.effort.map(Effort.init(rawValue:)),
                                                            mode: done.mode.map(PermissionMode.init(rawValue:))))
        } catch let error as HostedError {
            throw .hosted(error)
        } catch {
            throw Self.internalFailure("Side A couldn't change that session's settings.")
        }
    }

    private func codexSettings(_ live: LiveSession, _ change: SettingsChange) async throws(Failure) -> SettingsResult {
        let codex = store.remote.codex
        guard let before = codex.row(live), before.settings != nil else {
            throw Failure(status: 409, code: "cannot_deliver", message: Self.settingsRefusal(live))
        }
        guard !before.abilities.isEmpty else {
            throw Failure(status: 409, code: "cannot_deliver", message: before.reasons.values.first ?? Self.settingsRefusal(live))
        }
        if change.fast != nil { throw Failure(status: 422, code: "invalid_settings", message: "Codex has no fast mode.") }
        // The driver owns which modes Codex takes.
        do throws(CodexTerminals.Failure) {
            try await codex.change(live, model: change.model, effort: change.effort?.rawValue, mode: change.mode?.rawValue)
        } catch {
            throw .codex(error)
        }
        // The daemon confirms with thread/settings/updated, which comes just after its answer.
        for _ in 0..<20 where codex.row(live)?.settings == before.settings { try? await Task.sleep(for: .milliseconds(50)) }
        // Codex applies them from the next turn on.
        return SettingsResult(settings: codex.row(live)?.settings ?? before.settings!, nextTurn: true)
    }

    /// Codex's models for the session's home, from its app server; without one, what Codex lists for the default home.
    func models(_ agent: AgentProvider, session id: String?) async throws(Failure) -> ModelList? {
        guard agent == .codex, let id else { return nil }
        guard let live = Target(id, store: store)?.live, live.provider == .codex else { throw .noSession }
        guard store.remote.codex.row(live) != nil else { return nil }
        let models: [CodexAppServer.Model]
        do throws(CodexTerminals.Failure) { models = try await store.remote.codex.models(live) } catch { throw .codex(error) }
        return ModelList(agent: .codex, models: models.map {
            ModelOption(id: $0.id, title: $0.name, agent: .codex, efforts: $0.efforts.map(Effort.init(rawValue:)),
                        defaultEffort: $0.defaultEffort.map(Effort.init(rawValue:)), canChangeEffortMidSession: true, isDefault: $0.isDefault)
        })
    }
}
