import SideACore
import SideAProtocol
import SwiftUI

/// A running session's model · effort · mode · context, read from the same row the phone gets; a click opens what
/// can be changed, by the same command and abilities as the phone's sheet. What can't change says why.
struct SettingsChip: View {
    let model: SessionStore
    let live: LiveSession
    @State private var open = false

    var body: some View {
        let row = WireBuilders.session(live, store: model.store, finished: [])
        if let text = Self.summary(row) {
            Button { open = true } label: {
                ChipLabel(symbol: "slider.horizontal.3", text: text)
            }
            .buttonStyle(.plain)
            .help(Self.changeable(row) ? "Change its model, effort or mode" : "What it runs with")
            .accessibilityLabel("Session settings: \(text)")
            .popover(isPresented: $open, arrowEdge: .bottom) { SettingsPanel(model: model, live: live, row: row) }
        }
    }

    /// "Opus 5.5 · High · Accept edits · 42% context · 2 running", the phone's words, leaving out what wasn't read.
    static func summary(_ row: RemoteSession) -> String? {
        let settings = row.settings
        let parts: [String?] = [
            (settings?.model ?? row.model).map(ModelName.short),
            (settings?.effort ?? row.effort.map(Effort.init(rawValue:))).flatMap { $0 == .auto ? nil : $0.title },
            settings?.mode.flatMap { $0 == .default ? nil : $0.title },
            row.contextPercent.map { "\(Int($0.rounded()))% context" },
            row.backgroundTasks.flatMap { $0 > 0 ? "\($0) running" : nil },
        ]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    static func changeable(_ row: RemoteSession) -> Bool {
        !row.abilities.isDisjoint(with: [.settingsModel, .settingsEffort, .settingsMode, .settingsFast])
    }
}

/// The capsule the session header's chips share.
struct ChipLabel: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            Text(text).font(.system(size: 11.5)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).frame(height: 22)
        .background(Ink.field, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.line))
        .contentShape(Capsule())
    }
}

/// The popover: each setting a picker when the session takes changes to it, else its value and the reason.
struct SettingsPanel: View {
    let model: SessionStore
    let live: LiveSession
    let row: RemoteSession
    @State private var models: [ModelOption] = []
    @State private var modelID = ""
    @State private var effort = ""
    @State private var mode = ""
    @State private var failure: String?
    @State private var saving = false
    @State private var confirmingRaise = false
    @State private var applied: String?

    private var settings: SessionSettings? { row.settings }
    private var modes: [PermissionMode] {
        live.provider == .codex ? CodexAppServer.modes.map(PermissionMode.init(rawValue:)) : [.default, .acceptEdits, .plan, .auto, .bypassPermissions]
    }
    private var efforts: [Effort] {
        models.first { $0.id == modelID }?.efforts ?? (live.provider == .claude ? RemoteOptions.claudeEfforts(modelID) : [])
    }
    private var change: SettingsChange {
        SettingsChange(model: modelID.isEmpty || modelID == settings?.model ? nil : modelID,
                       effort: effort.isEmpty || effort == settings?.effort?.rawValue ? nil : Effort(rawValue: effort),
                       mode: mode.isEmpty || mode == settings?.mode?.rawValue ? nil : PermissionMode(rawValue: mode))
    }
    private var changed: Bool { change.model != nil || change.effort != nil || change.mode != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                setting("Model", ability: .settingsModel, value: (settings?.model ?? row.model).map(ModelName.short)) {
                    Picker("Model", selection: $modelID) { ForEach(models, id: \.id) { Text($0.title).tag($0.id) } }
                }
                setting("Effort", ability: .settingsEffort, value: (settings?.effort ?? row.effort.map(Effort.init(rawValue:)))?.title) {
                    Picker("Effort", selection: $effort) { ForEach(efforts, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
                }
                setting("Mode", ability: .settingsMode, value: settings?.mode?.title) {
                    Picker("Mode", selection: $mode) { ForEach(modes, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
                }
                if let percent = row.contextPercent {
                    GridRow {
                        Text("Context").foregroundStyle(.secondary)
                        Text("\(Int(percent.rounded()))% used")
                    }
                }
            }
            .font(.system(size: 12.5))
            if let applied { Label(applied, systemImage: "checkmark.circle").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            if let failure { Label(failure, systemImage: "exclamationmark.circle").font(.system(size: 11.5)).foregroundStyle(.red) }
            if SettingsChip.changeable(row) {
                HStack {
                    Spacer()
                    Button(saving ? "Changing…" : "Change") {
                        if change.raises { confirmingRaise = true } else { apply() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changed || saving)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .task { await load() }
        .confirmationDialog("Switch to \(PermissionMode(rawValue: mode).title)?", isPresented: $confirmingRaise) {
            Button("Switch", role: .destructive) { apply() }
        } message: {
            Text("It will run without asking before it acts.")
        }
    }

    @ViewBuilder
    private func setting(_ title: String, ability: SessionAbility, value: String?, @ViewBuilder picker: () -> some View) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            if row.abilities.contains(ability) {
                picker().labelsHidden().fixedSize()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value ?? "Unknown").foregroundStyle(value == nil ? .tertiary : .primary)
                    if let reason = row.abilityReasons?[ability.rawValue] {
                        Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func load() async {
        modelID = settings?.model ?? row.model ?? ""
        effort = settings?.effort?.rawValue ?? row.effort ?? ""
        mode = settings?.mode?.rawValue ?? ""
        guard row.abilities.contains(.settingsModel) || row.abilities.contains(.settingsEffort) else { return }
        // The daemon's own list for Codex; the phone's options for the rest.
        let commands = SessionCommands(store: model.store)
        if let list = try? await commands.models(live.provider, session: WireBuilders.key(live)) {
            models = list.models
        } else {
            models = await RemoteOptions.agents(model.store.remote)?.first { $0.agent == live.provider }?.models ?? []
        }
        if !modelID.isEmpty, !models.contains(where: { $0.id == modelID }) {
            models.insert(ModelOption(id: modelID, title: ModelName.short(modelID), agent: live.provider), at: 0)
        }
    }

    private func apply() {
        saving = true
        failure = nil
        applied = nil
        let change = change
        Task {
            do throws(SessionCommands.Failure) {
                let result = try await SessionCommands(store: model.store).settings(WireBuilders.key(live), change)
                applied = result.nextTurn ? "Changed. It takes effect from its next turn." : "Changed."
            } catch {
                failure = error.macMessage
            }
            saving = false
        }
    }
}
