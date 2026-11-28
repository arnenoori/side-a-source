import PhotosUI
import SideAProtocol
import SideASessionKit
import SwiftUI
import UniformTypeIdentifiers

enum FollowBadge: Equatable {
    case none, newMessages(Int), waiting
}

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

    static func available(for session: RemoteSession?) -> [Steer] {
        guard let session, SessionPhase(session) == .working || SessionPhase(session) == .needsYou else { return [] }
        var steers: [Steer] = []
        if (session.hosted != nil || session.abilities.contains(.replyTerminal)) && session.abilities.contains(.interrupt) {
            steers.append(.interruptNow)
        }
        if session.agent == .claude && session.abilities.contains(.interrupt) && session.mail == nil { steers.append(.stopBeforeNextStep) }
        if session.abilities.contains(.note) { steers.append(.note) }
        return steers
    }
}

struct Composer: View {
    @Binding var text: String
    let placeholder: String
    let canInterrupt: Bool
    let showsFollow: Bool
    let follow: FollowBadge
    @Binding var focused: Bool
    let onSend: () -> Void
    let onInterrupt: () -> Void
    let onFollow: () -> Void
    let session: RemoteSession?
    var steers: [Steer] = []
    var onSteer: (Steer) -> Void = { _ in }
    var disabledReason: String?
    var unsent: TranscriptStore.Unsent?
    var onRetry: () -> Void = {}
    var notice: String?
    var deliveries: [Delivery] = []
    var delivery: Delivery?
    var onDeliver: (Delivery) -> Void = { _ in }
    var dropped: String?
    var onRetryDropped: () -> Void = {}
    var choosingModel: Binding<Bool>?

    @State private var showsAdd = false
    @State private var surface = AttachSurface()
    @State private var sends = 0
    @State private var interrupts = 0
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var highlighted = 0
    @State private var dismissedFor: String?
    @State private var files: [String] = []
    @State private var showsQueue = false
    @State private var editing: QueuedReply?
    @State private var stashed = ""
    @State private var dictation = Dictation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(AppModel.self) private var model

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

    private var mention: String? { FileMentions.word(in: text, caret: caret)?.query }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var uploading: Bool { session.map { model.tools.attachments.isUploading($0.id) } ?? false }
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
                    RecentStripView(strip: surface.strip, window: surface.drawer.window)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)), removal: .opacity))
                }
                card
                DictationNote(dictation: dictation)
                if editing != nil || unsent != nil || notice != nil || disabledReason != nil || dropped != nil || blocked != nil || model.mac.shown.isOffline
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
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            let found = await model.tools.files(session.id, matching: mention)
            if !Task.isCancelled { files = found }
        }
        .animation(Motion.snappy(reduceMotion), value: session?.queued?.count)
        .onChange(of: session?.queued) { _, queued in
            if let editing, queued?.contains(where: { $0.id == editing.id }) != true { stopEditing() }
        }
        .sheet(isPresented: $showsQueue) {
            if let session { QueueSheet(sessionID: session.id) { edit($0) } }
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
    private func debugLaunch() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--focus-composer") || arguments.contains("--tray-full") || arguments.contains("--drawer") || arguments.contains("--show-picker") || arguments.contains("--show-options") || arguments.contains("--draft") || arguments.contains("--show-queue") else { return }
        try? await Task.sleep(for: .milliseconds(1200))
        if arguments.contains("--show-picker") { surface.showsPicker = true }
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
        if let index = arguments.firstIndex(of: "--draft"), index + 1 < arguments.count {
            text = arguments[index + 1]
            selection = NSRange(location: text.utf16.count, length: 0)
        }
        if arguments.contains("--show-queue") { showsQueue = true }
        if arguments.contains("--focus-composer") { focused = true; try? await Task.sleep(for: .milliseconds(900)) }
        if let index = arguments.firstIndex(of: "--drawer"), index + 1 < arguments.count {
            if !surface.open(key: session?.id, tools: model.tools, reduceMotion: reduceMotion), session != nil { showsAdd = true }
            if arguments[index + 1] == "large" { try? await Task.sleep(for: .milliseconds(900)); surface.drawer.toggleDetent() }
            if arguments[index + 1] == "camera" { try? await Task.sleep(for: .milliseconds(900)); surface.drawer.openCamera() }
            if arguments.contains("--camera-interrupted") { try? await Task.sleep(for: .milliseconds(600)); surface.drawer.camera.setInterrupted(true) }
        }
    }
    #endif

    private var room: Int { surface.room(session?.id, tools: model.tools) }

    private var attachButton: AttachButton {
        let options: (() -> Void)? = session == nil ? nil : { showsAdd = true }
        let mention: (() -> Void)? = session == nil ? nil : { mentionFile() }
        return AttachButton(surface: surface, key: session?.id, tools: model.tools, diameter: 44, bare: true, onSessionFile: mention,
                            offersScreen: true, hosted: session?.hosted, onOptions: options)
    }

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

    private var card: some View {
        VStack(spacing: 0) {
            ComposerField(text: $text, selection: $selection, isFocused: $focused, placeholder: placeholder,
                          insets: UIEdgeInsets(top: 12, left: Space.m, bottom: 2, right: Space.m),
                          drawer: surface.drawer, paste: surface.target, onKey: handle, highlights: highlights(in:))
            HStack(spacing: Space.xxs) {
                attachButton
                    .attachPopover(surface)
                if let session, let choosingModel, disabledReason == nil {
                    ModelChip(session: session, isPresented: choosingModel)
                }
                Spacer(minLength: 0)
                if mode == .stop, disabledReason == nil {
                    Button("Dictate", systemImage: "mic") { Task { await dictation.begin() } }
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                        .buttonStyle(.plain)
                        .transition(.opacity)
                }
                trailingControl
                    .opacity(disabledReason == nil ? 1 : 0)
                    .padding(.trailing, 8)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }
        .disabled(disabledReason != nil)
        .dictating(dictation)
        .frame(minHeight: 48)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26, style: .continuous))
    }

    private var mode: TrailingMode {
        if editing != nil { return .save }
        if hasText { return .send }
        return canInterrupt ? .stop : .dictate
    }

    @ViewBuilder private var trailingControl: some View {
        let mode = mode
        let deferred = mode == .send && model.mac.isAway
        let symbol = deferred ? SendsWhenConnected.symbol : mode == .send ? delivery?.symbol ?? mode.symbol : mode.symbol
        let idle = mode == .send || mode == .save ? uploading || stuck != nil : mode == .stop && offline
        Button {
            switch mode {
            case .send, .save: send()
            case .dictate: Task { await dictation.begin() }
            case .stop:
                interrupts += 1
                onInterrupt()
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: mode == .dictate ? 17 : mode == .stop ? 13 : 15, weight: mode == .dictate ? .medium : .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(mode == .dictate ? AnyShapeStyle(.secondary) : AnyShapeStyle(mode == .stop ? Color.white : Color(.systemBackground)))
                .frame(width: 36, height: 36)
                .background {
                    Circle().fill(mode == .stop ? Color.destructive : Color(.label)).opacity(mode == .dictate ? 0 : 1)
                }
                // Glass renders what's on it vibrant; the send circle stays solid.
                .compositingGroup()
                .hitArea(horizontal: 4, vertical: 4)
                .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .disabled(idle)
        .opacity(idle ? 0.3 : 1)
        .contentShape(.contextMenuPreview, Circle())
        .contextMenu {
            if mode == .stop {
                ForEach(steers.filter { $0 != .interruptNow }, id: \.self) { steer in
                    Button(steer.title, systemImage: steer.symbol) { onSteer(steer) }
                }
            } else if mode == .send {
                ForEach(deliveries, id: \.self) { delivery in
                    Button {
                        sends += 1
                        onDeliver(delivery)
                    } label: {
                        Label { Text(delivery.title); Text(delivery.hint) } icon: { Image(systemName: delivery.symbol) }
                    }
                }
                .disabled(uploading || stuck != nil)
            }
        }
        .accessibilityLabel(deferred ? SendsWhenConnected.action : mode == .send ? delivery?.title ?? mode.accessibilityLabel : mode.accessibilityLabel)
        .accessibilityHint(mode == .send && !deliveries.isEmpty ? "Touch and hold for other ways to send"
            : mode == .stop && steers.contains { $0 != .interruptNow } ? "Touch and hold for other ways to stop" : "")
        .animation(Motion.snappy(reduceMotion), value: mode)
    }

    private enum TrailingMode {
        case dictate, send, stop, save
        var symbol: String {
            switch self {
            case .dictate: "mic"
            case .send: "arrow.up"
            case .stop: "stop.fill"
            case .save: "checkmark"
            }
        }
        var accessibilityLabel: String {
            switch self {
            case .dictate: "Dictate"
            case .send: "Send"
            case .stop: "Stop"
            case .save: "Save queued message"
            }
        }
    }

    private var offline: Bool { model.mac.shown.isOffline }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            if editing != nil {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text("Editing a queued message").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Cancel") { stopEditing() }.fontWeight(.semibold).buttonStyle(.borderless).hitArea(vertical: 12)
                }
                .font(.footnote)
            }
            problem
        }
    }

    @ViewBuilder private var problem: some View {
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

    private func highlights(in text: String) -> [NSRange] {
        guard let session else { return [] }
        return CommandHighlight.ranges(in: text, agent: session.agent, commands: model.tools.agent(session.agent)?.commands ?? [])
    }

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

    private func pick(_ option: AgentOptions.Option, at range: NSRange, file: Bool = false) {
        let applied = file ? FileMentions.apply(option.id, agent: session?.agent ?? .claude, to: text, at: range)
            : CommandSuggestions.apply(option, to: text, at: range)
        text = applied.text
        selection = NSRange(location: min(applied.caret, applied.text.utf16.count), length: 0)
        focused = true
    }

    private func send() {
        sends += 1
        if let reply = editing, let session { return save(reply, in: session.id) }
        onSend()
    }

    private func edit(_ reply: QueuedReply) {
        if editing == nil { stashed = text }
        editing = reply
        text = reply.text
        selection = NSRange(location: text.utf16.count, length: 0)
        focused = true
    }

    private func stopEditing() {
        editing = nil
        text = stashed
        stashed = ""
    }

    private func save(_ reply: QueuedReply, in session: SessionKey) {
        let reworded = text, held = stashed, model = model
        stopEditing()
        Task {
            do { try await model.reword(reply, to: reworded, in: session) } catch ToolError.cancelled {} catch {
                model.transcripts.notice(MacTools.message(error), in: session)
                guard editing == nil, text == held else { return }
                edit(reply)
                text = reworded
            }
        }
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

struct AddSheet: View {
    let session: RemoteSession?
    var onCommand: (String) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var commands: [AgentOptions.Option] { session.flatMap { model.tools.agent($0.agent)?.commands } ?? [] }

    var body: some View {
        NavigationStack {
            List {
                Section {
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
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            .task {
                await model.tools.loadOptions()
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private enum CommandRow {
    static let builtIn = [("/model", "Choose the model"), ("/effort", "Set reasoning effort"), ("/compact", "Summarize the conversation to free context"),
                          ("/clear", "Start over with an empty context"), ("/review", "Review the current changes")]

    static func rows(_ commands: [AgentOptions.Option]) -> [(String, String)] {
        commands.isEmpty ? builtIn : commands.map { ($0.id.hasPrefix("/") ? $0.id : "/\($0.id)", $0.label) }
    }
}
