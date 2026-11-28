import Foundation
import os
import SideACore
import SideAProtocol
import SideASessionKit
import SwiftUI

/// The Mac has no record yet of a request it answered or a message on its way out, so the shared layout is given
/// these, which are never built. They become real when the Mac's composer shows what it sent.
struct MacAnswer: Hashable, Identifiable { let id: String }
struct MacSent: OutgoingTurn {
    let id: String
    let at: Date
    let isPendingNote: Bool
}

typealias MacLayout = TranscriptLayout<MacAnswer, MacSent>
typealias MacItem = TranscriptItem<MacAnswer, MacSent>

/// A conversation as the phone reads it (steps with their status, output and diffs; thinking), held for the Mac's
/// window. Read through the same bridge call the phone's pages come from, in process.
struct WireWindow: Sendable {
    var messages: [TranscriptMessage]
    /// The user's and the agent's words, laid out for the Mac's message view, by seq.
    var prepared: [Int: SessionMessage]
    /// Where the page before this one ends; nil at the start of the conversation.
    var before: Cursor?
    var generation: String

    static let page = 200

    init(_ page: TranscriptPage) {
        messages = page.messages
        prepared = Self.prepare(page.messages)
        before = page.before
        generation = page.generation
    }

    /// An earlier page joins the front. One from another generation (the transcript was rebuilt meanwhile) is left out:
    /// the next load brings a whole window of the new one.
    @discardableResult
    mutating func prepend(_ page: TranscriptPage) -> Bool {
        guard page.generation == generation else { return false }
        let have = Set(messages.map(\.seq))
        let new = page.messages.filter { !have.contains($0.seq) }
        messages = new + messages
        prepared.merge(Self.prepare(new)) { old, _ in old }
        before = page.before
        return true
    }

    static func prepare(_ messages: [TranscriptMessage]) -> [Int: SessionMessage] {
        var prepared: [Int: SessionMessage] = [:]
        for message in messages {
            guard let role = classic(message.role) else { continue }
            let text = message.text ?? ""
            var segments: [MessageSegment] = []
            if role == "assistant" {
                segments = MessageText.segments(text).map { kind, text in
                    switch kind {
                    case .code: MessageSegment(kind: .code, text: AttributedString(text))
                    case .table: MessageSegment(kind: .table, rows: MessageText.table(text))
                    case .prose: MessageSegment(kind: .prose, text: MessageText.markdown(text))
                    }
                }
            }
            prepared[message.seq] = SessionMessage(role: role, text: text, tools: [], uuid: message.uuid, ts: message.at, inherited: message.inherited,
                                                   model: message.model, segments: segments, key: "w\(message.seq)")
        }
        return prepared
    }

    /// The Mac message view's name for a role it draws; nil for the ones the layout turns into steps.
    static func classic(_ role: TranscriptRole) -> String? {
        switch role {
        case .user: "user"
        case .assistant: "assistant"
        case .compact: "compact"
        case .error: "error"
        default: nil
        }
    }
}

extension SessionPrefs {
    /// The conversation drawn the old way, with each run of steps as one line of text.
    static let classicKey = "sessionsClassicTranscript"
}

extension SessionStore {
    /// Reads the newest page of a conversation as the phone would get it. A failure leaves what was read before in
    /// place, and of two reads under way the later one asked for is the one kept.
    func loadWire(_ id: String) async {
        guard !store.isDemo else { return }
        desk.wireAsked[id, default: 0] += 1
        let asked = desk.wireAsked[id]
        do {
            let page = try RemoteTranscript.page(try await remoteReply(["show", "--format", "remote", "--limit", String(WireWindow.page), "--", id]))
            let window = await Task.detached { WireWindow(page) }.value
            guard desk.wireAsked[id] == asked else { return }
            // Earlier pages the reader loaded stay, while the transcript is the one they were read from.
            if let held = desk.wire[id], held.generation == window.generation, let first = window.messages.first?.seq,
               held.messages.contains(where: { $0.seq < first }) {
                var joined = window
                let older = held.messages.filter { $0.seq < first }
                joined.messages = older + window.messages
                joined.prepared.merge(held.prepared) { new, _ in new }
                joined.before = held.before
                desk.wire[id] = joined
            } else {
                desk.wire[id] = window
            }
            desk.keepWire(id)
            desk.settle(id, said: page.messages.filter { $0.role == .user }.map { ($0.text ?? "", $0.at) })
        } catch {
            SessionStore.wireLog.error("transcript not read: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadWireEarlier(_ id: String) {
        guard let cursor = desk.wire[id]?.before, !desk.wireLoading.contains(id) else { return }
        desk.wireLoading.insert(id)
        Task {
            defer { desk.wireLoading.remove(id) }
            guard let reply = try? await remoteReply(["show", "--format", "remote", "--limit", String(WireWindow.page), "--before", cursor.raw, "--", id]),
                  let page = try? RemoteTranscript.page(reply) else { return }
            // The transcript was rebuilt since this window was read, so the whole window is read again.
            if desk.wire[id]?.prepend(page) == false { await loadWire(id) }
        }
    }
}

extension SessionStore {
    nonisolated static let wireLog = Logger(subsystem: Perf.subsystem, category: "sessions")
}

extension SessionDesk {
    static let wireKept = 12

    /// The windows of the conversations opened most recently are kept, so going back to one paints at once.
    func keepWire(_ id: String) {
        wireOrder.removeAll { $0 == id }
        wireOrder.append(id)
        while wireOrder.count > Self.wireKept { wire[wireOrder.removeFirst()] = nil }
    }
}

/// What changes when the open conversation does: a new message, or more of the reply that is arriving.
struct WireStamp: Hashable {
    let id: String?
    let count: Int
    let last: String?
    let length: Int

    @MainActor init(_ model: SessionStore) {
        let detail = model.detail.flatMap { $0.session.id == model.selectedID ? $0 : nil }
        id = model.selectedID
        count = detail?.messages.count ?? 0
        last = detail?.messages.last?.key
        length = (detail?.messages.last?.text.count ?? 0) + (detail?.messages.last?.tools.count ?? 0)
    }
}

/// A conversation with its steps in detail: each one a sentence with its state and how long it took, opening to its
/// output; edits as diffs; thinking; a finished turn's work folded behind "Worked for 4m".
struct WireConversation: View {
    let model: SessionStore
    let session: SessionInfo
    let window: WireWindow
    let working: Bool
    /// The conversations branched from this one, by the message each left at.
    var forks: [String: [SessionInfo]] = [:]
    var onResend: ((String) -> Void)?
    @State private var open: Set<String> = []

    var body: some View {
        let items = MacLayout.folded(MacLayout.items(messages: window.messages, earlier: 0, working: working), working: working, since: nil)
        let rows = MacLayout.rows(items)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if window.before != nil {
                    Button { model.loadWireEarlier(session.id) } label: {
                        Divided(text: model.desk.wireLoading.contains(session.id) ? "Loading earlier messages…" : "Show earlier messages")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(row.items) { item in self.view(item) }
                    }
                }
                ForEach(model.desk.outgoing[session.id] ?? []) { sent in
                    MessageView(message: SessionMessage(role: "user", text: sent.text, tools: [], uuid: sent.id.uuidString, ts: nil, inherited: false, model: nil,
                                                        key: sent.id.uuidString), flashing: false)
                        .opacity(0.55)
                        .accessibilityLabel("Sending: \(sent.text)")
                }
            }
            .frame(maxWidth: 700)
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
        .defaultScrollAnchor(.bottom)
    }

    private func toggle(_ id: String) { withAnimation(Ink.glide) { open.formSymmetricDifference([id]) } }

    private func view(_ item: MacItem) -> AnyView {
        switch item {
        case .separator(let date):
            return AnyView(Divided(text: Self.day(date)).padding(.vertical, 6))
        case .user(let message), .assistant(let message), .notice(let message):
            guard let prepared = window.prepared[message.seq] else { return AnyView(EmptyView()) }
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                if case .assistant = item, startsTurn(message) { AgentHeader(codex: session.isCodex).padding(.top, 4) }
                MessageView(message: prepared, flashing: false, onResend: onResend,
                            onRewind: model.canRewind(session, prepared) ? { model.rewind(session, at: prepared) } : nil)
                    .opacity(message.inherited ? 0.6 : 1)
                // A reply read as several messages shares one id: the branch hangs under the last of them.
                if let branched = forks[prepared.uuid], window.messages.last(where: { $0.uuid == message.uuid })?.seq == message.seq {
                    ForEach(branched) { fork in BranchMarker(text: "Branched into", name: fork.name) { model.open(fork.id) } }
                }
            })
        case .tool(let tool), .thinking(let tool), .subagent(let tool):
            return AnyView(WireStep(tool: tool, open: open.contains(item.id)) { toggle(item.id) })
        case .images(let tool):
            return AnyView(Label(tool.images.count == 1 ? "1 image" : "\(tool.images.count) images", systemImage: "photo")
                .font(.callout).foregroundStyle(.secondary).padding(.leading, 22))
        case .file(let tool, let path, let bytes):
            return AnyView(WireFile(tool: tool, path: path, bytes: bytes))
        case .diff(_, let diff):
            return AnyView(WireDiff(diff: diff, whole: open.contains(item.id)) { toggle(item.id) })
        case .group(let group):
            let shown = open.contains(item.id) != group.running
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                WireFoldHeader(title: group.title, working: group.running, open: shown) { toggle(item.id) }
                if shown {
                    ForEach(group.tools) { tool in
                        let id = "t-\(tool.id)"
                        WireStep(tool: tool, open: open.contains(id)) { toggle(id) }
                    }
                    .padding(.leading, 14)
                }
            })
        case .turn(let fold):
            // A live turn starts open and a finished one closed; a click flips whichever it is.
            let shown = open.contains(item.id) != fold.live
            let worked = fold.duration.flatMap { SessionFormat.duration($0) }.map { "Worked for \($0)" } ?? "Worked"
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                WireFoldHeader(title: fold.live ? "Working" : worked, working: fold.live, open: shown) { toggle(item.id) }
                if shown {
                    VStack(alignment: .leading, spacing: 8) { ForEach(fold.items) { inner in self.view(inner) } }
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) { Rectangle().fill(Ink.line).frame(width: 1) }
                }
            })
        case .turnEnd(let end):
            let line = [end.model, end.duration.flatMap { SessionFormat.duration($0) }].compactMap { $0 }.joined(separator: "  ·  ")
            return AnyView(Group { if !line.isEmpty { Text(line).font(.caption).foregroundStyle(.tertiary) } })
        case .earlier, .answered, .request, .question, .outgoing, .mail:
            return AnyView(EmptyView())
        }
    }

    /// The first reply after the user spoke names the agent, as the old view does.
    private func startsTurn(_ message: TranscriptMessage) -> Bool {
        guard let index = window.messages.firstIndex(where: { $0.seq == message.seq }) else { return false }
        return window.messages[..<index].last { $0.role == .user || $0.role == .assistant }?.role != .assistant
    }

    static func day(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "Today, \(date.formatted(date: .omitted, time: .shortened))"
            : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
    }
}

/// The line a fold or a group of steps closes to.
struct WireFoldHeader: View {
    let title: String
    let working: Bool
    let open: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                if working { WorkingMark() }
                Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}

/// One step: what it did, whether it worked and how long it took, opening to what it printed.
struct WireStep: View {
    let tool: TranscriptTool
    let open: Bool
    let toggle: () -> Void

    private var label: ToolLabel { ToolLabel(tool) }
    private var body_: String? { tool.output.flatMap { $0.isEmpty ? nil : $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    glyph.frame(width: 14)
                    Text(label.verb).font(.callout).foregroundStyle(.secondary)
                    if let target = label.target {
                        Text(target).font(label.mono ? .system(.callout, design: .monospaced) : .callout).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if let duration = tool.duration, let text = SessionFormat.duration(duration) {
                        Text(text).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    if body_ != nil {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(body_ == nil)
            .accessibilityLabel(label.accessibilityText)
            .accessibilityValue(state)
            if open, let text = body_ {
                ScrollView {
                    Text(text).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 260)
                .background(Ink.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.leading, 21)
                if tool.outputTruncated { Text("The rest was left out.").font(.caption).foregroundStyle(.tertiary).padding(.leading, 21) }
            }
        }
    }

    private var state: String {
        switch tool.status {
        case .running: "Running"
        case .failed: "Failed"
        case .denied: "Denied"
        default: "Done"
        }
    }

    @ViewBuilder private var glyph: some View {
        switch tool.status {
        case .running: WorkingMark()
        case .failed: Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
        case .denied: Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
        default: Image(systemName: tool.name == TranscriptRules.thinkingTool ? "brain" : "checkmark").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// A file the agent wrote whole.
struct WireFile: View {
    let tool: TranscriptTool
    let path: String
    let bytes: Int
    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
            HStack(spacing: 7) {
                Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary).frame(width: 14)
                Text(tool.status == .running ? "Writing" : "Wrote").font(.callout).foregroundStyle(.secondary)
                Text((path as NSString).lastPathComponent).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show in Finder")
        .disabled(!FileManager.default.fileExists(atPath: path))
    }
}

/// An edit as the lines it took out and put in. Long ones show their start, as the phone's do.
struct WireDiff: View {
    let diff: FileDiff
    let whole: Bool
    let toggle: () -> Void

    static let preview = 40

    private var lines: [String] { diff.hunks.flatMap(\.lines) }

    var body: some View {
        let all = lines
        let shown = whole ? all : Array(all.prefix(Self.preview))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text((diff.path as NSString).lastPathComponent).font(.system(.callout, design: .monospaced).weight(.medium)).lineLimit(1).truncationMode(.middle)
                if diff.additions > 0 { Text("+\(diff.additions)").font(.caption.monospacedDigit()).foregroundStyle(.green) }
                if diff.deletions > 0 { Text("−\(diff.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.red) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .help(diff.path)
            Rectangle().fill(Ink.line).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("\\") ? .tertiary : .primary)
                            .padding(.horizontal, 10).padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.hasPrefix("+") ? Color.green.opacity(0.14) : line.hasPrefix("-") ? Color.red.opacity(0.14) : .clear)
                    }
                }
                .padding(.vertical, 4)
            }
            if all.count > Self.preview || diff.truncated {
                Rectangle().fill(Ink.line).frame(height: 1)
                HStack {
                    if all.count > Self.preview {
                        Button(whole ? "Show Less" : "Show All \(all.count.formatted()) Lines", action: toggle).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                    if diff.truncated { Text("A very long change: the rest was left out.").foregroundStyle(.tertiary) }
                }
                .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .background(Ink.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes to \((diff.path as NSString).lastPathComponent), \(diff.additions) added, \(diff.deletions) removed")
    }
}
