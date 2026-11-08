import AppKit
import SideACore
import SwiftUI

struct SessionViewer: View {
    @Bindable var model: SessionStore
    @AppStorage(SessionStore.resumeTerminalKey) private var terminal = ""
    @State private var showInherited = false
    @State private var flash: String?
    @State private var showDetails = false
    @State private var findText = ""
    @State private var matches: [Int] = []
    @State private var matchIndex = 0
    var body: some View {
        ZStack {
            if let detail = model.detail, detail.session.id == model.selectedID || model.loading {
                VStack(spacing: 0) {
                    header(detail)
                    Rectangle().fill(Ink.line).frame(height: 1)
                    conversation(detail)
                    SessionActions(model: model, sessionID: detail.session.id)
                }
                .id(detail.session.id)
                .opacity(detail.session.id == model.selectedID ? 1 : 0.55)
                .transition(.asymmetric(insertion: Ink.rise(8), removal: .opacity))
            } else if model.loading {
                ProgressView().controlSize(.small)
            } else if let error = model.error {
                ContentUnavailableView("Can't Open This Conversation", systemImage: "exclamationmark.bubble", description: Text(error))
            } else {
                Welcome()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if model.detail != nil, let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Ink.line))
                    .padding(16)
                    .onTapGesture { model.error = nil }
                    .transition(Ink.reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Ink.ease, value: model.error)
        .onChange(of: model.selectedID) {
            model.finding = false
            findText = ""
            matches = []
            showInherited = false
        }
    }

    private func header(_ detail: SessionDetail) -> some View {
        let session = detail.session
        let app = TerminalApp(rawValue: terminal) ?? model.usualTerminal
        // Resuming a session that is still running would put two agents on one conversation.
        let live = model.liveByID[session.id] ?? model.live.first { $0.sessionID == session.id }
        let running = live != nil
        // Running somewhere Side A can't bring forward (tmux, a closed window, a background job).
        let host = live.flatMap(model.hostName)
        let stale = session.id != model.selectedID
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    Button { showDetails.toggle() } label: {
                        Text(meta(session)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Details")
                    .popover(isPresented: $showDetails, arrowEdge: .bottom) { DetailsCard(session: session) }
                }
                Spacer(minLength: 12)
                Button { model.togglePin(session.id) } label: {
                    Image(systemName: model.isPinned(session.id) ? "pin.fill" : "pin").font(.callout)
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(model.isPinned(session.id) ? Color.orange : .secondary)
                }
                .buttonStyle(.plain)
                .modifier(HoverPlate())
                .help(model.isPinned(session.id) ? "Unpin" : "Pin to the top of the list")
                Menu {
                    // What the phone's menu offers after its settings: each only where the session takes it.
                    if let live {
                        let abilities = WireBuilders.session(live, store: model.store, finished: []).abilities
                        if abilities.contains(.review) {
                            Button { model.review(live) } label: { Label("Review Changes", systemImage: "text.magnifyingglass") }
                        }
                        if abilities.contains(.compact) {
                            Button { model.compact(live) } label: { Label("Compact", systemImage: "arrow.down.right.and.arrow.up.left") }
                        }
                        if !abilities.isDisjoint(with: [.review, .compact]) { Divider() }
                    }
                    if !session.isCodex {
                        Button { model.resume(session, fork: true, in: app) } label: { Label("Branch into a New Session", systemImage: "arrow.triangle.branch") }
                    }
                    Button { model.renaming = session } label: { Label("Rename…", systemImage: "pencil") }
                    Button { model.toggleArchive(session.id) } label: {
                        Label(model.isArchived(session.id) ? "Unarchive" : "Archive", systemImage: "archivebox")
                    }
                    Divider()
                    Button { SessionStore.copy(SessionStore.command(session, fork: false)) } label: { Label("Copy Resume Command", systemImage: "doc.on.doc") }
                    if let pr = session.prUrl, let url = URL(string: pr) {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Open Pull Request", systemImage: "arrow.up.forward.square") }
                    }
                    Divider()
                    Picker("Resume In", selection: $terminal) {
                        Text("Automatic (\(model.usualTerminal.title))").tag("")
                        ForEach(TerminalApp.allCases.filter(\.installed)) { Text($0.title).tag($0.rawValue) }
                    }
                } label: { Image(systemName: "ellipsis").font(.body) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .modifier(HoverPlate())
                Button {
                    if let live, host != nil { model.show(live) } else { model.resume(session, fork: running, in: app) }
                } label: {
                    Label(host.map { "Show in \($0)" } ?? (running ? "Branch" : "Resume"),
                          systemImage: host != nil ? "macwindow" : running ? "arrow.triangle.branch" : "arrow.uturn.forward")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12).frame(height: 28)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(Press())
                .keyboardShortcut(.return, modifiers: .command)
                .help(host != nil ? "Go to the tab it's running in (⌘↩)"
                      : running ? "It's running where Side A can't reach it (tmux or a background job), so this starts a copy in \(app.title) (⌘↩)"
                      : "Continue it in \(app.title) with \(session.isCodex ? "codex resume" : "claude --resume") (⌘↩)")
            }
            .disabled(stale)
            if let live {
                HStack(spacing: 6) {
                    SettingsChip(model: model, live: live)
                    ChangesChip(model: model, live: live)
                }
            }
            if detail.parent != nil || !detail.forks.isEmpty { Lineage(model: model, detail: detail) }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
    }

    private func meta(_ session: SessionInfo) -> String {
        var parts: [String?] = [session.project.isEmpty ? nil : session.project]
        if let branch = session.branch, !["HEAD", "main", "master"].contains(branch) { parts.append(branch) }
        // The account a running session uses, as the phone shows it.
        if let live = model.liveByID[session.id], let id = model.accountID(of: live, agent: live.provider) {
            parts.append(model.store.config.accounts.first { $0.id == id }?.name)
        }
        parts.append(session.lastTs.map { Date(timeIntervalSince1970: $0).formatted(.relative(presentation: .named)) })
        if let cost = session.cost, cost >= 0.01 { parts.append(cost.formatted(.currency(code: "USD"))) }
        return parts.compactMap { $0 }.joined(separator: "  ·  ")
    }

    /// Only while the composer is there to take the words.
    private var resend: ((String) -> Void)? {
        guard let id = model.detail?.session.id, ComposerTarget(id, store: model.store).canReply else { return nil }
        return { text in
            model.drafts[id] = text
            model.outcomes[id] = nil
        }
    }

    private func conversation(_ detail: SessionDetail) -> some View {
        // A fork's copied history can open with a summary, so count up to the last inherited message.
        let inherited = (detail.messages.lastIndex { $0.inherited } ?? -1) + 1
        let forksAt = Dictionary(grouping: detail.forks, by: { $0.forkPoint ?? "" })
        let shown = Array(detail.messages.enumerated()).filter { showInherited || $0.offset >= inherited }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if detail.truncated > 0 {
                        Button { model.loadEarlier() } label: { Divided(text: "Show \(detail.truncated.formatted()) earlier messages") }
                            .buttonStyle(.plain)
                    }
                    if inherited > 0 {
                        InheritedCard(count: inherited + (detail.inheritedBefore ?? 0), open: showInherited) {
                            withAnimation(Ink.ease) { showInherited.toggle() }
                        }
                    }
                    ForEach(shown, id: \.element.key) { index, message in
                        if let gap = dayBreak(detail.messages, index) { Divided(text: gap).padding(.vertical, 6) }
                        if startsTurn(detail.messages, index) { AgentHeader(codex: detail.session.isCodex).padding(.top, 4) }
                        MessageView(message: message, flashing: flash != nil && flash == message.uuid,
                                    highlight: model.finding && matches.contains(index) ? findText : nil, onResend: resend)
                            .id(message.key)
                            .opacity(message.inherited ? 0.6 : 1)
                            .transition(.opacity)
                        if index == inherited - 1 && showInherited { BranchMarker(text: "Branched here") }
                        if let forks = forksAt[message.uuid], !(detail.messages.indices.contains(index + 1) && detail.messages[index + 1].uuid == message.uuid) {
                            ForEach(forks) { fork in
                                BranchMarker(text: "Branched into", name: fork.name) { model.open(fork.id) }
                            }
                        }
                    }
                    if let later = detail.later, later > 0 {
                        Button { model.showLatest() } label: { Divided(text: "Jump to latest · \(later.formatted()) newer") }
                            .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 700)
                .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .topTrailing) {
                if model.finding {
                    FindBar(text: $findText, count: matches.count, index: matchIndex,
                            step: { delta in step(delta, detail, proxy, inherited: inherited) },
                            close: { withAnimation(Ink.glide) { model.finding = false } })
                        .padding(12)
                        .transition(Ink.rise(-6))
                }
            }
            .onChange(of: findText) { search(detail, proxy, inherited: inherited) }
            .onChange(of: detail.messages.count) {
                if model.finding { search(detail, proxy, inherited: inherited) }
                jump(detail, proxy, inherited: inherited)
            }
            .onChange(of: model.finding) {
                if model.finding && detail.truncated > 0 { model.loadEarlier() }
                if model.finding { search(detail, proxy, inherited: inherited) }
            }
            .onAppear { jump(detail, proxy, inherited: inherited) }
            .onChange(of: detail.messages.first?.key) { jump(detail, proxy, inherited: inherited) }
            .onChange(of: model.focus) { jump(detail, proxy, inherited: inherited) }
            .onChange(of: detail.session.id) { showInherited = false; model.finding = false; jump(detail, proxy, inherited: inherited) }
        }
    }

    private func search(_ detail: SessionDetail, _ proxy: ScrollViewProxy, inherited: Int) {
        let term = findText.trimmingCharacters(in: .whitespaces)
        matches = term.isEmpty ? [] : detail.messages.indices.filter { index in
            let message = detail.messages[index]
            return message.text.localizedStandardContains(term) || message.tools.contains { $0.localizedStandardContains(term) }
        }
        matchIndex = max(matches.count - 1, 0)
        reveal(detail, proxy, inherited: inherited)
    }

    private func step(_ delta: Int, _ detail: SessionDetail, _ proxy: ScrollViewProxy, inherited: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        reveal(detail, proxy, inherited: inherited)
    }

    private func reveal(_ detail: SessionDetail, _ proxy: ScrollViewProxy, inherited: Int) {
        guard matches.indices.contains(matchIndex) else { return }
        let index = matches[matchIndex]
        let key = detail.messages[index].key
        if index < inherited && !showInherited {
            showInherited = true
            Task { try? await Task.sleep(for: .milliseconds(60)); proxy.scrollTo(key, anchor: .center) }
        } else {
            proxy.scrollTo(key, anchor: .center)
        }
        withAnimation(Ink.glide) { flash = detail.messages[index].uuid }
    }

    private func startsTurn(_ messages: [SessionMessage], _ index: Int) -> Bool {
        guard ["assistant", "tool", "error"].contains(messages[index].role) else { return false }
        return !messages[..<index].contains { $0.role != "compact" } || messages[..<index].last { $0.role != "compact" }?.role == "user"
    }

    private func dayBreak(_ messages: [SessionMessage], _ index: Int) -> String? {
        guard let ts = messages[index].ts else { return nil }
        let previous = messages[..<index].last { $0.ts != nil }?.ts
        guard previous == nil || ts - previous! > 3600 else { return nil }
        let date = Date(timeIntervalSince1970: ts)
        return Calendar.current.isDateInToday(date) ? "Today, \(date.formatted(date: .omitted, time: .shortened))"
            : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
    }

    private func jump(_ detail: SessionDetail, _ proxy: ScrollViewProxy, inherited: Int) {
        guard let focus = model.focus, detail.session.id == model.selectedID else { return }
        guard let index = detail.messages.lastIndex(where: { $0.uuid == focus }) else {
            // Not in the conversation itself, such as a hit inside a subagent's work.
            if !model.loading { model.focus = nil }
            return
        }
        model.focus = nil
        if index < inherited { showInherited = true }
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            proxy.scrollTo(detail.messages[index].key, anchor: .center)
            withAnimation(Ink.glide) { flash = focus }
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.8)) { if flash == focus { flash = nil } }
        }
    }
}

struct AgentHeader: View {
    let codex: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: codex ? "chevron.left.forwardslash.chevron.right" : "asterisk")
                .font(.system(size: codex ? 8 : 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(codex ? Color.teal : Color(red: 0.85, green: 0.47, blue: 0.34), in: Circle())
            Text(codex ? "Codex" : "Claude").font(.callout.weight(.semibold))
        }
    }
}

struct Welcome: View {
    var body: some View {
        ContentUnavailableView("No Conversation Selected", systemImage: "text.bubble")
    }
}

struct DetailsCard: View {
    let session: SessionInfo
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("Folder", session.cwd?.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            row("Branch", session.branch == "HEAD" ? nil : session.branch)
            row("Model", session.model)
            row("Started", session.firstTs.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) })
            row("Last reply", session.lastTs.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) })
            row("Prompts", session.prompts.map { $0.formatted() })
            row("Tokens", session.tokens.flatMap { $0 > 0 ? TokenCount.short($0) : nil })
            row("Cost", session.cost.map { $0.formatted(.currency(code: "USD")) })
            row("Session", session.id, mono: true)
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder private func row(_ label: String, _ value: String?, mono: Bool = false) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.tertiary)
                Text(value).font(mono ? .subheadline.monospaced() : .callout).lineLimit(2).truncationMode(.middle)
            }
        }
    }
}

struct LinkText: View {
    let text: String
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Text(text).lineLimit(1)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.primary.opacity(0.5)).frame(height: 1).offset(y: 1)
                    .scaleEffect(x: hovering || reduceMotion ? 1 : 0, anchor: .leading)
                    .opacity(hovering ? 1 : 0)
            }
            .onHover { inside in withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.28)) { hovering = inside } }
    }
}

struct Lineage: View {
    let model: SessionStore
    let detail: SessionDetail
    var body: some View {
        HStack(spacing: 16) {
            if let parent = detail.parent {
                Button { model.open(parent.id, at: detail.session.forkPoint) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.left.up").foregroundStyle(Ink.branch)
                        Text("Branched from").foregroundStyle(.secondary)
                        LinkText(text: parent.name)
                    }
                }
                .buttonStyle(.plain)
                .help("Open the conversation this one branched from, at the point it branched")
            }
            if !detail.forks.isEmpty {
                Menu {
                    ForEach(detail.forks) { fork in Button(fork.name) { model.open(fork.id) } }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Ink.branch)
                        Text(detail.forks.count == 1 ? "1 branch" : "\(detail.forks.count) branches")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Spacer()
        }
        .font(.callout)
    }
}

struct InheritedCard: View {
    let count: Int
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch").font(.callout).foregroundStyle(Ink.branch)
                Text("\(count.formatted()) earlier messages from before the branch").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(open ? "Hide" : "Show").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(hovering ? Ink.hover : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(Press())
        .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
    }
}

struct Divided: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Ink.line).frame(height: 1)
            Text(text).font(.subheadline.weight(.medium)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
            Rectangle().fill(Ink.line).frame(height: 1)
        }
    }
}

struct BranchMarker: View {
    let text: String
    var name: String?
    var action: (() -> Void)?
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Ink.branch.opacity(0.22)).frame(height: 1)
            Button { action?() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(Ink.branch)
                    Text(text).foregroundStyle(.secondary)
                    if let name { LinkText(text: name).frame(maxWidth: 260) }
                }
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain).disabled(action == nil).fixedSize(horizontal: true, vertical: false)
            Rectangle().fill(Ink.branch.opacity(0.22)).frame(height: 1)
        }
    }
}

struct MessageView: View {
    let message: SessionMessage
    let flashing: Bool
    var highlight: String?
    /// Edit & Resend: the words go back into the composer as a new message; agents can't rewrite what was said.
    var onResend: ((String) -> Void)?
    @State private var hovering = false
    @State private var more = false
    var body: some View {
        Group {
            switch message.role {
            case "user":
                VStack(alignment: .trailing, spacing: 4) {
                    Text(MessageText.marking(AttributedString(message.text), highlight)).font(.body).lineSpacing(3)
                        .lineLimit(long && !more ? 12 : nil)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .topTrailing) { toolbar }
                        .contextMenu {
                            Button("Copy") { SessionStore.copy(message.text) }
                            if let onResend { Button("Edit & Resend") { onResend(message.text) } }
                        }
                    if long {
                        Button(more ? "Show less" : "Show more") { withAnimation(Ink.ease) { more.toggle() } }
                            .buttonStyle(.plain).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 72)
            case "assistant":
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(message.segments.enumerated()), id: \.offset) { _, segment in
                            if segment.kind == .table {
                                MarkdownTable(rows: segment.rows)
                            } else if segment.kind == .code {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    Text(segment.text).font(.callout.monospaced()).lineSpacing(3).fixedSize()
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Ink.field.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.line))
                            } else {
                                Text(MessageText.marking(segment.text, highlight)).font(.body).lineSpacing(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .overlay(alignment: .topTrailing) { toolbar }
            case "tool":
                ToolGroup(tools: message.tools, revealed: highlight != nil)
            case "compact":
                Divided(text: "Earlier context was summarized")
            case "error":
                Label(message.text, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            default:
                Text(message.text)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(flashing ? 0.1 : 0))
                .padding(-8)
        }
        .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
    }

    private var long: Bool { message.text.count > 900 }

    /// Floats on its own surface over the message's corner, so it never lands on the text around it.
    private var toolbar: some View {
        HStack(spacing: 0) {
            if let ts = message.ts {
                let date = Date(timeIntervalSince1970: ts)
                Text(date, format: .dateTime.hour().minute())
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.leading, 8).padding(.trailing, 2)
                    .help(date.formatted(date: .complete, time: .shortened))
            }
            CopyButton(text: message.text)
            if let onResend, message.role == "user" {
                Button { onResend(message.text) } label: {
                    Image(systemName: "pencil").font(.subheadline).frame(width: 24, height: 22).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Edit & Resend")
                .accessibilityLabel("Edit and resend")
            }
        }
        .padding(2)
        .background(Ink.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.line))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        .offset(x: 6, y: -14)
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
    }
}

enum MessageText {
    static func marking(_ text: AttributedString, _ term: String?) -> AttributedString {
        guard let term = term?.trimmingCharacters(in: .whitespaces), !term.isEmpty else { return text }
        var result = text
        var cursor = result.startIndex
        while cursor < result.endIndex, let range = result[cursor...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].backgroundColor = Color.yellow.opacity(0.45)
            cursor = range.upperBound
        }
        return result
    }

    static func segments(_ text: String) -> [(MessageSegment.Kind, String)] {
        var result: [(MessageSegment.Kind, String)] = []
        var buffer: [String] = []
        var kind = MessageSegment.Kind.prose
        func flush() {
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { result.append((kind, joined)) }
            buffer = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                kind = kind == .code ? .prose : .code
            } else if kind != .code, trimmed.hasPrefix("|") != (kind == .table) {
                flush()
                kind = kind == .table ? .prose : .table
                buffer.append(line)
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result.map { $0.0 == .table && $0.1.components(separatedBy: "\n").count < 2 ? (.prose, $0.1) : $0 }
    }

    static func table(_ text: String) -> [[AttributedString]] {
        text.components(separatedBy: "\n").compactMap { line in
            let cells = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.allSatisfy({ $0.range(of: "^:?-+:?$", options: .regularExpression) != nil }) { return nil }
            return cells.map { markdown($0) }
        }
    }

    /// Inline Markdown only, so lists and headings are turned into plain equivalents first.
    static func markdown(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "^#{1,6} ", options: .regularExpression) { return "**" + trimmed[range.upperBound...] + "**" }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return String(line.prefix { $0 == " " }) + "•  " + trimmed.dropFirst(2)
            }
            return line
        }
        let source = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    }
}

struct MarkdownTable: View {
    let rows: [[AttributedString]]
    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(column < row.count ? row[column] : "")
                                .font(.system(size: 12.5, weight: index == 0 ? .semibold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(maxWidth: 320, alignment: .leading)
                        }
                    }
                    .background(index == 0 ? Ink.field : .clear)
                    if index < rows.count - 1 { Rectangle().fill(Ink.line).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.line))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FindBar: View {
    @Binding var text: String
    let count: Int
    let index: Int
    let step: (Int) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.subheadline.weight(.medium)).foregroundStyle(.tertiary)
            TextField("Find in conversation", text: $text)
                .textFieldStyle(.plain).font(.callout)
                .focused($focused)
                .onKeyPress(keys: [.return]) { press in step(press.modifiers.contains(.shift) ? 1 : -1); return .handled }
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .onExitCommand(perform: close)
            if !text.isEmpty {
                Text(count == 0 ? "No matches" : "\(index + 1) of \(count)")
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).modifier(HoverPlate(size: 22, radius: 6)).disabled(count == 0)
            Button { step(1) } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).modifier(HoverPlate(size: 22, radius: 6)).disabled(count == 0)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).modifier(HoverPlate(size: 22, radius: 6))
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 10).padding(.trailing, 4).frame(width: 340, height: 34)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .onAppear { focused = true }
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            SessionStore.copy(text)
            withAnimation(Ink.glide) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(Ink.glide) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "square.on.square").font(.subheadline.weight(.medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(copied ? Color.green : .secondary)
        }
        .buttonStyle(.plain)
        .modifier(HoverPlate(size: 22, radius: 6))
        .help("Copy")
    }
}

struct ToolGroup: View {
    let tools: [String]
    var revealed = false
    @State private var open = false
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { withAnimation(Ink.ease) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                    Text(ToolSteps.summary(tools)).monospacedDigit()
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 6).frame(height: 24)
                .background(hovering ? Ink.hover2 : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, -6)
            .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
            if open || revealed {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in ToolRow(tool: tool, index: index) }
                }
                .transition(.opacity)
            }
        }
    }
}

struct ToolRow: View {
    let tool: String
    let index: Int
    @State private var open = false
    @State private var hovering = false
    @State private var shown = false
    var body: some View {
        let step = ToolSteps.step(tool)
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Ink.ease) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Image(systemName: step.icon).opacity(hovering || open ? 0 : 1)
                        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(open ? 0 : -90)).opacity(hovering || open ? 1 : 0)
                    }
                    .font(.subheadline).foregroundStyle(.tertiary).frame(width: 16)
                    Text(step.verb).font(.callout.weight(.medium)).fixedSize()
                    if !step.target.isEmpty {
                        Text(step.target).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 6).frame(height: 22)
                            .background(Ink.hover2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ink.line))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 3).frame(height: 28)
                .background(hovering ? Ink.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
            if open {
                Text(ToolSteps.detail(tool)).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                    .lineSpacing(3).lineLimit(30)
                    .padding(.leading, 14).padding(.vertical, 3)
                    .overlay(alignment: .leading) { Rectangle().fill(Ink.line).frame(width: 1) }
                    .padding(.leading, 11).padding(.bottom, 6)
                    .transition(Ink.rise(-4))
            }
        }
        .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 6)
        .onAppear { withAnimation(Ink.ease.delay(Double(min(index, 10)) * 0.035)) { shown = true } }
    }
}

enum ToolSteps {
    static func kind(_ line: String) -> String {
        let name = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? line
        switch name {
        case "Bash", "shell", "exec", "exec_command", "BashOutput": return "ran"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": return "edited"
        case "Read": return "read"
        case "Grep", "Glob", "LS": return "searched"
        case "WebFetch", "WebSearch": return "looked up"
        case "Task", "Agent": return "delegated"
        default: return "used"
        }
    }

    static func summary(_ tools: [String]) -> String {
        var counts: [(String, Int)] = []
        for tool in tools {
            let kind = kind(tool)
            if let index = counts.firstIndex(where: { $0.0 == kind }) { counts[index].1 += 1 } else { counts.append((kind, 1)) }
        }
        let words: [String: (String, String)] = ["ran": ("command", "commands"), "edited": ("file", "files"), "read": ("file", "files"),
                                                 "searched": ("time", "times"), "looked up": ("page", "pages"),
                                                 "delegated": ("task", "tasks"), "used": ("tool", "tools")]
        let text = counts.map { kind, count in
            let (one, many) = words[kind]!
            return kind == "searched" ? (count == 1 ? "searched the code" : "searched \(count) times") : "\(kind) \(count) \(count == 1 ? one : many)"
        }.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func step(_ line: String) -> (icon: String, verb: String, target: String) {
        let value = detail(line)
        let kind = kind(line)
        let file = URL(fileURLWithPath: value).lastPathComponent
        switch kind {
        case "ran": return ("terminal", "Ran", value.split(separator: "\n").first.map(String.init) ?? value)
        case "edited": return ("pencil", "Edited", file)
        case "read": return ("doc.text", "Read", file)
        case "searched": return ("magnifyingglass", "Searched", value)
        case "looked up": return ("globe", "Looked up", value)
        case "delegated": return ("person.2", "Delegated", value)
        default:
            let name = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? line
            return ("wrench.and.screwdriver", name.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " · "), value == line ? "" : value)
        }
    }

    static func detail(_ line: String) -> String {
        let parts = line.split(separator: ":", maxSplits: 1)
        let value = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : line
        return value.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
