import AppKit
import SideAProtocol
import SideASessionKit
import SwiftUI

struct SessionComposer: View {
    @Bindable var model: SessionStore
    let target: ComposerTarget
    @State private var height = ComposerField.lineHeight
    @State private var caret = Int.max
    @State private var highlighted = 0
    /// esc closed the list for this word; typing another opens it again.
    @State private var dismissed: String?
    /// Files matching the `@word` at the caret.
    @State private var files: [String] = []
    /// Which earlier prompt ↑ last brought back.
    @State private var recalled: Int?
    @State private var stashing = false

    private var id: String { target.id }
    private var text: Binding<String> { Binding(get: { model.drafts[id] ?? "" }, set: { model.drafts[id] = $0 }) }
    private var empty: Bool { (model.drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty }
    private var photos: [Upload] { model.attachments[id] ?? [] }

    var body: some View {
        let queued = model.queued(id)
        VStack(alignment: .leading, spacing: 6) {
            if !queued.isEmpty { QueuedList(model: model, id: id, replies: queued).padding(.leading, 30).padding(.trailing, 32) }
            if !photos.isEmpty { chips.padding(.leading, 30) }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: choosePhotos) {
                    Image(systemName: "paperclip").font(.system(size: 14)).frame(width: 22, height: 33)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Attach photos")
                .accessibilityLabel("Attach photos")
                if !model.desk.stash.isEmpty {
                    Button { stashing = true } label: {
                        Image(systemName: "tray.full").font(.system(size: 13)).frame(width: 22, height: 33)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Stashed messages (⌘S)")
                    .accessibilityLabel("Stashed messages, \(model.desk.stash.count)")
                    .popover(isPresented: $stashing, arrowEdge: .top) { StashList(model: model, id: id) { stashing = false } }
                }
                ComposerField(text: text, height: $height, placeholder: target.placeholder, onKey: key,
                              onImages: { images in
                                  model.attach(images, to: id)
                                  return true
                              },
                              onCaret: { caret = $0 },
                              wantsFocus: model.desk.composerFocus != model.desk.composerTaken,
                              onFocus: { model.desk.composerTaken = model.desk.composerFocus })
                    .frame(height: height)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Ink.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        if let open = suggestions {
                            SuggestionList(options: open.options, highlighted: min(highlighted, open.options.count - 1)) { choose($0, in: open.range) }
                                .offset(y: -(height + 16 + 6))
                                .transition(Ink.rise(4))
                        } else if let mention, !files.isEmpty {
                            MentionList(paths: files, highlighted: min(highlighted, files.count - 1)) { choose(file: $0, in: mention.range) }
                                .offset(y: -(height + 16 + 6))
                                .transition(Ink.rise(4))
                        }
                    }
                trailing
            }
            status.font(.system(size: 11)).frame(minHeight: 14)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            let (folder, agent) = (target.live?.cwd, target.claude ? AgentProvider.claude : .codex)
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    // A photo is attached; any other file goes in by its path, which is how the agents read files.
                    if (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true, let data = try? Data(contentsOf: url) {
                        Task { @MainActor in model.attach([data], to: id) }
                    } else {
                        let word = SideASessionKit.FileMentions.dropped(url.path, folder: folder, agent: agent)
                        Task { @MainActor in
                            let draft = model.drafts[id] ?? ""
                            model.drafts[id] = draft + (draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " ") + word + " "
                        }
                    }
                }
            }
            return true
        }
        .task(id: mention?.query) {
            guard let query = mention?.query, let folder = target.live?.cwd else { return files = [] }
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            files = Array(await SideA.FileMentions.shared.matches(query, in: folder).prefix(8))
        }
        .animation(Ink.glide, value: files)
        .animation(Ink.ease, value: model.outcomes[id])
        .animation(Ink.ease, value: photos.map(\.id))
        .animation(Ink.glide, value: suggestions?.options.map(\.id))
        .task { model.loadStash(); await model.loadCommands() }
    }


    private var suggestions: (range: NSRange, options: [CommandSuggestions.Option])? {
        guard let found = CommandSuggestions.word(in: model.drafts[id] ?? "", caret: caret, agent: target.claude ? .claude : .codex), found.word != dismissed else { return nil }
        let options = CommandSuggestions.matches(found.word, in: target.claude ? model.commands.claude : model.commands.codex)
        guard !options.isEmpty, !(options.count == 1 && options[0].id == found.word) else { return nil }
        return (found.range, options)
    }

    private var mention: (range: NSRange, query: String)? {
        guard suggestions == nil, target.live?.cwd != nil,
              let found = SideASessionKit.FileMentions.word(in: model.drafts[id] ?? "", caret: caret), "@" + found.query != dismissed else { return nil }
        return found
    }

    private func choose(file path: String, in range: NSRange) {
        model.drafts[id] = SideASessionKit.FileMentions.apply(path, agent: target.claude ? .claude : .codex, to: model.drafts[id] ?? "", at: range).text
        highlighted = 0
        files = []
    }

    private func choose(_ option: CommandSuggestions.Option, in range: NSRange) {
        model.drafts[id] = CommandSuggestions.apply(option, to: model.drafts[id] ?? "", at: range).text
        highlighted = 0
    }

    @ViewBuilder private var trailing: some View {
        if empty, let when = target.interrupt {
            Button { model.interrupt(id) } label: {
                Image(systemName: "stop.circle.fill").font(.system(size: 24))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(when == .now ? "Stop its current turn (⎋)" : "Stop before its next step (⎋)")
            .accessibilityLabel(when == .now ? "Stop now" : "Stop before its next step")
        } else {
            Button { model.compose(id, how: .now) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            .disabled(empty)
            .help("Send (↩)")
            .accessibilityLabel("Send")
            .contextMenu { sendMenu }
            .overlay(alignment: .bottomTrailing) {
                if target.queues || offersNote {
                    Menu { sendMenu } label: {
                        Image(systemName: "chevron.down.circle.fill").font(.system(size: 11)).symbolRenderingMode(.palette)
                            .foregroundStyle(Color.primary, Color(nsColor: .windowBackgroundColor))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .offset(x: 4, y: 3)
                    .help("Other ways to send")
                    .accessibilityLabel("Other ways to send")
                }
            }
        }
    }

    private var offersNote: Bool { target.abilities.contains(.note) && !target.becomesNote }

    @ViewBuilder private var sendMenu: some View {
        Button("Send Now") { model.compose(id, how: .now) }
        if target.queues { Button("Send After This Turn") { model.compose(id, how: .afterTurn) } }
        if offersNote { Button("Send as Note") { model.compose(id, how: .note) } }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(photos, id: \.id) { photo in
                    Group {
                        if let image = NSImage(contentsOfFile: photo.path) {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.line))
                    .overlay(alignment: .topTrailing) {
                        Button { model.detach(photo, from: id) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 14)).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.black.opacity(0.6))
                        }
                        .buttonStyle(.plain).offset(x: 5, y: -5)
                        .help("Remove")
                        .accessibilityLabel("Remove photo")
                    }
                }
            }
            .padding(.top, 6).padding(.trailing, 6)
        }
    }

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose photos to send with your reply"
        guard panel.runModal() == .OK else { return }
        model.attach(panel.urls.compactMap { try? Data(contentsOf: $0) }, to: id)
    }

    private func key(_ key: ComposerField.Key) -> Bool {
        if let open = suggestions {
            switch key {
            case .up: highlighted = (min(highlighted, open.options.count - 1) - 1 + open.options.count) % open.options.count; return true
            case .down: highlighted = (min(highlighted, open.options.count - 1) + 1) % open.options.count; return true
            case .send, .tab: choose(open.options[min(highlighted, open.options.count - 1)], in: open.range); return true
            case .escape:
                dismissed = CommandSuggestions.word(in: model.drafts[id] ?? "", caret: caret, agent: target.claude ? .claude : .codex)?.word
                return true
            case .queue, .other, .stash: break
            }
        } else if let mention, !files.isEmpty {
            switch key {
            case .up: highlighted = (min(highlighted, files.count - 1) - 1 + files.count) % files.count; return true
            case .down: highlighted = (min(highlighted, files.count - 1) + 1) % files.count; return true
            case .send, .tab: choose(file: files[min(highlighted, files.count - 1)], in: mention.range); return true
            case .escape:
                dismissed = "@" + mention.query
                return true
            case .queue, .other, .stash: break
            }
        }
        switch key {
        case .other:
            // The other way to send, where there is one: after this turn, or as a note.
            model.compose(id, how: target.queues ? .afterTurn : offersNote ? .note : .now)
            return true
        case .up, .down:
            guard let step = PromptRecall.step(key == .up ? 1 : -1, draft: model.drafts[id] ?? "", at: recalled, prompts: model.desk.prompts(id)) else { return false }
            model.drafts[id] = step.draft
            recalled = step.index
            return true
        case .send:
            model.compose(id, how: .now)
            return true
        case .queue:
            model.compose(id, how: target.queues ? .afterTurn : .now)
            return true
        case .escape:
            guard target.interrupt != nil else { return false }
            model.interrupt(id)
            return true
        case .stash:
            // With something typed it is set aside; with nothing, the stash opens to take one back.
            if empty { stashing = !model.desk.stash.isEmpty } else { model.stash(id) }
            return true
        case .tab: return false
        }
    }


    @ViewBuilder private var status: some View {
        if let outcome = model.outcomes[id], case .failed(let reason) = outcome.result {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text("Not sent").foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Button("Retry") { model.retry(id) }.buttonStyle(.link).fontWeight(.semibold)
                Text(reason).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Not sent. \(reason)")
            .accessibilityAction(named: "Retry") { model.retry(id) }
        } else if let live = target.live, let flag = SessionCommands(store: model.store).flag(live), flag.kind == .unsent {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(flag.text).foregroundStyle(.secondary).lineLimit(2)
                Button("Retry") { model.retryDropped(id) }.buttonStyle(.link).fontWeight(.semibold)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Retry") { model.retryDropped(id) }
        } else if let live = target.live, let waiting = model.mail[live.pid] {
            waitingMail(live, kind: waiting)
        } else if let outcome = model.outcomes[id], case .sent(let delivery) = outcome.result {
            Label(Self.label(delivery, target: target), systemImage: Self.symbol(delivery)).foregroundStyle(.secondary)
        } else {
            Text(target.hint).foregroundStyle(.secondary)
        }
    }

    private func waitingMail(_ live: LiveSession, kind: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: kind == "note" ? "envelope" : "pause.circle").foregroundStyle(.secondary)
            Text(kind == "note" ? "Note waiting" : "Stopping before its next step").foregroundStyle(.secondary)
            if kind == "note" {
                Menu {
                    Button("Edit") { model.editNote(live) }
                    Button("Copy") { model.noteText(live).map(SessionStore.copy) }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteMail(live) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Note actions")
            } else {
                Button("Don't Stop") { model.deleteMail(live) }.buttonStyle(.link)
            }
        }
        .contextMenu {
            if kind == "note" {
                Button("Edit") { model.editNote(live) }
                Button("Copy") { model.noteText(live).map(SessionStore.copy) }
                Button("Delete", role: .destructive) { model.deleteMail(live) }
            }
        }
    }

    static func label(_ delivery: ReplyResult.Delivery, target: ComposerTarget) -> String {
        switch delivery {
        case .typed: target.terminal ? "Sent to its terminal" : "Typed into its terminal"
        case .followUp: "Sent · it started its next turn"
        case .queued: "Queued · goes when this turn ends"
        case .note: "Left as a note"
        case .inbox: "In its inbox · it reads it within a second"
        default: "Sent"
        }
    }

    static func symbol(_ delivery: ReplyResult.Delivery) -> String {
        switch delivery {
        case .queued: "clock"
        case .note, .inbox: "envelope"
        default: "checkmark.circle"
        }
    }
}

struct SuggestionList: View {
    let options: [CommandSuggestions.Option]
    let highlighted: Int
    let choose: (CommandSuggestions.Option) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                Button { choose(option) } label: {
                    HStack(spacing: 10) {
                        Text(option.id).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(index == highlighted ? Color.white : .primary)
                        Text(option.label).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(index == highlighted ? Color.white.opacity(0.85) : .secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(index == highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == highlighted ? .isSelected : [])
            }
        }
        .padding(5)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }
}
