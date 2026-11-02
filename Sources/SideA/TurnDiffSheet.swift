import SideACore
import SideAProtocol
import SwiftUI

/// "Changes" in the session header, where the phone's row offers a turn diff.
struct ChangesChip: View {
    let model: SessionStore
    let live: LiveSession
    @State private var open = false

    var body: some View {
        let row = WireBuilders.session(live, store: model.store, finished: [])
        if let turn = row.turnID, row.abilities.contains(.turnDiff) {
            Button { open = true } label: { ChipLabel(symbol: "plus.forwardslash.minus", text: "Changes") }
                .buttonStyle(.plain)
                .accessibilityLabel("Changes in this turn")
                .sheet(isPresented: $open) { TurnDiffSheet(model: model, live: live, turnID: turn) }
        }
    }
}

/// Everything a turn changed, by the same command as the phone's Changes page: the Mac's note on what it leaves out,
/// then each file's hunks. A running turn reloads as the session moves.
struct TurnDiffSheet: View {
    let model: SessionStore
    let live: LiveSession
    let turnID: String
    @Environment(\.dismiss) private var dismiss
    @State private var diff: TurnDiff?
    @State private var failure: String?

    /// `diff`: one already read, shown until the next read lands.
    init(model: SessionStore, live: LiveSession, turnID: String, diff: TurnDiff? = nil) {
        self.model = model; self.live = live; self.turnID = turnID
        _diff = State(initialValue: diff)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Changes").font(.system(size: 15, weight: .semibold))
                if let summary = diff.flatMap(Self.summary) {
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 620)
        .task(id: "\(live.status ?? "")-\(live.turnID ?? "")") { await load() }
    }

    @ViewBuilder private var content: some View {
        if let diff {
            if diff.files.isEmpty {
                ContentUnavailableView(diff.running ? "No Changes Yet" : "No Changes", systemImage: "doc.text.magnifyingglass",
                                       description: diff.note.map(Text.init))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let note = diff.note {
                            Label(note, systemImage: "info.circle").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        ForEach(diff.files, id: \.path) { FileDiffCard(file: $0) }
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
    static func summary(_ diff: TurnDiff) -> String? {
        guard !diff.files.isEmpty else { return nil }
        let added = diff.files.reduce(0) { $0 + $1.additions }, removed = diff.files.reduce(0) { $0 + $1.deletions }
        let files = diff.files.count == 1 ? "1 file" : "\(diff.files.count) files"
        return "\(files) · +\(added) −\(removed)" + (diff.running ? " · still working" : "")
    }

    private func load() async {
        do throws(SessionCommands.Failure) {
            diff = try await SessionCommands(store: model.store).turnDiff(WireBuilders.key(live), turn: turnID)
            failure = nil
        } catch {
            if diff == nil { failure = error.macMessage }
        }
    }
}

/// One file: its path and counts, then each hunk's lines, tinted by sign.
struct FileDiffCard: View {
    let file: FileDiff

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
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in DiffLine(line: line) }
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
        .textSelection(.enabled)
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

private struct DiffLine: View {
    let line: String

    var body: some View {
        let sign = line.first
        let tint: Color? = sign == "+" ? .green : sign == "-" ? .red : nil
        Text(line.isEmpty ? " " : line)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(sign == "\\" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 0.5)
            .background(tint.map { $0.opacity(0.12) } ?? .clear)
    }
}
