import SideACore
import SideAProtocol
import SideASessionKit
import SwiftUI

/// ⌘K: go to a session by typing part of what is known about it, or (after ">") do something to the open one.
enum Switcher {
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable { case needsYou, ready, working, idle, past, action, search }
        let id: String
        let kind: Kind
        let title: String
        var detail = ""
        /// What matching looks in, beside the title.
        var fields: [String?] = []
    }

    static let recentShown = 8
    static let most = 40

    /// Empty: what needs you, then what is ready, then recent ones, so ⌘K ↩ is "take me to the next thing". Typed:
    /// every session matching, running ones first, then a way into full-text search.
    static func entries(_ query: String, running: [Entry], past: [Entry], actions: [Entry]) -> [Entry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        if query.hasPrefix(">") {
            let wanted = String(query.dropFirst())
            return actions.filter { SessionSearch.matches(wanted, fields: [$0.title]) }
        }
        let rank: [Entry.Kind] = [.needsYou, .ready, .working, .idle]
        let ordered = running.enumerated().sorted { a, b in
            let (x, y) = (rank.firstIndex(of: a.element.kind) ?? rank.count, rank.firstIndex(of: b.element.kind) ?? rank.count)
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
        let taken = Set(ordered.map(\.id))
        let rest = past.filter { !taken.contains($0.id) }
        guard !query.isEmpty else { return Array((ordered + rest.prefix(recentShown)).prefix(most)) }
        let found = (ordered + rest).filter { SessionSearch.matches(query, fields: [$0.title] + $0.fields) }
        return Array(found.prefix(most)) + [Entry(id: "search", kind: .search, title: "Search conversations for “\(query)”")]
    }

    static func next(_ index: Int, by delta: Int, count: Int) -> Int {
        count == 0 ? 0 : (index + delta + count) % count
    }
}

extension SessionStore {
    var switcherRunning: [Switcher.Entry] {
        let listed = self.listed
        func entry(_ live: LiveSession, _ kind: Switcher.Entry.Kind) -> Switcher.Entry? {
            guard let id = live.sessionID else { return nil }
            let account = accountID(of: live, agent: live.provider).flatMap { id in store.config.accounts.first { $0.id == id }?.name }
            let project = project(of: live.cwd)
            return Switcher.Entry(id: id, kind: kind, title: names[id] ?? live.title ?? live.name ?? "Session",
                                  detail: [project, live.provider == .codex ? "Codex" : "Claude"].joined(separator: "  ·  "),
                                  fields: [project, live.cwd, account, live.provider.rawValue])
        }
        let finished = listed.finished.compactMap { item -> Switcher.Entry? in
            guard let id = item.finish.sessionID else { return nil }
            return Switcher.Entry(id: id, kind: .ready, title: names[id] ?? item.title, detail: item.finish.summary)
        }
        return listed.waiting.compactMap { entry($0, .needsYou) } + finished + listed.working.compactMap { entry($0, .working) }
            + listed.idle.compactMap { entry($0, .idle) }
    }

    /// Conversations that have ended, newest first.
    var switcherPast: [Switcher.Entry] {
        groups.flatMap(\.rows).map(\.session).sorted { ($0.lastTs ?? 0) > ($1.lastTs ?? 0) }.map { session in
            Switcher.Entry(id: session.id, kind: .past, title: session.name,
                           detail: [session.project, When.compact(session.lastTs)].filter { !$0.isEmpty }.joined(separator: "  ·  "),
                           fields: [session.project, session.branch, session.model, session.agent])
        }
    }

    func switcherChoose(_ entry: Switcher.Entry, query: String) {
        desk.switching = false
        switch entry.kind {
        case .search:
            self.query = query.trimmingCharacters(in: .whitespaces)
            queryChanged()
            focusSearch += 1
        case .action: actions.first { $0.id == entry.id }?.run()
        default: go(entry.id)
        }
    }
}

struct SwitcherPanel: View {
    let model: SessionStore
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var entries: [Switcher.Entry] {
        Switcher.entries(query, running: model.switcherRunning, past: model.switcherPast,
                         actions: model.actions.map { Switcher.Entry(id: $0.id, kind: .action, title: $0.title, detail: $0.key) })
    }

    var body: some View {
        let entries = self.entries
        let at = min(index, max(entries.count - 1, 0))
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to a session, or > for actions", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { if entries.indices.contains(at) { model.switcherChoose(entries[at], query: query) } }
                    .onKeyPress(.downArrow) { index = Switcher.next(at, by: 1, count: entries.count); return .handled }
                    .onKeyPress(.upArrow) { index = Switcher.next(at, by: -1, count: entries.count); return .handled }
                    .onExitCommand { model.desk.switching = false }
            }
            .padding(.horizontal, 14).frame(height: 44)
            if !entries.isEmpty {
                Rectangle().fill(Ink.line).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                                Button { model.switcherChoose(entry, query: query) } label: { SwitcherRow(entry: entry, selected: offset == at) }
                                    .buttonStyle(.plain).id(entry.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: at) { if entries.indices.contains(at) { proxy.scrollTo(entries[at].id) } }
                }
            }
        }
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.line))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Go to a session")
    }
}

struct SwitcherRow: View {
    let entry: Switcher.Entry
    let selected: Bool
    var body: some View {
        HStack(spacing: 9) {
            mark.frame(width: 14)
            Text(entry.title).font(.body).lineLimit(1).foregroundStyle(selected ? Color.white : .primary)
            Spacer(minLength: 8)
            Text(entry.detail).font(.subheadline).lineLimit(1).foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
        }
        .padding(.horizontal, 9).frame(height: 30)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var mark: some View {
        switch entry.kind {
        case .needsYou: Circle().fill(Ink.amber).frame(width: 7, height: 7).accessibilityLabel("Needs you")
        case .ready: Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(selected ? .white : .green).accessibilityLabel("Ready")
        case .working: Image(systemName: "circle.dotted").font(.system(size: 10)).foregroundStyle(selected ? .white : .secondary).accessibilityLabel("Working")
        case .idle: Circle().fill(Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
        case .past: Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(selected ? Color.white : Color.secondary.opacity(0.7))
        case .action: Image(systemName: "command").font(.system(size: 10)).foregroundStyle(selected ? .white : .secondary)
        case .search: Image(systemName: "text.magnifyingglass").font(.system(size: 10)).foregroundStyle(selected ? .white : .secondary)
        }
    }
}

/// Something the open session can have done to it, for ⌘K's ">" list. The Session menu offers the same.
struct SessionAction: Identifiable {
    let id: String
    let title: String
    var key = ""
    let run: @MainActor () -> Void
}

extension SessionStore {
    var actions: [SessionAction] {
        var list = [SessionAction(id: "new", title: "New Session", key: "⌘N") { [self] in creating = true }]
        if let live = openLive {
            if live.status == "busy" { list.append(SessionAction(id: "stop", title: "Stop", key: "⌘.") { [self] in stop(live, now: true) }) }
            if snooze(of: live) != nil {
                list.append(SessionAction(id: "wake", title: "Wake") { [self] in wake(live) })
            } else {
                list += SessionSnooze.Choice.offered.map { choice in
                    SessionAction(id: "snooze-\(choice.rawValue)", title: "Snooze: \(choice.title)") { [self] in snooze(live, choice) }
                }
            }
            if store.hostingWanted, store.hosted.available, live.cwd != nil {
                list.append(SessionAction(id: "restart", title: "Restart Fresh…") { [self] in restarting = live })
            }
            list.append(SessionAction(id: "quit", title: "Quit Session") { [self] in requestQuit(live) })
        }
        list += projectActions.map { action in
            SessionAction(id: "run-\(action.name)", title: "Run: \(action.name)", key: action.command) { [self] in run(action) }
        }
        if let open = openSession {
            list.append(SessionAction(id: "show", title: openLive == nil ? "Resume" : "Show in Terminal", key: "⌘T") { [self] in showOrResume(open) })
            list.append(SessionAction(id: "pin", title: isPinned(open.id) ? "Unpin" : "Pin", key: "⌥⌘P") { [self] in pin(open.id) })
            list.append(SessionAction(id: "rename", title: "Rename…", key: "⌥⌘R") { [self] in renaming = open })
            if openLive == nil {
                list.append(SessionAction(id: "archive", title: isArchived(open.id) ? "Unarchive" : "Archive", key: "⇧⌘A") { [self] in archive(open.id) })
            }
            list.append(SessionAction(id: "copy", title: "Copy Session ID") { SessionStore.copy(open.id) })
            list.append(SessionAction(id: "find", title: "Find in Conversation", key: "⌘F") { [self] in finding = true })
        }
        list.append(SessionAction(id: "sidebar", title: desk.sidebarHidden ? "Show Sidebar" : "Hide Sidebar", key: "⌘0") { [self] in desk.sidebarHidden.toggle() })
        return list
    }
}
