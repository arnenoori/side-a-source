import SideAProtocol
import SwiftUI

/// Model, Effort and Mode in the session's menu, in the Mac chip's order, and Fast mode where the session takes it. Each is
/// a picker when the session takes that change, else its value and the Mac's reason. A mode that raises asks for Face ID.
struct SettingsMenu: View {
    let session: RemoteSession?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session {
            let settings = model.tools.settings(of: session)
            let models = model.tools.models(for: session)
            let current = models.first { $0.id == settings.model || $0.title == settings.model }
            let busy = actions.isBusy("settings-\(session.id)")
            Section {
                setting("Model", symbol: "cpu", ability: .settingsModel, value: current?.title ?? settings.model.map(ModelName.short),
                        session: session) {
                    Picker(selection: Binding(get: { current?.id ?? "" }, set: { id in
                        change(session, SettingsChange(model: id), title: models.first { $0.id == id }?.title ?? ModelName.short(id))
                    })) {
                        ForEach(models, id: \.id) { Text($0.title).tag($0.id) }
                    } label: {
                        Label("Model", systemImage: "cpu")
                        Text(current?.title ?? "Default")
                    }
                    .disabled(busy)
                }
                let efforts = current?.efforts ?? []
                if !efforts.isEmpty || settings.effort != nil {
                    setting("Effort", symbol: "gauge.with.dots.needle.50percent", ability: efforts.isEmpty ? nil : .settingsEffort,
                            value: settings.effort?.title, session: session) {
                        Picker(selection: Binding(get: { settings.effort ?? current?.defaultEffort ?? .auto }, set: { effort in
                            change(session, SettingsChange(effort: effort), title: "\(effort.title) effort")
                        })) {
                            ForEach(efforts, id: \.self) { Text($0.title).tag($0) }
                        } label: {
                            Label("Effort", systemImage: "gauge.with.dots.needle.50percent")
                            Text((settings.effort ?? current?.defaultEffort)?.title ?? "Default")
                        }
                        .disabled(busy)
                    }
                }
                let mode = settings.mode
                setting("Mode", symbol: "shield.lefthalf.filled", ability: .settingsMode, value: mode?.title, session: session) {
                    Picker(selection: Binding(get: { mode ?? .default }, set: { mode in
                        change(session, SettingsChange(mode: mode), title: mode.title)
                    })) {
                        ForEach(PermissionMode.offered(session.agent, current: mode), id: \.self) { mode in
                            Text(mode.title).accessibilityHint(mode.raises ? "Asks for Face ID" : "")
                        }
                    } label: {
                        Label("Mode", systemImage: "shield.lefthalf.filled")
                        Text((mode ?? .default).title)
                    }
                    .disabled(busy)
                }
                // Claude Code saves a fast toggle as the user's default, so the Mac offers it rarely; like the Mac's
                // chip, it shows only when it does.
                if session.abilities.contains(.settingsFast) {
                    Toggle("Fast Mode", systemImage: "bolt", isOn: Binding(get: { settings.fast ?? false }, set: { fast in
                        change(session, SettingsChange(fast: fast), title: fast ? "fast mode" : "standard speed")
                    }))
                    .disabled(busy)
                }
            }
            .pickerStyle(.menu)
        }
    }

    /// A picker when the session takes the change; else its value, if the Mac read one, with the reason.
    @ViewBuilder
    private func setting(_ title: String, symbol: String, ability: SessionAbility?, value: String?, session: RemoteSession,
                         @ViewBuilder picker: () -> some View) -> some View {
        if let ability, session.abilities.contains(ability) {
            picker()
        } else if let value {
            Button {} label: {
                Label("\(title): \(value)", systemImage: symbol)
                if let reason = ability.flatMap({ session.abilityReasons?[$0.rawValue] }) { Text(reason) }
            }
            .disabled(true)
        }
    }

    private func change(_ session: RemoteSession, _ change: SettingsChange, title: String) {
        actions.on(model).change(session, change, title: title)
    }
}

extension PermissionMode {
    /// The Mac chip's modes and order for each agent, and the session's own if it's another.
    static func offered(_ agent: AgentProvider, current: PermissionMode?) -> [PermissionMode] {
        let modes: [PermissionMode] = agent == .codex ? [.default, .plan] : [.default, .acceptEdits, .plan, .auto, .bypassPermissions]
        guard let current, !modes.contains(current) else { return modes }
        return modes + [current]
    }
}

extension SessionSettings {
    /// These, with `other`'s fields over them.
    func merging(_ other: SessionSettings) -> SessionSettings {
        SessionSettings(model: other.model ?? model, effort: other.effort ?? effort, mode: other.mode ?? mode, fast: other.fast ?? fast)
    }

    /// The fields `row` doesn't say yet; nil once it says them all.
    func pending(over row: SessionSettings?) -> SessionSettings? {
        let left = SessionSettings(model: model == row?.model ? nil : model, effort: effort == row?.effort ? nil : effort,
                                   mode: mode == row?.mode ? nil : mode, fast: fast == row?.fast ? nil : fast)
        return left == SessionSettings() ? nil : left
    }
}

/// As the Mac names a model id it has no title for.
enum ModelName {
    /// "claude-opus-5-5-20260101" reads as "Opus 5.5", "gpt-6.1-sol" as "GPT-6.1 Sol".
    static func short(_ id: String) -> String {
        if id.hasPrefix("gpt-") {
            let parts = id.dropFirst(4).split(separator: "-").map(String.init)
            return "GPT-" + (parts.first ?? "") + parts.dropFirst().map { " " + $0.capitalized }.joined()
        }
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init).filter { $0.count < 8 }
        guard let name = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return name.capitalized + (version.isEmpty ? "" : " " + version)
    }
}
