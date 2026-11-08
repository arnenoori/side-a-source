import SideAProtocol
import SwiftUI

/// The Search tab is History (sections 4.11, 4.14). Before typing: Pinned, then Recent by project with
/// forks under their parents, then Show Archived. Typing searches the Mac's index of asks, replies and
/// commands. Everything pages by the Mac's cursors. With several Macs shown, typing searches every one and
/// each Mac's results sit under its name; before typing, each Mac shows its pinned and latest conversations.
struct HistoryView: View {
    @Environment(AppRoot.self) private var root
    /// Owned by the Search tab's stack, which carries the field.
    let query: String
    @State private var lists: [String: HistoryList] = [:]
    @State private var searches: [String: HistorySearch] = [:]

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var macs: [AppModel] { root.visible }

    var body: some View {
        Group {
            if macs.count > 1 {
                if trimmed.isEmpty {
                    EveryMacBrowse(macs: macs, lists: lists)
                } else {
                    EveryMacResults(macs: macs, lists: lists, searches: searches, query: trimmed)
                }
            } else if let mac = macs.first {
                OneMacHistory(list: lists[mac.macID], search: searches[mac.macID], query: trimmed)
                    .environment(mac)
            }
        }
        .navigationTitle("History")
        .historyDestinations()
        .sessionActions()
        .task(id: macs.map { "\($0.macID):\($0.tools.can(.history))" }) {
            for mac in macs where lists[mac.macID] == nil {
                let demo = mac.isDemo ? mac.history : nil
                lists[mac.macID] = HistoryList(tools: mac.tools, archived: false, demo: demo?.past)
                searches[mac.macID] = HistorySearch(tools: mac.tools, demo: demo)
            }
            await withTaskGroup { group in
                for mac in macs where mac.tools.can(.history) && lists[mac.macID]?.loaded == false {
                    let list = lists[mac.macID]
                    group.addTask { await list?.refresh() }
                }
            }
        }
        .task(id: [trimmed] + macs.map(\.macID)) {
            // Searches once typing pauses; the next keystroke cancels this one. Every Mac at once.
            if !trimmed.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            let text = trimmed
            await withTaskGroup { group in
                for mac in macs {
                    let search = searches[mac.macID]
                    group.addTask { await search?.search(text) }
                }
            }
        }
    }
}

/// One Mac's History: the browse, or its results.
private struct OneMacHistory: View {
    let list: HistoryList?
    let search: HistorySearch?
    let query: String
    @Environment(AppModel.self) private var model

    var body: some View {
        // Capabilities arrive with the Mac's hello; until then there's nothing to say.
        if model.mac.state == .live && !model.tools.can(.history) && !model.tools.can(.search) {
            ContentUnavailableView("No History", systemImage: "clock",
                                   description: Text("\(model.mac.name) doesn't share its history."))
        } else if !query.isEmpty, let search {
            HistoryResults(search: search, list: list, query: query)
        } else if let list {
            HistoryBrowse(list: list)
        }
    }
}

/// Pushes from History: a past transcript, the archive, or one Mac's whole History, each on its Mac.
enum HistoryRoute: Hashable {
    /// With the uuid of the message a search matched.
    case past(PastSession, match: String?, mac: String)
    case archive(mac: String)
    case mac(String)

    var mac: String {
        switch self {
        case .past(_, _, let mac), .archive(let mac), .mac(let mac): mac
        }
    }
}

private struct HistoryDestinations: ViewModifier {
    @Environment(AppRoot.self) private var root
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.navigationDestination(for: HistoryRoute.self) { route in
            Group {
                switch route {
                case .past(let past, let match, _): PastSessionView(past: past, match: match)
                case .archive: ArchiveView()
                case .mac: MacHistoryPage()
                }
            }
            .environment(root.model(for: route.mac) ?? model)
        }
    }
}

extension View {
    fileprivate func historyDestinations() -> some View { modifier(HistoryDestinations()) }
}

extension HistoryList {
    /// What a pin, archive or rename changes in a list: rows keyed by id slide between sections.
    fileprivate var layout: [String] { sessions.map { "\($0.id)|\($0.isPinned)|\($0.title)" } }
}

// MARK: Every Mac

/// A Mac's name over its part of History, as in Sessions.
private struct MacHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            ConnectionDot(state: model.mac.state)
            Text(model.mac.name)
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Before typing, with several Macs: each Mac's pinned conversations and latest five, then all of its History.
private struct EveryMacBrowse: View {
    let macs: [AppModel]
    let lists: [String: HistoryList]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List {
            ForEach(macs, id: \.macID) { mac in
                if let list = lists[mac.macID] { MacRecent(list: list).environment(mac) }
            }
        }
        .listStyle(.insetGrouped)
        .animation(Motion.smooth(reduceMotion), value: macs.map { lists[$0.macID]?.layout ?? [] })
        .refreshable {
            await withTaskGroup { group in
                for list in lists.values { group.addTask { await list.refresh() } }
            }
        }
    }
}

private struct MacRecent: View {
    let list: HistoryList
    @Environment(AppModel.self) private var model

    static let latest = 5

    var body: some View {
        let pinned = list.sessions.filter(\.isPinned)
        let latest = list.sessions.filter { !$0.isPinned }.prefix(Self.latest)
        Section {
            ForEach(pinned + latest) { HistoryRow(past: $0, list: list) }
            if !list.loaded && list.loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if list.sessions.isEmpty {
                Text(list.error ?? "No past sessions").foregroundStyle(.secondary)
            } else {
                NavigationLink(value: HistoryRoute.mac(model.macID)) { Text("All History") }
            }
        } header: {
            MacHeader()
        }
        .headerProminence(.increased)
    }
}

/// One Mac's whole History, pushed from its part of the list.
private struct MacHistoryPage: View {
    @Environment(AppModel.self) private var model
    @State private var list: HistoryList?

    var body: some View {
        Group {
            if let list { HistoryBrowse(list: list) }
        }
        .navigationTitle(model.mac.name)
        .sessionActions()
        .task {
            guard list == nil else { return }
            list = HistoryList(tools: model.tools, archived: false, demo: model.isDemo ? model.history.past : nil)
            await list?.refresh()
        }
    }
}

/// Typing, with several Macs: each Mac's results under its name, paging on their own.
private struct EveryMacResults: View {
    let macs: [AppModel]
    let lists: [String: HistoryList]
    let searches: [String: HistorySearch]
    let query: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var done: Bool { macs.allSatisfy { searches[$0.macID]?.query == query || isOffline($0) } }
    private var empty: Bool { macs.allSatisfy { searches[$0.macID]?.results.isEmpty != false } }

    private func isOffline(_ mac: AppModel) -> Bool {
        if case .offline = mac.mac.state { return !mac.isDemo }
        return false
    }

    var body: some View {
        List {
            ForEach(macs, id: \.macID) { mac in
                if let search = searches[mac.macID] {
                    MacResults(search: search, list: lists[mac.macID], query: query, offline: isOffline(mac)).environment(mac)
                }
            }
        }
        .listStyle(.insetGrouped)
        // Each Mac's section settles in as that Mac answers; no haptic per keystroke or result.
        .animation(Motion.smooth(reduceMotion), value: macs.map { searches[$0.macID]?.results.map(\.id) ?? [] })
        .overlay {
            Group {
                if empty && done && !macs.allSatisfy(isOffline) {
                    ContentUnavailableView.search(text: query)
                } else if empty && !done {
                    ProgressView()
                }
            }
            .animation(Motion.smooth(reduceMotion), value: empty && done)
        }
    }
}

private struct MacResults: View {
    let search: HistorySearch
    let list: HistoryList?
    let query: String
    let offline: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        // A Mac with nothing to say about this query stays out of the way.
        if !search.results.isEmpty || offline || search.error != nil {
            Section {
                ForEach(search.results) { past in
                    HistoryRow(past: past, list: list, search: search, query: query)
                        .onAppear { if past.id == search.results.last?.id { Task { await search.loadMore() } } }
                }
                if search.next != nil {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                if offline {
                    Text("Search needs a connection to \(model.mac.name).").foregroundStyle(.secondary)
                } else if let error = search.error, search.results.isEmpty {
                    Text(error).foregroundStyle(.secondary)
                }
            } header: {
                MacHeader()
            }
            .headerProminence(.increased)
        }
    }
}

// MARK: Browse

private struct HistoryBrowse: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let list: HistoryList

    var body: some View {
        let pinned = list.sessions.filter(\.isPinned)
        let recent = HistoryTree.byProject(list.sessions.filter { !$0.isPinned })
        List {
            if let error = list.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.secondary) }
            }
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { HistoryRow(past: $0, list: list) }
                }
            }
            ForEach(recent, id: \.project) { group in
                Section(group.project) {
                    ForEach(group.rows, id: \.session.id) { row in
                        HistoryRow(past: row.session, list: list, depth: row.depth)
                            .onAppear { if row.session.id == list.sessions.last?.id { Task { await list.loadMore() } } }
                    }
                }
            }
            if list.next != nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    .task(id: list.sessions.count) { await list.loadMore() }
            }
            if list.loaded {
                Section {
                    NavigationLink(value: HistoryRoute.archive(mac: model.macID)) { Label("Show Archived", systemImage: "archivebox") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(Motion.smooth(reduceMotion), value: list.layout)
        .refreshable { await list.refresh() }
        .overlay {
            if list.loaded && list.sessions.isEmpty && list.error == nil {
                ContentUnavailableView("No Past Sessions", systemImage: "clock",
                                       description: Text("Conversations on \(model.mac.name) show here once they end."))
            } else if !list.loaded && list.loading {
                ProgressView()
            }
        }
    }
}

/// History's forks sit under the conversation they came from; each project is a section, newest first.
enum HistoryTree {
    struct Row { let session: PastSession; let depth: Int }
    struct Group { let project: String; let rows: [Row] }

    static func byProject(_ sessions: [PastSession]) -> [Group] {
        let ids = Set(sessions.map(\.id))
        var children: [String: [PastSession]] = [:]
        var roots: [PastSession] = []
        for session in sessions {
            if let parent = session.parentID, ids.contains(parent), parent != session.id {
                children[parent, default: []].append(session)
            } else {
                roots.append(session)
            }
        }
        var groups: [(project: String, newest: Double, rows: [Row])] = []
        for root in roots {
            var rows: [Row] = []
            var seen: Set<String> = []
            func walk(_ session: PastSession, _ depth: Int) {
                guard seen.insert(session.id).inserted else { return }
                rows.append(Row(session: session, depth: depth))
                for child in children[session.id] ?? [] { walk(child, depth + 1) }
            }
            walk(root, 0)
            if let index = groups.firstIndex(where: { $0.project == root.project }) {
                groups[index].rows += rows
            } else {
                groups.append((root.project, root.lastAt ?? 0, rows))
            }
        }
        return groups.map { Group(project: $0.project, rows: $0.rows) }
    }
}

// MARK: Search

private struct HistoryResults: View {
    @Environment(AppModel.self) private var model
    let search: HistorySearch
    let list: HistoryList?
    let query: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var offline: Bool {
        if case .offline = model.mac.state { return !model.isDemo }
        return false
    }

    var body: some View {
        List {
            ForEach(search.results) { past in
                HistoryRow(past: past, list: list, search: search, query: query)
                    .onAppear { if past.id == search.results.last?.id { Task { await search.loadMore() } } }
            }
            if search.next != nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .animation(Motion.smooth(reduceMotion), value: search.results.map(\.id))
        .overlay {
            if offline {
                ContentUnavailableView("Can't Search", systemImage: "wifi.slash",
                                       description: Text("Search needs a connection to \(model.mac.name)."))
            } else if let error = search.error, search.results.isEmpty {
                ContentUnavailableView("Can't Search", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if search.query == query && search.results.isEmpty && !search.searching {
                ContentUnavailableView.search(text: query)
            } else if search.results.isEmpty {
                ProgressView()
            }
        }
        .animation(Motion.smooth(reduceMotion), value: search.query == query && !search.searching)
    }
}

// MARK: Archive

private struct ArchiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var list: HistoryList?

    var body: some View {
        Group {
            if let list {
                List {
                    ForEach(list.sessions) { past in
                        HistoryRow(past: past, list: list)
                            .onAppear { if past.id == list.sessions.last?.id { Task { await list.loadMore() } } }
                    }
                }
                .listStyle(.insetGrouped)
                .animation(Motion.smooth(reduceMotion), value: list.layout)
                .refreshable { await list.refresh() }
                .overlay {
                    if list.loaded && list.sessions.isEmpty {
                        ContentUnavailableView("Nothing Archived", systemImage: "archivebox")
                    } else if let error = list.error, list.sessions.isEmpty {
                        ContentUnavailableView("Can't Load", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else if !list.loaded {
                        ProgressView()
                    }
                }
            }
        }
        .navigationTitle("Archived")
        .sessionActions()
        .task {
            guard list == nil else { return }
            list = HistoryList(tools: model.tools, archived: true, demo: model.isDemo ? model.history.past : nil)
            await list?.refresh()
        }
    }
}

// MARK: Row

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions
    @Environment(\.dynamicTypeSize) private var typeSize
    let past: PastSession
    let list: HistoryList?
    var search: HistorySearch?
    var query = ""
    var depth = 0
    @State private var renaming = false
    @State private var title = ""
    @State private var failure: String?
    @State private var renamed = 0
    @State private var failed = 0

    private var large: Bool { typeSize.isAccessibilitySize }

    /// The live session running this conversation, if one is: tapping opens that instead.
    private var live: RemoteSession? {
        model.sessions.sessions.first { $0.conversationID == past.id || $0.id == past.id }
    }

    var body: some View {
        Group {
            if let live {
                NavigationLink(value: Route.session(live.id, mac: model.macID)) { label }
            } else {
                NavigationLink(value: HistoryRoute.past(past, match: query.isEmpty ? nil : past.snippetUUID, mac: model.macID)) { label }
            }
        }
        .swipeActions(edge: .leading) {
            if model.tools.can(.history) || model.isDemo {
                Button(past.isPinned ? "Unpin" : "Pin", systemImage: past.isPinned ? "pin.slash" : "pin") {
                    change(HistoryChange(pinned: !past.isPinned))
                }
                .tint(.yellow)
            }
        }
        .swipeActions(edge: .trailing) {
            if model.tools.can(.history) || model.isDemo {
                Button(past.isArchived ? "Unarchive" : "Archive", systemImage: past.isArchived ? "tray.and.arrow.up" : "archivebox") {
                    change(HistoryChange(archived: !past.isArchived))
                }
                .tint(.gray)
            }
        }
        .contextMenu { menu }
        // Pin and archive come from a swipe or a context menu, which play their own; only a rename,
        // confirmed by the Mac after the alert, gets .success. A refusal gets .error with its alert.
        .sensoryFeedback(.success, trigger: renamed)
        .sensoryFeedback(.error, trigger: failed)
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $title)
            Button("Rename") { change(HistoryChange(title: title.trimmingCharacters(in: .whitespacesAndNewlines))) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Side A keeps the name; Claude and Codex keep theirs.")
        }
        .alert("Couldn't Do That", isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var label: some View {
        // Accessibility sizes: the glyph sits above and the title and facts wrap instead of truncating.
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xxs))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Space.s))
        return layout {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(depth - 1) * Space.m)
                    .accessibilityLabel("Fork")
            }
            Image(systemName: past.agent.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .accessibilityLabel(past.agent == .claude ? "Claude" : "Codex")
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text(past.title).font(.body.weight(.semibold)).lineLimit(large ? 5 : 2)
                    if live != nil {
                        Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Live")
                    }
                }
                Text(facts)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(large ? 3 : 1)
                if !query.isEmpty, let snippet = past.snippet {
                    Text(highlighted(snippet)).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var facts: String {
        [past.project, past.branch, past.lastAt.map { Date(timeIntervalSince1970: $0).formatted(.dateTime.month(.abbreviated).day()) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var menu: some View {
        if model.tools.can(.hosted), past.cwd != nil {
            if live == nil {
                Button("Resume", systemImage: "play.circle") { actions.on(model).resume(past) }
            }
            Button("Fork", systemImage: "arrow.triangle.branch") { actions.on(model).resume(past, .init(fork: true)) }
        }
        if model.tools.can(.history) || model.isDemo {
            Button(past.isPinned ? "Unpin" : "Pin", systemImage: past.isPinned ? "pin.slash" : "pin") {
                change(HistoryChange(pinned: !past.isPinned))
            }
            Button("Rename…", systemImage: "pencil") {
                title = past.customTitle ?? past.title
                renaming = true
            }
            Button(past.isArchived ? "Unarchive" : "Archive", systemImage: past.isArchived ? "tray.and.arrow.up" : "archivebox") {
                change(HistoryChange(archived: !past.isArchived))
            }
        }
        Button("Copy Conversation ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = past.id }
    }

    private func change(_ change: HistoryChange) {
        guard let list else { return }
        Task {
            do {
                let updated = try await list.change(past, change)
                search?.apply(updated)
                if change.title != nil { renamed += 1 }
                // The row has left this list; the pill says where it went and can bring it back.
                if let archived = change.archived { Pill.show(archived ? "Archived" : "Unarchived") { undo(updated, archived: !archived) } }
            } catch {
                failure = MacTools.message(error)
                failed += 1
            }
        }
    }

    /// Puts an archive or unarchive back; the list reloads, since the row had left it.
    private func undo(_ session: PastSession, archived: Bool) {
        guard let list else { return }
        Task {
            do {
                _ = try await list.change(session, HistoryChange(archived: archived))
                await list.refresh()
            } catch {
                failure = MacTools.message(error)
                failed += 1
            }
        }
    }

    private func highlighted(_ snippet: String) -> AttributedString {
        var text = AttributedString(snippet)
        for word in query.split(separator: " ") {
            var start = text.startIndex
            while let range = text[start...].range(of: word, options: .caseInsensitive) {
                text[range].font = .subheadline.bold()
                text[range].foregroundColor = .primary
                start = range.upperBound
            }
        }
        return text
    }
}
