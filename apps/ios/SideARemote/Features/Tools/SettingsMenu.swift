import SideAProtocol
import SideARemoteKit
import SwiftUI

struct SettingsMenu: View {
    enum Style { case menu, form }

    let session: RemoteSession?
    var style: Style = .menu
    var chooseModel: (() -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session {
            let settings = model.tools.settings(of: session)
            let models = model.tools.models(for: session)
            let current = models.first { $0.id == settings.model || $0.title == settings.model }
            let busy = actions.isBusy("settings-\(session.id)")
            Section {
                if let chooseModel, session.takesModelSettings {
                    Button(action: chooseModel) {
                        Label("Model", systemImage: "cpu")
                        Text(current.map { ModelOption.chipText($0, effort: settings.effort) } ?? model.tools.modelTitle(of: session))
                    }
                    .disabled(busy)
                } else {
                    modelAndEffort(session, settings: settings, models: models, current: current, busy: busy)
                }
                let mode = settings.mode
                setting("Mode", symbol: "shield.lefthalf.filled", ability: .settingsMode, value: mode?.title, session: session) {
                    Picker(selection: Binding(get: { mode ?? .default }, set: { mode in
                        change(session, SettingsChange(mode: mode), title: mode.title)
                    })) {
                        ForEach(PermissionMode.offered(session.agent, current: mode), id: \.self) { mode in
                            Text(mode.title).accessibilityHint(mode.raises ? "Asks for \(Biometry.current.phrase)" : "")
                        }
                    } label: {
                        Label("Mode", systemImage: "shield.lefthalf.filled")
                        if style == .menu { Text((mode ?? .default).title) }
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
            } footer: {
                if style == .form, !session.takesModelSettings,
                   let reason = session.reason(.settingsModel) {
                    Text(reason)
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private func modelAndEffort(_ session: RemoteSession, settings: SessionSettings, models: [ModelOption], current: ModelOption?,
                                busy: Bool) -> some View {
        setting("Model", symbol: "cpu", ability: .settingsModel, value: model.tools.modelTitle(of: session),
                session: session) {
            Picker(selection: Binding(get: { current?.id ?? "" }, set: { id in
                change(session, SettingsChange(model: id), title: models.first { $0.id == id }?.title ?? ModelName.short(id))
            })) {
                ForEach(models, id: \.id) { Text($0.title).tag($0.id) }
            } label: {
                Label("Model", systemImage: "cpu")
                if style == .menu { Text(model.tools.modelTitle(of: session)) }
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
                    if style == .menu { Text((settings.effort ?? current?.defaultEffort)?.title ?? "Default") }
                }
                .disabled(busy)
            }
        }
    }

    @ViewBuilder
    private func setting(_ title: String, symbol: String, ability: SessionAbility?, value: String?, session: RemoteSession,
                         @ViewBuilder picker: () -> some View) -> some View {
        if let ability, session.abilities.contains(ability) {
            picker()
        } else if let value {
            switch style {
            case .menu:
                Button {} label: {
                    Label("\(title): \(value)", systemImage: symbol)
                    if let reason = ability.flatMap(session.reason), !(title != "Model" && modelRowSaysIt(reason, session)) { Text(reason) }
                }
                .disabled(true)
            case .form:
                LabeledContent { Text(value) } label: { Label(title, systemImage: symbol) }
            }
        }
    }

    private func modelRowSaysIt(_ reason: String, _ session: RemoteSession) -> Bool {
        !session.abilities.contains(.settingsModel) && session.reason(.settingsModel) == reason
    }

    private func change(_ session: RemoteSession, _ change: SettingsChange, title: String) {
        actions.on(model).change(session, change, title: title)
    }
}

struct LiveModelSheet: View {
    let session: RemoteSession
    let models: [ModelOption]
    @State private var modelID: String?
    @State private var effort: Effort?
    @State private var otherModelID: String?
    @State private var otherEffort: Effort?
    @State private var otherAccountID: String?
    private let was: (model: String?, effort: Effort?)
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    init(session: RemoteSession, models: [ModelOption], settings: SessionSettings, draft: HandoffDraft? = nil) {
        self.session = session
        self.models = models
        let id = models.first { $0.id == settings.model || $0.title == settings.model }?.id ?? settings.model
        was = (id, settings.effort)
        _modelID = State(initialValue: id)
        _effort = State(initialValue: settings.effort)
        _otherModelID = State(initialValue: draft?.modelID)
        _otherEffort = State(initialValue: draft?.effort)
        _otherAccountID = State(initialValue: draft?.accountID)
    }

    private var other: ModelEffortSheet.OtherAgent? {
        guard let options = model.tools.otherAgent(for: session) else { return nil }
        return .init(agent: options.agent, models: options.models,
                     accounts: model.accounts.accounts.filter { $0.provider == options.agent },
                     modelID: $otherModelID, effort: $otherEffort, accountID: $otherAccountID)
    }

    var body: some View {
        ModelEffortSheet(models: models, modelID: $modelID, effort: $effort,
                         canChangeModel: session.abilities.contains(.settingsModel),
                         canChangeEffort: { session.abilities.contains(.settingsEffort) && $0.canChangeEffortMidSession != false },
                         note: session.reason(.settingsModel) ?? session.reason(.settingsEffort),
                         other: other, mode: mode, apply: apply)
    }

    /// The modes that lift every check stay in the session's menu, where each asks for Face ID.
    private var mode: ModelEffortSheet.ModeRow? {
        guard session.abilities.contains(.settingsMode) else { return nil }
        let current = model.tools.settings(of: model.sessions.session(session.id) ?? session).mode ?? .default
        let offered = PermissionMode.offered(session.agent, current: current).filter { !$0.raises || $0 == current || $0 == .auto }
        return .init(offered: offered, current: current, busy: actions.isBusy("settings-\(session.id)")) { mode in
            actions.on(model).change(session, SettingsChange(mode: mode), title: mode.title)
        }
    }

    private func apply() {
        if let agent = other?.agent, let otherModelID {
            model.handoffs.move(session.id, .picked(HandoffDraft(agent: agent, modelID: otherModelID, effort: otherEffort, accountID: otherAccountID)))
            return
        }
        model.handoffs.move(session.id, .dropped)
        let change = SettingsChange(model: modelID == was.model ? nil : modelID, effort: effort == was.effort ? nil : effort)
        guard change.model != nil || change.effort != nil else { return }
        let title = ModelOption.chipText(models.first { $0.id == modelID }, effort: effort)
        actions.on(model).change(session, change, title: title)
    }
}

private struct LiveModelSheetPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let session: RemoteSession?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let session {
                LiveModelSheet(session: session, models: model.tools.models(for: session), settings: model.tools.settings(of: session),
                               draft: model.handoffs[session.id])
            }
        }
    }
}

extension View {
    func liveModelSheet(isPresented: Binding<Bool>, session: RemoteSession?) -> some View {
        modifier(LiveModelSheetPresenter(isPresented: isPresented, session: session))
    }
}

extension PermissionMode {
    static func offered(_ agent: AgentProvider, current: PermissionMode?) -> [PermissionMode] {
        let modes: [PermissionMode] = agent == .codex ? [.default, .plan] : [.default, .acceptEdits, .plan, .auto, .bypassPermissions]
        guard let current, !modes.contains(current) else { return modes }
        return modes + [current]
    }
}

extension SessionSettings {
    func merging(_ other: SessionSettings) -> SessionSettings {
        SessionSettings(model: other.model ?? model, effort: other.effort ?? effort, mode: other.mode ?? mode, fast: other.fast ?? fast)
    }

    func pending(over row: SessionSettings?) -> SessionSettings? {
        let left = SessionSettings(model: model == row?.model ? nil : model, effort: effort == row?.effort ? nil : effort,
                                   mode: mode == row?.mode ? nil : mode, fast: fast == row?.fast ? nil : fast)
        return left == SessionSettings() ? nil : left
    }
}

extension MacTools {
    /// The folders used last, newest first; one that was never used sorts after those that were.
    var recentProjects: [RemoteProject] { Array(projects.sorted { ($0.lastUsedAt ?? 0) > ($1.lastUsedAt ?? 0) }.prefix(5)) }

    func modelTitle(of session: RemoteSession) -> String {
        guard let id = settings(of: session).model else { return "Default" }
        return models(for: session).first { $0.id == id || $0.title == id }?.title ?? ModelName.short(id)
    }
}

enum ModelName {
    static func brief(_ name: String) -> String {
        let plain = name.split(whereSeparator: { "[(".contains($0) }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
        let named = plain.contains("-") && plain == plain.lowercased() ? short(plain) : plain
        let title = named.hasPrefix("Claude ") ? String(named.dropFirst(7)) : named
        return title.hasPrefix("GPT") ? title : String(title.split(separator: " ").first ?? Substring(title))
    }

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
