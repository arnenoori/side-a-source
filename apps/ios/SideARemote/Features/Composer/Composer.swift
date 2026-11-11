import PhotosUI
import SideAProtocol
import SwiftUI

/// What the follow-mode button says when it buds off the composer.
enum FollowBadge: Equatable {
    case none, newMessages(Int), waiting
}

/// The stop button's long-press menu, the toolbar's Steer section and a row's context menu.
enum Steer: Hashable, CaseIterable {
    case interruptNow, stopBeforeNextStep, note

    var title: String {
        switch self {
        case .interruptNow: "Interrupt Now"
        case .stopBeforeNextStep: "Stop Before Next Step"
        case .note: "Send a Message…"
        }
    }

    var symbol: String {
        switch self {
        case .interruptNow: "stop.fill"
        case .stopBeforeNextStep: "pause.circle"
        case .note: "text.bubble"
        }
    }

    /// What this session takes, from the abilities the Mac lists. Interrupt Now is Esc in a hosted terminal,
    /// or Codex's own interrupt for one it reaches through its shared server; stops and next-step messages go
    /// through the agent's hooks.
    static func available(for session: RemoteSession?) -> [Steer] {
        guard let session, SessionPhase(session) == .working || SessionPhase(session) == .needsYou else { return [] }
        var steers: [Steer] = []
        if (session.hosted != nil || session.abilities.contains(.replyTerminal)) && session.abilities.contains(.interrupt) {
            steers.append(.interruptNow)
        }
        // The Mac keeps one piece of mail per session, so a stop would replace a waiting note.
        if session.agent == .claude && session.abilities.contains(.interrupt) && session.mail == nil { steers.append(.stopBeforeNextStep) }
        if session.abilities.contains(.note) { steers.append(.note) }
        return steers
    }
}

/// The floating composer: a round `+`, a pill field with its trailing control, and
/// the follow-mode button, all one `GlassEffectContainer` so they blend and morph.
struct Composer: View {
    @Binding var text: String
    let placeholder: String
    /// The session works and the field is empty: the trailing control interrupts.
    let canInterrupt: Bool
    let showsFollow: Bool
    let follow: FollowBadge
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onInterrupt: () -> Void
    let onFollow: () -> Void
    let session: RemoteSession?
    /// The stop button's long-press menu.
    var steers: [Steer] = []
    var onSteer: (Steer) -> Void = { _ in }
    /// Status `unknown`: nothing typed here could be delivered, so the field says why instead.
    var disabledReason: String?
    /// "Not sent · Retry" for a reply the Mac didn't take.
    var unsent: TranscriptStore.Unsent?
    var onRetry: () -> Void = {}
    /// A steer the Mac refused, or a standing fact about where replies go.
    var notice: String?
    /// Mid-turn: how the send button's long-press offers to deliver what's typed.
    var deliveries: [Delivery] = []
    var onDeliver: (Delivery) -> Void = { _ in }
    /// What Codex dropped («Didn't reach Codex: "…"»), with Retry.
    var dropped: String?
    var onRetryDropped: () -> Void = {}

    @Namespace private var glass
    @State private var showsAdd = false
    @State private var sends = 0
    /// Where the caret is, for the "/" or "$" word it's in.
    @State private var selection: TextSelection?
    /// The suggestion a hardware keyboard's Return or Tab takes, and the text Esc closed the list for.
    @State private var highlighted = 0
    @State private var dismissedFor: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model

    /// The caret as a UTF-16 offset; the end when the field hasn't reported one.
    private var caret: Int {
        guard case .selection(let range)? = selection?.indices, range.upperBound <= text.endIndex else { return text.utf16.count }
        return range.upperBound.utf16Offset(in: text)
    }

    private var suggestion: (range: NSRange, options: [AgentOptions.Option])? {
        guard let session, dismissedFor != text, let commands = model.tools.agent(session.agent)?.commands,
              let word = CommandSuggestions.word(in: text, caret: caret, agent: session.agent) else { return nil }
        let options = CommandSuggestions.matches(word.word, in: commands)
        return options.isEmpty ? nil : (word.range, options)
    }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// A photo still on its way to the Mac: the reply waits for it.
    private var uploading: Bool { session.map { model.tools.attachments.isUploading($0.id) } ?? false }
    /// Why the send button is off with something to send: the Mac is out of reach, or a photo is still on its way.
    private var blocked: String? {
        if case .offline(let reason) = model.mac.state { return reason.message(mac: model.mac.name) }
        return hasText && uploading ? "Sends once the photo has uploaded." : nil
    }

    var body: some View {
        GlassEffectContainer(spacing: Space.s) {
            VStack(spacing: Space.s) {
                if showsFollow {
                    followButton
                        .glassEffectID("follow", in: glass)
                        .glassEffectTransition(.matchedGeometry)
                }
                if let session {
                    AttachmentTray(session: session.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let suggestion {
                    CommandSuggestionList(options: suggestion.options, highlighted: highlighted) { pick($0, at: suggestion.range) }
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
                HStack(alignment: .bottom, spacing: Space.s) {
                    Button {
                        showsAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 19, weight: .medium))
                            .frame(width: 48, height: 48)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("plus", in: glass)
                    .accessibilityLabel("Add")
                    .accessibilityHint("Attachments, model and commands")

                    field
                        .glassEffectID("field", in: glass)
                }
                .disabled(disabledReason != nil)
                if unsent != nil || notice != nil || disabledReason != nil || dropped != nil || blocked != nil {
                    statusLine
                        .padding(.horizontal, Space.xs)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.bottom, Space.xs)
        .animation(Motion.smooth(reduceMotion), value: showsFollow)
        .animation(Motion.snappy(reduceMotion), value: suggestion == nil)
        .onChange(of: text) { highlighted = 0 }
        .task(id: session?.agent) { await model.tools.loadOptions() }
        .animation(Motion.smooth(reduceMotion), value: follow)
        .animation(Motion.smooth(reduceMotion), value: unsent)
        .animation(Motion.smooth(reduceMotion), value: notice)
        .animation(Motion.smooth(reduceMotion), value: blocked)
        .animation(Motion.smooth(reduceMotion), value: session.map { model.tools.attachments.items($0.id).map(\.id) })
        .sensoryFeedback(.impact(weight: .light), trigger: sends)
        .sensoryFeedback(.error, trigger: unsent) { _, new in new != nil }
        .sheet(isPresented: $showsAdd) {
            AddSheet(session: session) { command in
                text = command + " "
                focused.wrappedValue = true
            }
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: Space.xs) {
            TextField(placeholder, text: $text, selection: $selection, axis: .vertical)
                .lineLimit(1...6)
                .font(.body)
                .focused(focused)
                .padding(.vertical, 13)
                .padding(.leading, Space.m)
                .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: .down) { press in
                    guard let suggestion else { return .ignored }
                    switch press.key {
                    case .upArrow: highlighted = max(highlighted - 1, 0)
                    case .downArrow: highlighted = min(highlighted + 1, suggestion.options.count - 1)
                    case .escape: dismissedFor = text
                    default: pick(suggestion.options[min(highlighted, suggestion.options.count - 1)], at: suggestion.range)
                    }
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if let suggestion, !press.modifiers.contains(.shift) {
                        pick(suggestion.options[min(highlighted, suggestion.options.count - 1)], at: suggestion.range)
                        return .handled
                    }
                    guard !press.modifiers.contains(.shift), hasText, !offline, !uploading else { return .ignored }
                    send()
                    return .handled
                }
            trailingControl
                .opacity(disabledReason == nil ? 1 : 0)
                .needsMac()
                .padding(.trailing, 6)
                .padding(.bottom, 6)
        }
        .frame(minHeight: 48)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder private var trailingControl: some View {
        let mode: TrailingMode = hasText || !canInterrupt ? .send : .interrupt
        let idle = mode == .send && (!hasText || uploading)
        Button {
            switch mode {
            case .send: send()
            case .interrupt: onInterrupt()
            }
        } label: {
            Image(systemName: mode.symbol)
                .font(.system(size: mode == .send ? 15 : 14, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(mode == .send ? Color(.systemBackground) : .primary)
                .frame(width: 36, height: 36)
                .background {
                    Circle().fill(mode == .send ? Color(.label) : Color(.tertiarySystemFill))
                }
                // Glass renders what's on it vibrant; the send circle stays solid label colour.
                .compositingGroup()
        }
        .buttonStyle(.plain)
        .disabled(idle)
        .opacity(idle || offline ? 0.3 : 1)
        .contextMenu {
            if mode == .interrupt {
                ForEach(steers, id: \.self) { steer in
                    Button(steer.title, systemImage: steer.symbol) { onSteer(steer) }
                }
            } else if mode == .send, hasText {
                // Sending takes the attachment tray, so a photo still uploading would be dropped.
                ForEach(deliveries, id: \.self) { delivery in
                    Button(delivery.title, systemImage: delivery.symbol) {
                        sends += 1
                        onDeliver(delivery)
                    }
                }
                .disabled(uploading || offline)
            }
        }
        .accessibilityLabel(mode.accessibilityLabel)
        .animation(Motion.snappy(reduceMotion), value: mode)
    }

    private enum TrailingMode {
        case send, interrupt
        var symbol: String {
            switch self {
            case .send: "arrow.up"
            case .interrupt: "stop.fill"
            }
        }
        var accessibilityLabel: String {
            switch self {
            case .send: "Send"
            case .interrupt: "Interrupt session"
            }
        }
    }

    private var offline: Bool { model.mac.isOffline }

    /// One quiet line under the field: why nothing can be sent now, a reply that didn't go, or a steer the Mac refused.
    @ViewBuilder private var statusLine: some View {
        if case .offline(let reason) = model.mac.state {
            // Retry is off too while the Mac is out of reach, so this leads.
            Label(reason.message(mac: model.mac.name), systemImage: reason.symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let unsent {
            HStack(alignment: .firstTextBaseline, spacing: Space.xxs) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.destructive)
                Text("Not sent · \(unsent.reason)").foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Button("Retry", action: onRetry).fontWeight(.semibold).buttonStyle(.borderless).needsMac()
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Not sent. \(unsent.reason)")
            .accessibilityAction(named: "Retry", onRetry)
        } else if let dropped {
            // The quote wraps rather than hiding what didn't arrive; Retry stays at the end of its first line.
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(dropped).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Button("Retry", action: onRetryDropped).fontWeight(.semibold).buttonStyle(.borderless).needsMac()
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(dropped)
            .accessibilityAction(named: "Retry", onRetryDropped)
        } else if let notice = blocked ?? notice ?? disabledReason {
            Text(notice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A suggestion replaces the word, ready for its arguments.
    private func pick(_ option: AgentOptions.Option, at range: NSRange) {
        let applied = CommandSuggestions.apply(option, to: text, at: range)
        text = applied.text
        let caret = String.Index(utf16Offset: min(applied.caret, applied.text.utf16.count), in: applied.text)
        selection = TextSelection(insertionPoint: caret)
        focused.wrappedValue = true
    }

    private func send() {
        sends += 1
        onSend()
    }

    private var followButton: some View {
        Button(action: onFollow) {
            HStack(spacing: 6) {
                if follow == .waiting { Circle().fill(Color.amber).frame(width: 7, height: 7) }
                Image(systemName: "arrow.down").font(.system(size: 15, weight: .semibold))
                switch follow {
                case .newMessages(let count): Text("\(count) new").font(.subheadline.weight(.medium).monospacedDigit())
                case .waiting: Text("Question").font(.subheadline.weight(.medium))
                case .none: EmptyView()
                }
            }
            .padding(.horizontal, follow == .none ? 0 : Space.m)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(follow == .waiting ? "Scroll to the question" : "Scroll to the latest message")
    }
}

/// v0's Add to Chat: Camera / Photos / Files / Paste tiles, then Model, Effort and Commands from the
/// Mac's `/v1/options`.
struct AddSheet: View {
    let session: RemoteSession?
    /// A command picked from the list goes into the field.
    var onCommand: (String) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [PhotosPickerItem] = []
    @State private var importsFiles = false
    @State private var takesPhoto = false

    private var settings: SessionSettings? { session.map(model.tools.settings(of:)) }
    private var models: [ModelOption] { session.map(model.tools.models(for:)) ?? [] }
    private var current: ModelOption? { models.first { $0.id == settings?.model || $0.title == settings?.model } }
    private func can(_ ability: SessionAbility) -> Bool { session?.abilities.contains(ability) == true }
    private var effortTitle: String { (settings?.effort ?? current?.defaultEffort)?.title ?? "Default" }
    private var commands: [AgentOptions.Option] { session.flatMap { model.tools.agent($0.agent)?.commands } ?? [] }
    private var room: Int { session.map { model.tools.attachments.room($0.id) } ?? 0 }

    var body: some View {
        NavigationStack {
            List {
                if let session, model.tools.can(.uploads), room > 0 {
                    Section {
                        HStack(spacing: Space.s) {
                            if CameraPicker.isAvailable {
                                AddTile(title: "Camera", symbol: "camera") { takesPhoto = true }
                            }
                            PhotosPicker(selection: $photos, maxSelectionCount: min(5, room), matching: .images) {
                                AddTileLabel(title: "Photos", symbol: "photo.on.rectangle")
                            }
                            .buttonStyle(.plain)
                            AddTile(title: "Files", symbol: "folder") { importsFiles = true }
                            if UIPasteboard.general.hasImages {
                                AddTile(title: "Paste", symbol: "doc.on.clipboard") {
                                    if let data = UIPasteboard.general.image?.jpegData(compressionQuality: 0.95) { add([data], to: session) }
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
                Section {
                    if can(.settingsModel), !models.isEmpty {
                        NavigationLink {
                            OptionList(title: "Model", options: models.map { ($0.id, $0.title) }, selected: current?.id) { id in
                                choose(SettingsChange(model: id), title: models.first { $0.id == id }?.title ?? id)
                            }
                        } label: {
                            LabeledContent("Model", value: current?.title ?? settings?.model ?? "Default")
                        }
                    } else {
                        LabeledContent("Model", value: current?.title ?? settings?.model ?? "Default")
                    }
                    if can(.settingsEffort), let current, !current.efforts.isEmpty {
                        NavigationLink {
                            OptionList(title: "Effort", options: current.efforts.map { ($0.rawValue, $0.title) },
                                       selected: (settings?.effort ?? current.defaultEffort)?.rawValue) { raw in
                                let effort = Effort(rawValue: raw)
                                choose(SettingsChange(effort: effort), title: "\(effort.title) effort")
                            }
                        } label: {
                            LabeledContent("Effort", value: effortTitle)
                        }
                    } else {
                        LabeledContent("Effort", value: effortTitle)
                    }
                    NavigationLink("Commands") {
                        CommandList(commands: commands) { command in
                            onCommand(command)
                            dismiss()
                        }
                    }
                } footer: {
                    if !can(.settingsModel), !can(.settingsEffort),
                       let reason = session?.abilityReasons?[SessionAbility.settingsModel.rawValue] {
                        Text(reason)
                    }
                }
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } }
            }
            .fileImporter(isPresented: $importsFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                guard let session, case .success(let urls) = result else { return }
                add(urls.prefix(room).compactMap { url in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                }, to: session)
            }
            .onChange(of: photos) { _, picked in
                guard let session, !picked.isEmpty else { return }
                photos = []
                Task {
                    var loaded: [Data] = []
                    for item in picked { if let data = try? await item.loadTransferable(type: Data.self) { loaded.append(data) } }
                    add(loaded, to: session)
                }
            }
            .fullScreenCover(isPresented: $takesPhoto) {
                CameraPicker { data in if let session { add([data], to: session) } }
                    .ignoresSafeArea()
            }
            .task { await model.tools.loadOptions() }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(_ images: [Data], to session: RemoteSession) {
        for data in images { model.tools.attachments.add(data, to: session.id) }
        if !images.isEmpty { dismiss() }
    }

    /// Model and effort change as in the session's menu, signed through the Mac's settings.
    private func choose(_ change: SettingsChange, title: String) {
        guard let session else { return }
        actions.on(model).change(session, change, title: title)
        dismiss()
    }
}

private struct AddTile: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { AddTileLabel(title: title, symbol: symbol) }.buttonStyle(.plain)
    }
}

private struct AddTileLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: Space.xs) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.footnote.weight(.medium))
        }
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Radius.inlineCard, style: .continuous))
        .contentShape(.rect)
    }
}

private struct OptionList: View {
    let title: String
    /// (id, title)
    let options: [(String, String)]
    let selected: String?
    let onChoose: (String) -> Void

    var body: some View {
        List(options, id: \.0) { option in
            Button {
                if option.0 != selected { onChoose(option.0) }
            } label: {
                HStack {
                    Text(option.1)
                    Spacer()
                    if option.0 == selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(title)
    }
}

/// The Mac's slash commands for this agent, its custom ones included; the built-ins when it lists none.
private struct CommandList: View {
    let commands: [AgentOptions.Option]
    let onPick: (String) -> Void
    private static let builtIn = [("/model", "Choose the model"), ("/effort", "Set reasoning effort"), ("/compact", "Summarize the conversation to free context"),
                                  ("/clear", "Start over with an empty context"), ("/review", "Review the current changes")]

    private var rows: [(String, String)] {
        commands.isEmpty ? Self.builtIn : commands.map { ($0.id.hasPrefix("/") ? $0.id : "/\($0.id)", $0.label) }
    }

    var body: some View {
        List(rows, id: \.0) { command in
            Button { onPick(command.0) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.0).font(.body.monospaced())
                    Text(command.1).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Commands")
    }
}
