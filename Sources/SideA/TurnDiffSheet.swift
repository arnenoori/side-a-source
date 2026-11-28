import SideAProtocol
import SwiftUI

struct ChangesChip: View {
    let model: SessionStore
    let live: LiveSession
    @State private var open = false

    var body: some View {
        let row = WireBuilders.session(live, store: model.store, finished: [])
        let turn = row.abilities.contains(.turnDiff) ? row.turnID : nil
        if turn != nil || live.cwd != nil {
            Button { open = true } label: { ChipLabel(symbol: "plus.forwardslash.minus", text: "Changes") }
                .buttonStyle(.plain)
                .accessibilityLabel("Changes")
                .sheet(isPresented: $open) { ChangesSheet(model: model, live: live, turnID: turn) }
        }
    }
}

/// What changed, from one of four places: this turn's edits, the working tree, the branch since it left the main
/// one, or one of its commits. A click on a line takes a remark; the remarks go to the agent as one message.
struct ChangesSheet: View {
    enum Source: Hashable { case turn, uncommitted, branch, commit(String) }

    let model: SessionStore
    let live: LiveSession
    let turnID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var source: Source
    @State private var files: [FileDiff]?
    @State private var running = false
    @State private var note: String?
    @State private var failure: String?
    @State private var commits: [GitChanges.Commit] = []
    @State private var comments: [DiffComment] = []
    /// The line a remark is being typed for, and its words so far.
    @State private var writing: String?
    @State private var words = ""

    init(model: SessionStore, live: LiveSession, turnID: String?) {
        self.model = model; self.live = live; self.turnID = turnID
        _source = State(initialValue: turnID == nil ? .uncommitted : .turn)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Changes", selection: picked) {
                    if turnID != nil { Text("This Turn").tag(0) }
                    if live.cwd != nil {
                        Text("Uncommitted").tag(1)
                        Text("Branch").tag(2)
                        Text("Commits").tag(3)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if case .commit(let id) = source, !commits.isEmpty {
                    Picker("Commit", selection: Binding(get: { id }, set: { source = .commit($0) })) {
                        ForEach(commits) { Text($0.subject.isEmpty ? String($0.id.prefix(7)) : $0.subject).tag($0.id) }
                    }
                    .labelsHidden().frame(maxWidth: 260)
                }
                if let summary = files.flatMap({ Self.summary($0, running: running) }) {
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !comments.isEmpty {
                Divider()
                HStack {
                    Text(comments.count == 1 ? "1 comment" : "\(comments.count) comments").font(.callout).foregroundStyle(.secondary)
                    Button("Clear") { comments = [] }.buttonStyle(.link)
                    Spacer()
                    Button("Add to Message") { hand() }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                        .disabled(live.sessionID == nil)
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
            }
        }
        .frame(minWidth: 620, idealWidth: 780, minHeight: 440, idealHeight: 660)
        .task(id: Stamp(source: source, status: live.status, turn: live.turnID)) { await load() }
        .onChange(of: source) { files = nil; failure = nil; writing = nil }
    }

    private struct Stamp: Hashable { let source: Source; let status: String; let turn: String? }

    /// The segments; Commits stands for whichever commit is shown.
    private var picked: Binding<Int> {
        Binding(get: {
            switch source {
            case .turn: 0
            case .uncommitted: 1
            case .branch: 2
            case .commit: 3
            }
        }, set: { tag in
            source = [Source.turn, .uncommitted, .branch][safe: tag] ?? .commit(commits.first?.id ?? "")
        })
    }

    @ViewBuilder private var content: some View {
        if let files {
            if files.isEmpty {
                ContentUnavailableView(running ? "No Changes Yet" : "No Changes", systemImage: "doc.text.magnifyingglass", description: note.map(Text.init))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let note { Label(note, systemImage: "info.circle").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                        ForEach(files, id: \.path) { file in
                            ReviewDiffCard(file: file, comments: comments.filter { $0.path == file.path && $0.scope == scope }, writing: $writing, words: $words,
                                           add: add, remove: { id in comments.removeAll { $0.id == id } })
                        }
                    }
                    .padding(18)
                }
            }
        } else if let failure {
            ContentUnavailableView {
                Label("Couldn't Load Changes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            ProgressView()
        }
    }

    /// "2 files · +14 −3 · still working", as the phone's subtitle reads.
    static func summary(_ files: [FileDiff], running: Bool) -> String? {
        guard !files.isEmpty else { return nil }
        let added = files.reduce(0) { $0 + $1.additions }, removed = files.reduce(0) { $0 + $1.deletions }
        let count = files.count == 1 ? "1 file" : "\(files.count) files"
        return "\(count) · +\(added) −\(removed)" + (running ? " · still working" : "")
    }

    private var scope: String { "\(source)" }

    private func add(_ comment: DiffComment) {
        var comment = comment
        comment.scope = scope
        comments.append(comment)
        writing = nil; words = ""
    }

    /// The remarks join whatever is typed to the session, ready to send.
    private func hand() {
        guard let id = live.sessionID else { return }
        let draft = model.drafts[id] ?? ""
        model.drafts[id] = (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : draft + "\n\n") + DiffReview.message(comments)
        model.desk.composerFocus += 1
        dismiss()
    }

    private func load() async {
        let asked = source
        do {
            let found: [FileDiff]
            var runs = false, says: String?
            switch asked {
            case .turn:
                guard let turnID else { return (files, running, note, failure) = ([], false, nil, nil) }
                let diff = try await SessionCommands(store: model.store).turnDiff(WireBuilders.key(live), turn: turnID)
                (found, runs, says) = (diff.files, diff.running, diff.note)
            case .uncommitted:
                found = try await GitChanges.uncommitted(in: live.cwd ?? "")
            case .branch:
                found = try await GitChanges.sinceBase(in: live.cwd ?? "")
            case .commit(let id):
                let listed = try await GitChanges.commits(in: live.cwd ?? "")
                guard asked == source else { return }
                commits = listed
                guard let shown = listed.first(where: { $0.id == id }) ?? listed.first else {
                    (files, running, note, failure) = ([], false, "The branch has no commits of its own yet.", nil)
                    return
                }
                if shown.id != id { return source = .commit(shown.id) }
                found = try await GitChanges.commit(shown.id, in: live.cwd ?? "")
            }
            guard asked == source else { return }
            (files, running, note, failure) = (found, runs, says, nil)
        } catch let error as SessionCommands.Failure {
            if asked == source, files == nil { failure = error.macMessage }
        } catch let error as GitChanges.Failure {
            if asked == source, files == nil { failure = error.message }
        } catch {
            if asked == source, files == nil { failure = error.localizedDescription }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// One file's diff. A line takes a remark when clicked, and shows the remarks made on it.
struct ReviewDiffCard: View {
    let file: FileDiff
    let comments: [DiffComment]
    @Binding var writing: String?
    @Binding var words: String
    let add: (DiffComment) -> Void
    let remove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.secondary).font(.system(size: 11))
                Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("−\(file.deletions)").foregroundStyle(.red)
            }
            .font(.system(size: 11.5)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 7)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { index, hunk in
                    if index > 0 { Text("⋯").foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.vertical, 2) }
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { row, line in self.line(line, row, in: hunk, index) }
                }
                if file.truncated {
                    Label("Cut short", systemImage: "scissors").font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
            .padding(.vertical, 4)
        }
        .background(Ink.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.line))
    }

    @ViewBuilder private func line(_ text: String, _ row: Int, in hunk: DiffHunk, _ index: Int) -> some View {
        let key = "\(file.path)#\(index)#\(row)"
        let place = DiffReview.line(of: row, in: hunk)
        let sign = text.first
        let tint: Color? = sign == "+" ? .green : sign == "-" ? .red : nil
        Button {
            guard place != nil else { return }
            words = ""; writing = writing == key ? nil : key
        } label: {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(sign == "\\" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 0.5)
                .background(tint.map { $0.opacity(0.12) } ?? .clear)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(place.map { "Line \($0.line): \(text)" } ?? text)
        .accessibilityHint("Comments on this line")
        if let place {
            ForEach(comments.filter { $0.line == place.line && $0.removed == place.removed }) { comment in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "text.bubble").foregroundStyle(Color.accentColor)
                    Text(comment.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Button { remove(comment.id) } label: { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove comment")
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.08))
            }
            if writing == key {
                CommentField(words: $words) {
                    let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !said.isEmpty else { return writing = nil }
                    add(DiffComment(id: UUID(), path: file.path, line: place.line, removed: place.removed, quote: String(text.dropFirst()), text: said))
                } cancel: { writing = nil }
            }
        }
    }

    private var icon: String {
        switch file.change {
        case .added: "plus.square"
        case .deleted: "minus.square"
        case .renamed: "arrow.right.square"
        default: "square.and.pencil"
        }
    }
}

private struct CommentField: View {
    @Binding var words: String
    let done: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Comment on this line", text: $words)
            .textFieldStyle(.roundedBorder).font(.callout)
            .focused($focused)
            .onSubmit(done)
            .onExitCommand(perform: cancel)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .onAppear { focused = true }
    }
}
