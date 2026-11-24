import PhotosUI
import SideAProtocol
import SwiftUI
import UniformTypeIdentifiers

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
    @Binding var focused: Bool
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
    /// Mid-turn: the ways to deliver what's typed, the one Send uses now (nil when there's no choice) and what picking one does.
    /// The control beside Send picks; the send button's long-press picks and sends.
    var deliveries: [Delivery] = []
    var delivery: Delivery?
    var onChooseDelivery: (Delivery) -> Void = { _ in }
    var onDeliver: (Delivery) -> Void = { _ in }
    /// What Codex dropped («Didn't reach Codex: "…"»), with Retry.
    var dropped: String?
    var onRetryDropped: () -> Void = {}
    /// The page's model sheet, where it has one: the field then carries a chip that opens it.
    var choosingModel: Binding<Bool>?

    @Namespace private var glass
    @State private var showsAdd = false
    @State private var surface = AttachSurface()
    @State private var sends = 0
    @State private var interrupts = 0
    /// Where the caret is (a UTF-16 range), for the "/" or "$" word it's in.
    @State private var selection = NSRange(location: 0, length: 0)
    /// The suggestion a hardware keyboard's Return or Tab takes, and the text Esc closed the list for.
    @State private var highlighted = 0
    @State private var dismissedFor: String?
    /// The Mac's matches for the `@` word at the caret.
    @State private var files: [String] = []
    @State private var showsQueue = false
    @State private var dictation = Dictation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(AppModel.self) private var model

    /// The caret as a UTF-16 offset.
    private var caret: Int { min(selection.location + selection.length, text.utf16.count) }

    private var suggestion: (range: NSRange, options: [AgentOptions.Option], files: Bool)? {
        guard let session, dismissedFor != text else { return nil }
        if let commands = model.tools.agent(session.agent)?.commands,
           let word = CommandSuggestions.word(in: text, caret: caret, agent: session.agent) {
            let options = CommandSuggestions.matches(word.word, in: commands)
            if !options.isEmpty { return (word.range, options, false) }
        }
        guard let word = FileMentions.word(in: text, caret: caret), !files.isEmpty else { return nil }
        return (word.range, files.map { AgentOptions.Option(id: $0, label: "") }, true)
    }

    /// What follows the `@` at the caret, nil when the caret isn't in one.
    private var mention: String? { FileMentions.word(in: text, caret: caret)?.query }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// A photo still on its way to the Mac: the reply waits for it.
    private var uploading: Bool { session.map { model.tools.attachments.isUploading($0.id) } ?? false }
    /// Why the send button is off with something to send: the pairing or a version needs someone first, or a photo is
    /// still on its way. A Mac that's only out of reach doesn't stop it: what's sent waits for it.
    private var blocked: String? {
        if let stuck { return stuck.message(mac: model.mac.name) }
        return hasText && uploading ? "Sends once the photo has uploaded." : nil
    }

    private var stuck: MacConnection.Offline? {
        if case .offline(let reason) = model.mac.shown, !reason.comesBack { reason } else { nil }
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
                if let count = session?.queued?.count, count > 0, suggestion == nil {
                    QueueChip(count: count) { showsQueue = true }
                        .transition(.opacity)
                }
                if let suggestion {
                    CommandSuggestionList(options: suggestion.options, highlighted: highlighted, files: suggestion.files) {
                        pick($0, at: suggestion.range, file: suggestion.files)
                    }
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
                if surface.strip.isShown {
                    // Out of the + the finger is holding, and gone at once when it's done with.
                    RecentStripView(strip: surface.strip, window: surface.drawer.window)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)), removal: .opacity))
                }
                ComposerRow(stacked: stacked) {
                    attachButton
                    .glassEffectID("plus", in: glass)
                    .attachPopover(surface)
                    .disabled(disabledReason != nil)
                    .layoutValue(key: ComposerSlot.self, value: .plus)

                    if showsChip, let session, let choosingModel {
                        ModelChip(session: session, isPresented: choosingModel)
                            .glassEffectID("chip", in: glass)
                            .glassEffectTransition(.materialize)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                            .layoutValue(key: ComposerSlot.self, value: .chip)
                    }

                    field
                        .glassEffectID("field", in: glass)
                        .accessibilitySortPriority(stacked ? 1 : 0)
                }
                .animation(Motion.snappy(reduceMotion), value: showsChip)
                .animation(Motion.smooth(reduceMotion), value: stacked)
                DictationNote(dictation: dictation)
                if unsent != nil || notice != nil || disabledReason != nil || dropped != nil || blocked != nil || model.mac.shown.isOffline
                    || hasText && model.mac.isAway {
                    statusLine
                        .padding(.horizontal, Space.xs)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.bottom, Space.xs)
        .animation(Motion.smooth(reduceMotion), value: showsFollow)
        .animation(Motion.snappy(reduceMotion), value: surface.strip.isShown)
        .animation(Motion.snappy(reduceMotion), value: suggestion == nil)
        .onChange(of: text) { highlighted = 0 }
        .task(id: session?.agent) { await model.tools.loadOptions() }
        .task(id: mention) {
            guard let mention, let session else { files = []; return }
            // Each letter asks again; a pause in typing is what's worth a trip to the Mac.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            let found = await model.tools.files(session.id, matching: mention)
            if !Task.isCancelled { files = found }
        }
        .animation(Motion.snappy(reduceMotion), value: session?.queued?.count)
        .sheet(isPresented: $showsQueue) {
            if let session { QueueSheet(sessionID: session.id) }
        }
        .animation(Motion.smooth(reduceMotion), value: follow)
        .animation(Motion.smooth(reduceMotion), value: unsent)
        .animation(Motion.smooth(reduceMotion), value: notice)
        .animation(Motion.smooth(reduceMotion), value: blocked)
        .animation(Motion.smooth(reduceMotion), value: session.map { model.tools.attachments.items($0.id).map(\.id) })
        .sensoryFeedback(.impact(weight: .light), trigger: sends)
        .sensoryFeedback(.impact(weight: .medium), trigger: interrupts)
        .sensoryFeedback(.error, trigger: unsent) { _, new in new != nil }
        .sheet(isPresented: $showsAdd) {
            AddSheet(session: session) { command in
                text = command + " "
                focused = true
            }
        }
        #if DEBUG
        .task { await debugLaunch() }
        #endif
        .attachments(surface, key: session?.id, tools: model.tools)
        .dictation(dictation, text: $text, selection: $selection, focused: $focused, session: session)
    }

    #if DEBUG
    /// `--focus-composer`, `--tray-full`, `--show-options`, `--drawer panel|large|camera`: states for screenshots and checks, reached without taps.
    private func debugLaunch() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--focus-composer") || arguments.contains("--tray-full") || arguments.contains("--drawer") || arguments.contains("--show-picker") || arguments.contains("--show-options") || arguments.contains("--draft") || arguments.contains("--show-queue") else { return }
        try? await Task.sleep(for: .milliseconds(1200))
        // `--show-picker` / `--show-files`: the system pickers without the drawer, to tell the drawer from the simulator.
        if arguments.contains("--show-picker") { surface.showsPicker = true }
        // `--show-options`: the + drawer's Model & Commands sheet.
        if arguments.contains("--show-options") { showsAdd = true }
        if arguments.contains("--tray-full"), let session {
            for n in 0..<model.tools.attachments.room(session.id) {
                let picture = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in
                    UIColor(hue: CGFloat(n) / 10, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
                    ("\(n + 1)" as NSString).draw(at: CGPoint(x: 70, y: 50), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 90), .foregroundColor: UIColor.white])
                }
                model.tools.attachments.add(picture.jpegData(compressionQuality: 0.8)!, to: session.id)
            }
        }
        // `--draft "text"` puts text in the field, to see commands tinted.
        if let index = arguments.firstIndex(of: "--draft"), index + 1 < arguments.count {
            text = arguments[index + 1]
            selection = NSRange(location: text.utf16.count, length: 0)
        }
        // `--show-queue`: the sheet of queued messages.
        if arguments.contains("--show-queue") { showsQueue = true }
        if arguments.contains("--focus-composer") { focused = true; try? await Task.sleep(for: .milliseconds(900)) }
        if let index = arguments.firstIndex(of: "--drawer"), index + 1 < arguments.count {
            if !surface.open(key: session?.id, tools: model.tools, reduceMotion: reduceMotion), session != nil { showsAdd = true }
            if arguments[index + 1] == "large" { try? await Task.sleep(for: .milliseconds(900)); surface.drawer.toggleDetent() }
            // `--drawer camera` opens the viewfinder (with `--fake-camera`); `--camera-interrupted` takes the camera away.
            if arguments[index + 1] == "camera" { try? await Task.sleep(for: .milliseconds(900)); surface.drawer.openCamera() }
            if arguments.contains("--camera-interrupted") { try? await Task.sleep(for: .milliseconds(600)); surface.drawer.camera.setInterrupted(true) }
        }
    }
    #endif

    private var stacked: Bool { surface.drawer.showsInlineGrid }

    /// In one row there's no room for it beside the text, the delivery menu or at the largest type sizes.
    private var showsChip: Bool {
        guard choosingModel != nil, let session, ModelChip.offers(session, tools: model.tools), disabledReason == nil,
              !dictation.isActive else { return false }
        if stacked { return true }
        // Not once there is text: beside the chip the field is about 170 points wide, and a path or a sentence wraps in scraps.
        return focused && !hasText && !typeSize.isAccessibilitySize
    }

    /// Photos left in the tray, 0 when the Mac can't take uploads.
    private var room: Int { surface.room(session?.id, tools: model.tools) }

    private var attachButton: AttachButton {
        let options: (() -> Void)? = session == nil ? nil : { showsAdd = true }
        let mention: (() -> Void)? = session == nil ? nil : { mentionFile() }
        return AttachButton(surface: surface, key: session?.id, tools: model.tools, onSessionFile: mention, offersScreen: true,
                            hosted: session?.hosted, onOptions: options)
    }

    /// The + menu's File from This Session: an `@` at the caret, which lists the session's files as typing one does.
    private func mentionFile() {
        let string = text as NSString
        let at = min(caret, string.length)
        let spaced = at > 0 && !(string.substring(with: NSRange(location: at - 1, length: 1)).first?.isWhitespace ?? true)
        let insert = spaced ? " @" : "@"
        text = string.replacingCharacters(in: NSRange(location: at, length: 0), with: insert)
        selection = NSRange(location: at + insert.utf16.count, length: 0)
        dismissedFor = nil
        focused = true
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: Space.xs) {
            ComposerField(text: $text, selection: $selection, isFocused: $focused, placeholder: placeholder,
                          drawer: surface.drawer, paste: surface.target, onKey: handle, highlights: highlights(in:))
            HStack(spacing: Space.xs) {
                DictationButton(dictation: dictation)
                if hasText, let delivery { deliveryControl(delivery) }
                trailingControl
            }
            .opacity(disabledReason == nil ? 1 : 0)
            .padding(.trailing, 6)
            .padding(.bottom, 6)
            .animation(Motion.snappy(reduceMotion), value: hasText)
        }
        // Inside `dictating`, so a session that ends mid-recording still leaves ✓ and × working.
        .disabled(disabledReason != nil)
        .dictating(dictation)
        .frame(minHeight: 48)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
    }

    /// How the message goes, in a word, with the other ways in its menu. Picking changes how Send delivers; it doesn't send.
    private func deliveryControl(_ delivery: Delivery) -> some View {
        Menu {
            Picker("Delivery", selection: Binding(get: { delivery }, set: { onChooseDelivery($0) })) {
                ForEach(deliveries, id: \.self) { delivery in
                    Label { Text(delivery.title); Text(delivery.hint) } icon: { Image(systemName: delivery.symbol) }.tag(delivery)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(delivery.shortTitle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.s)
            .frame(height: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .sensoryFeedback(.selection, trigger: delivery)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .accessibilityLabel("Delivery")
        .accessibilityValue(delivery.title)
    }

    @ViewBuilder private var trailingControl: some View {
        let mode: TrailingMode = hasText || !canInterrupt ? .send : .interrupt
        let deferred = mode == .send && model.mac.isAway
        let symbol = deferred ? SendsWhenConnected.symbol : mode == .send ? delivery?.symbol ?? mode.symbol : mode.symbol
        // A Stop that waited for the Mac would land on whatever runs then, so it needs the Mac now.
        let idle = mode == .send ? !hasText || uploading || stuck != nil : offline
        Button {
            switch mode {
            case .send: send()
            case .interrupt:
                interrupts += 1
                onInterrupt()
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: mode == .send ? 15 : 14, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(mode == .send ? Color(.systemBackground) : .primary)
                .frame(width: 36, height: 36)
                .background {
                    Circle().fill(mode == .send ? Color(.label) : Color(.tertiarySystemFill))
                }
                // Glass renders what's on it vibrant; the send circle stays solid label colour.
                .compositingGroup()
                .hitArea(horizontal: 4, vertical: 4)
                .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .disabled(idle)
        .opacity(idle ? 0.3 : 1)
        .contextMenu {
            if mode == .interrupt {
                ForEach(steers, id: \.self) { steer in
                    Button(steer.title, systemImage: steer.symbol) { onSteer(steer) }
                }
            } else if mode == .send, hasText {
                // Sending takes the attachment tray, so a photo still uploading would be dropped.
                ForEach(deliveries, id: \.self) { delivery in
                    Button {
                        sends += 1
                        onChooseDelivery(delivery)
                        onDeliver(delivery)
                    } label: {
                        Label { Text(delivery.title); Text(delivery.hint) } icon: { Image(systemName: delivery.symbol) }
                    }
                }
                .disabled(uploading || stuck != nil)
            }
        }
        .accessibilityLabel(deferred ? SendsWhenConnected.action : mode.accessibilityLabel)
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

    private var offline: Bool { model.mac.shown.isOffline }

    /// One quiet line under the field: a reply that didn't go, why the Mac is out of reach and that what's sent waits for
    /// it, or a steer the Mac refused.
    @ViewBuilder private var statusLine: some View {
        if let unsent {
            HStack(alignment: .firstTextBaseline, spacing: Space.xxs) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.destructive)
                Text("Not sent · \(unsent.reason)").foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Button("Retry", action: onRetry).fontWeight(.semibold).buttonStyle(.borderless).disabled(stuck != nil)
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Not sent. \(unsent.reason)")
            .accessibilityAction(named: "Retry", onRetry)
        } else if case .offline(let reason) = model.mac.shown {
            VStack(alignment: .leading, spacing: 2) {
                Label(reason.message(mac: model.mac.name), systemImage: reason.symbol)
                if reason.comesBack, hasText { Label(SendsWhenConnected.line, systemImage: SendsWhenConnected.symbol) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if hasText, model.mac.isAway {
            Label(SendsWhenConnected.line, systemImage: SendsWhenConnected.symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let dropped {
            // The quote wraps rather than hiding what didn't arrive; Retry stays at the end of its first line.
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(dropped).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Button("Retry", action: onRetryDropped).fontWeight(.semibold).buttonStyle(.borderless).disabled(stuck != nil)
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

    /// The words in the field that are real commands for this session's agent: tinted as they are typed.
    private func highlights(in text: String) -> [NSRange] {
        guard let session else { return [] }
        return CommandHighlight.ranges(in: text, agent: session.agent, commands: model.tools.agent(session.agent)?.commands ?? [])
    }

    /// A hardware keyboard's keys: the suggestion list's, and Return to send. Anything not answered here is the field's.
    private func handle(_ key: HardwareKey) -> Bool {
        if let suggestion {
            let chosen = suggestion.options[min(highlighted, suggestion.options.count - 1)]
            switch key {
            case .up: highlighted = max(highlighted - 1, 0)
            case .down: highlighted = min(highlighted + 1, suggestion.options.count - 1)
            case .escape: dismissedFor = text
            case .tab: pick(chosen, at: suggestion.range, file: suggestion.files)
            case .enter(let shift):
                guard !shift else { return false }
                pick(chosen, at: suggestion.range, file: suggestion.files)
            }
            return true
        }
        guard case .enter(let shift) = key, !shift, hasText, stuck == nil, !uploading else { return false }
        send()
        return true
    }

    /// A suggestion replaces the word, ready for its arguments.
    private func pick(_ option: AgentOptions.Option, at range: NSRange, file: Bool = false) {
        let applied = file ? FileMentions.apply(option.id, agent: session?.agent ?? .claude, to: text, at: range)
            : CommandSuggestions.apply(option, to: text, at: range)
        text = applied.text
        selection = NSRange(location: min(applied.caret, applied.text.utf16.count), length: 0)
        focused = true
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

/// The + drawer's Model & Commands: the session's settings, as in its ⋯ menu, and the Mac's commands from `/v1/options`.
/// Photos, Camera and Files are the drawer's.
struct AddSheet: View {
    let session: RemoteSession?
    /// A command picked from the list goes into the field.
    var onCommand: (String) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var commands: [AgentOptions.Option] { session.flatMap { model.tools.agent($0.agent)?.commands } ?? [] }

    var body: some View {
        NavigationStack {
            List {
                SettingsMenu(session: session, style: .form)
                Section("Commands") {
                    ForEach(CommandRow.rows(commands), id: \.0) { command in
                        Button { onCommand(command.0); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(command.0).font(.body.monospaced())
                                Text(command.1).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Model & Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            .task {
                await model.tools.loadOptions()
                if let session { await model.tools.loadModels(for: session) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The Mac's slash commands for this agent, its custom ones included; the built-ins when it lists none.
private enum CommandRow {
    static let builtIn = [("/model", "Choose the model"), ("/effort", "Set reasoning effort"), ("/compact", "Summarize the conversation to free context"),
                          ("/clear", "Start over with an empty context"), ("/review", "Review the current changes")]

    static func rows(_ commands: [AgentOptions.Option]) -> [(String, String)] {
        commands.isEmpty ? builtIn : commands.map { ($0.id.hasPrefix("/") ? $0.id : "/\($0.id)", $0.label) }
    }
}
