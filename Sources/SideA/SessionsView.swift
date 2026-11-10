import AppKit
import SideACore
import SwiftUI

/// Sessions in a window of its own, so Settings keeps one size.
struct SessionsWindow: View {
    let store: AccountStore
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        SessionsBrowser(model: store.sessions)
            .frame(minWidth: 860, minHeight: 560)
            .onAppear {
                store.sessions.appear()
                store.sessionsOpen = true
                if !store.sessionsRequested { dismissWindow(id: "sessions") }
            }
            .onDisappear { store.sessions.disappear(); store.sessionsOpen = false; store.sessionsRequested = false }
    }
}

/// Design tokens from beautifului.dev (the inkfold package).
enum Ink {
    static let hover = Color.primary.opacity(0.045)
    static let hover2 = Color.primary.opacity(0.075)
    static let field = Color.primary.opacity(0.05)
    static let line = Color.primary.opacity(0.08)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let selected = Color.accentColor.opacity(0.13)
    static let branch = Color.purple
    /// The iPhone's Amber: a session waiting on you.
    static let amber = Color(nsColor: NSColor(name: "SideA.amber") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua: NSColor(srgbRed: 1, green: 0.698, blue: 0.243, alpha: 1)
        case .accessibilityHighContrastAqua: NSColor(srgbRed: 0.761, green: 0.478, blue: 0, alpha: 1)
        case .accessibilityHighContrastDarkAqua: NSColor(srgbRed: 1, green: 0.761, blue: 0.4, alpha: 1)
        default: NSColor(srgbRed: 0.949, green: 0.616, blue: 0.043, alpha: 1)
        }
    })
    /// Read at each use, for animations started outside a view; views read the environment's.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var ease: Animation { reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.3) }
    static var glide: Animation { reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.22) }
    /// A fade that drifts `y` points, or only fades under Reduce Motion.
    static func rise(_ y: CGFloat) -> AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .offset(y: y)) }
}

struct ProjectGroup {
    struct Row { let session: SessionInfo; let depth: Int }
    let path: String
    let name: String
    let rows: [Row]
}

struct SessionsBrowser: View {
    @Bindable var model: SessionStore
    @State private var draft = ""
    @State private var note = ""
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    SearchField(model: model)
                    Button { model.creating = true } label: {
                        Image(systemName: "plus").font(.body.weight(.medium)).frame(width: 30, height: 32).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .modifier(HoverPlate())
                    .help("New Session (⌘N)")
                    .accessibilityLabel("New session")
                }
                .padding(.horizontal, 12).padding(.top, 12)
                if model.filtered {
                    ActiveFilters(model: model).padding(.horizontal, 12).padding(.top, 8)
                        .transition(Ink.rise(-4))
                }
                SessionList(model: model)
            }
            .frame(width: 320)
            .animation(Ink.glide, value: model.filtered)
            .background(.background.secondary)
            Rectangle().fill(Ink.line).frame(width: 1)
            SessionViewer(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        }
        .background {
            Button("Find") {
                if model.detail != nil { withAnimation(Ink.glide) { model.finding = true } } else { model.focusSearch += 1 }
            }
            .keyboardShortcut("f")
            .opacity(0)
            Button("New Session") { model.creating = true }.keyboardShortcut("n").opacity(0)
        }
        .sheet(isPresented: Binding(get: { model.creating }, set: { model.creating = $0 })) { NewSessionSheet(model: model) }
        .alert("Rename conversation", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Rename") { if let session = model.renaming { model.rename(session, to: draft) } }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: model.renaming) { draft = model.renaming?.name ?? "" }
        .alert("Send a note", isPresented: Binding(get: { model.noting != nil }, set: { if !$0 { model.noting = nil } })) {
            TextField("Note", text: $note)
            Button("Send") { if let session = model.noting { model.note(note, to: session) } }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: model.noting) {
            note = model.noteDraft
            model.noteDraft = ""
        }
        .confirmationDialog("Quit this session?", isPresented: Binding(get: { model.quitting != nil }, set: { if !$0 { model.quitting = nil } }), presenting: model.quitting) { session in
            Button("Quit Session", role: .destructive) { model.quit(session) }
        } message: { session in
            Text("Frees about \(Megabytes.text(session.memory ?? 0)).")
        }
        .sheet(item: Binding(get: { model.restarting.map(Restarting.init) }, set: { if $0 == nil { model.restarting = nil } })) { item in
            RestartSheet(model: model, session: item.session)
        }
        .confirmationDialog("Stop the server on :\(model.stoppingServer?.port ?? 0)?", isPresented: Binding(get: { model.stoppingServer != nil }, set: { if !$0 { model.stoppingServer = nil } }), presenting: model.stoppingServer) { port in
            Button("Stop Server", role: .destructive) { model.stopServer(port) }
        } message: { port in
            Text("Sends \(port.command ?? "the process") (pid \(port.pid)) a quit signal. The session keeps running.")
        }
    }
}

/// The session Restart Fresh's sheet is for, as a sheet item.
private struct Restarting: Identifiable {
    let session: LiveSession
    var id: Int { session.pid }
}

struct SearchField: View {
    @Bindable var model: SessionStore
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.callout.weight(.medium)).foregroundStyle(.tertiary)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focused)
                .onChange(of: model.query) { model.queryChanged() }
                .onExitCommand { model.query = "" }
                .onKeyPress(.downArrow) { model.step(1); return .handled }
                .onKeyPress(.upArrow) { model.step(-1); return .handled }
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.callout) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Clear")
                    .transition(Ink.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
            }
            FilterMenu(model: model)
        }
        .padding(.leading, 10).padding(.trailing, 4).frame(height: 32)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.55) : Ink.line, lineWidth: 1)
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(focused ? 0.12 : 0)).padding(-3)
        }
        .animation(Ink.glide, value: focused)
        .animation(Ink.glide, value: model.query.isEmpty)
        .onAppear { focused = true }
        .onChange(of: model.focusSearch) { focused = true }
    }

    private var placeholder: String {
        model.remaining > 0 ? "Reading \(model.remaining.formatted()) more conversations…"
            : model.total > 0 ? "Search \(model.total.formatted()) conversations" : "Search conversations"
    }
}

struct FilterMenu: View {
    @Bindable var model: SessionStore
    var body: some View {
        Menu {
            Picker("Agent", selection: $model.agent) {
                Text("Any").tag(String?.none)
                Text("Claude").tag(String?.some("claude"))
                Text("Codex").tag(String?.some("codex"))
            }
            .pickerStyle(.menu)
            Picker("Date", selection: $model.days) {
                Text("Any time").tag(Double?.none)
                Text("Today").tag(Double?.some(1))
                Text("Past week").tag(Double?.some(7))
                Text("Past month").tag(Double?.some(30))
            }
            .pickerStyle(.menu)
            Picker("Project", selection: $model.project) {
                Text("Any").tag(String?.none)
                // A choice missing from the options would be reset to nil by the picker.
                ForEach(model.projects + (model.project.map { model.projects.contains($0) ? [] : [$0] } ?? []), id: \.self) {
                    Text(URL(fileURLWithPath: $0).lastPathComponent).tag(String?.some($0))
                }
            }
            .pickerStyle(.menu)
            Divider()
            Toggle("Archived", isOn: $model.showArchived)
            Toggle("Automated runs", isOn: $model.includeAutomated)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.callout.weight(.medium))
                .foregroundStyle(model.filtered ? Color.accentColor : .secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .modifier(HoverPlate(size: 24, radius: 6))
        .help("Filter")
        .onChange(of: model.agent) { Task { await model.refresh() } }
        .onChange(of: model.project) { Task { await model.refresh() } }
        .onChange(of: model.days) { Task { await model.refresh() } }
        .onChange(of: model.includeAutomated) { Task { await model.refresh() } }
        .onChange(of: model.showArchived) { Task { await model.refresh() } }
    }
}

/// Only what is applied, each removable, like Linear's filter bar.
struct ActiveFilters: View {
    @Bindable var model: SessionStore
    var body: some View {
        HStack(spacing: 5) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if let agent = model.agent { FilterToken(text: agent == "codex" ? "Codex" : "Claude") { model.agent = nil } }
                    if let days = model.days { FilterToken(text: days == 1 ? "Today" : days == 7 ? "Past week" : "Past month") { model.days = nil } }
                    if let project = model.project { FilterToken(text: URL(fileURLWithPath: project).lastPathComponent, icon: "folder") { model.project = nil } }
                    if model.showArchived { FilterToken(text: "Archived", icon: "archivebox") { model.showArchived = false } }
                    if model.includeAutomated { FilterToken(text: "With automated runs") { model.includeAutomated = false } }
                }
            }
            Button("Clear") {
                withAnimation(Ink.glide) { model.agent = nil; model.days = nil; model.project = nil; model.showArchived = false; model.includeAutomated = false }
            }
            .buttonStyle(.plain).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

struct FilterToken: View {
    let text: String
    var icon: String?
    let remove: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9.5)).foregroundStyle(.secondary) }
            Text(text).font(.subheadline.weight(.medium)).lineLimit(1)
            Button { withAnimation(Ink.glide) { remove() } } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(hovering ? .primary : .tertiary)
            }
            .buttonStyle(.plain).help("Remove filter")
        }
        .padding(.leading, 8).padding(.trailing, 6).frame(height: 22)
        .background(Ink.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ink.line))
        .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
    }
}

struct RowPlate: ViewModifier {
    let id: String
    let selected: Bool
    @Binding var hovered: String?
    var radius: CGFloat = 8
    func body(content: Content) -> some View {
        content
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Ink.selected)
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Ink.hover)
                        .opacity(hovered == id ? 1 : 0)
                        .animation(.easeOut(duration: 0.1), value: hovered == id)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = id } else if hovered == id { hovered = nil }
            }
    }
}

struct HoverPlate: ViewModifier {
    var size: CGFloat = 28
    var radius: CGFloat = 8
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .frame(width: size, height: size)
            .background(hovering ? Ink.hover2 : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
    }
}

struct Press: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(Ink.glide, value: configuration.isPressed)
    }
}

struct SessionList: View {
    @Bindable var model: SessionStore
    @State private var collapsed: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var hovered: String?
    @FocusState private var focused: Bool
    var body: some View {
        let groups = model.groups
        let listed = model.showsSections ? model.listed : .init()
        let finishedIDs = Set(listed.finished.compactMap(\.finish.sessionID))
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if model.searching {
                        ForEach(model.results) { session in
                            SearchResultRow(model: model, session: session, hovered: $hovered)
                                .transition(Ink.rise(6))
                        }
                    } else {
                        if !listed.waiting.isEmpty {
                            SectionLabel(text: "Needs you")
                            ForEach(listed.waiting) { session in
                                WaitingRow(model: model, session: session, hovered: $hovered)
                                    .transition(Ink.rise(-4))
                            }
                        }
                        if !listed.finished.isEmpty {
                            SectionLabel(text: "Ready")
                            ForEach(listed.finished) { item in
                                FinishedRow(model: model, item: item, hovered: $hovered)
                                    .transition(Ink.rise(-4))
                            }
                        }
                        if !listed.working.isEmpty || !listed.idle.isEmpty {
                            RunningHeader(model: model, title: listed.working.isEmpty ? "Idle" : "Working",
                                          count: listed.working.isEmpty ? listed.idle.count : listed.working.count)
                            // Project captions only help once sessions span more than one project.
                            let captions = Set((listed.working + listed.idle).map { model.project(of: $0.cwd) }).count > 1
                            ForEach(model.byProject(listed.working)) { group in
                                if captions { ProjectCaption(name: group.project) }
                                ForEach(group.sessions) { session in
                                    RunningRow(model: model, session: session, hovered: $hovered)
                                        .transition(Ink.rise(-4))
                                }
                            }
                            if !listed.idle.isEmpty {
                                IdleFold(model: model, sessions: listed.idle)
                                if model.idleOpen {
                                    ForEach(model.byProject(listed.idle)) { group in
                                        if captions { ProjectCaption(name: group.project) }
                                        ForEach(group.sessions) { session in
                                            RunningRow(model: model, session: session, hovered: $hovered)
                                                .transition(Ink.rise(-4))
                                        }
                                    }
                                }
                            }
                        }
                        if model.showsSections && !model.visiblePins.isEmpty {
                            SectionLabel(text: "Pinned")
                            ForEach(model.visiblePins.filter { !finishedIDs.contains($0.id) }) { session in
                                SessionRow(model: model, session: session, depth: 0, hovered: $hovered)
                                    .transition(Ink.rise(-4))
                            }
                        }
                        ForEach(groups, id: \.path) { group in
                            let folded = collapsed.contains(group.path)
                            let rows = group.rows.filter { !finishedIDs.contains($0.session.id) }
                            ProjectHeader(name: group.name, count: rows.count, collapsed: folded) {
                                withAnimation(Ink.ease) { collapsed.formSymmetricDifference([group.path]) }
                            }
                            if !folded {
                                let limit = expanded.contains(group.path) ? rows.count : 5
                                ForEach(rows.prefix(limit), id: \.session.id) { row in
                                    SessionRow(model: model, session: row.session, depth: row.depth, hovered: $hovered)
                                        .transition(Ink.rise(-4))
                                }
                                if rows.count > limit {
                                    MoreButton(count: rows.count - limit) { withAnimation(Ink.ease) { _ = expanded.insert(group.path) } }
                                }
                            }
                        }
                    }
                    if model.results.isEmpty { EmptyList(model: model) }
                }
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 12)
            }
            .onHover { inside in model.holding = inside }
            .onDisappear { model.holding = false }
            .overlay(alignment: .top) {
                if model.heldBehind {
                    Button { model.showHeld() } label: {
                        Label("Show Updates", systemImage: "arrow.up").font(.subheadline.weight(.medium))
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Ink.line))
                    }
                    .buttonStyle(Press())
                    .padding(.top, 6)
                    .help("The list holds still under the pointer. This puts changes in place now.")
                    .transition(Ink.rise(-6))
                }
            }
            .animation(Ink.glide, value: model.heldBehind)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { model.step(1); return .handled }
            .onKeyPress(.upArrow) { model.step(-1); return .handled }
            .onKeyPress(.escape) { model.focusSearch += 1; return .handled }
            .onChange(of: hovered) { _, id in
                guard let id else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    if hovered == id { model.prefetch(id, at: model.searching ? model.results.first { $0.id == id }?.snippets?.first?.uuid : nil) }
                }
            }
            .onChange(of: model.selectedID) { _, id in
                // Arrow keys keep working from the list once a row is picked, not only from search.
                if id != nil && !model.searching { focused = true }
                if let id, !model.idleOpen, listed.idle.contains(where: { $0.sessionID == id }) { model.idleOpen = true }
                guard let id, !model.searching, let group = groups.first(where: { $0.rows.contains { $0.session.id == id } }) else {
                    if let id { proxy.scrollTo(id) }
                    return
                }
                collapsed.remove(group.path)
                if let index = group.rows.firstIndex(where: { $0.session.id == id }), index >= 5 { expanded.insert(group.path) }
                proxy.scrollTo(id)
            }
        }
    }
}

struct EmptyList: View {
    let model: SessionStore
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: model.listError != nil ? "exclamationmark.triangle" : model.searching ? "text.magnifyingglass" : "tray")
                .font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
            Text(model.listError ?? (model.searching ? "Nothing matches “\(model.query)”" : model.filtered ? "Nothing matches these filters"
                    : model.remaining != 0 ? "Reading your conversations…" : "No conversations yet"))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.searching && !model.includeAutomated {
                Button("Include Automated Runs") { model.includeAutomated = true }.buttonStyle(.link).font(.callout)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 56).padding(.horizontal, 16)
    }
}

struct ProjectHeader: View {
    let name: String
    let count: Int
    let collapsed: Bool
    let toggle: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(name).font(.subheadline.weight(.semibold)).textCase(.uppercase).tracking(0.6).lineLimit(1)
                    .foregroundStyle(hovering ? .secondary : .tertiary)
                Text(count.formatted()).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.quaternary)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .opacity(hovering || collapsed ? 1 : 0)
            }
            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).textCase(.uppercase).tracking(0.6).foregroundStyle(.tertiary)
            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 5)
    }
}

struct MoreButton: View {
    let count: Int
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                Text("\(count.formatted()) more")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(hovering ? .secondary : .tertiary)
            .padding(.leading, 28).frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
    }
}

enum When {
    static func compact(_ ts: Double?) -> String {
        guard let ts else { return "" }
        let seconds = Date().timeIntervalSince1970 - ts
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        let date = Date(timeIntervalSince1970: ts)
        if seconds < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The iPhone's working glyph; macOS 14 has no progress.indicator, so it shows a still one.
struct WorkingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if #available(macOS 15, *) {
                Image(systemName: "progress.indicator")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: !reduceMotion)
            } else {
                Image(systemName: "ellipsis.circle")
            }
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

struct LiveMark: View {
    let status: String
    var body: some View {
        switch status {
        case "waiting": Beacon(tint: Ink.amber).help("Waiting on you")
        // Codex's rollout showed no turn yet, so it may be working or not.
        case "unknown": Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1).frame(width: 6, height: 6).help("Status unknown")
        default: WorkingMark().help("Working")
        }
    }
}

/// Codex beside a title, with the island's glyph; Claude, the usual case, has none.
struct CodexMark: View {
    var body: some View {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
            .help("Codex").accessibilityLabel("Codex")
    }
}

/// One line, like a sidebar item: the project is already the group.
struct SessionRow: View {
    let model: SessionStore
    let session: SessionInfo
    let depth: Int
    @Binding var hovered: String?
    var body: some View {
        let selected = model.selectedID == session.id
        Button { model.open(session.id) } label: {
            HStack(spacing: 7) {
                Group {
                    if depth > 0 {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Ink.branch.opacity(0.7))
                    } else if session.isCodex {
                        Circle().fill(Color.teal).frame(width: 5, height: 5).help("Codex")
                    }
                }
                .frame(width: 12)
                .padding(.leading, CGFloat(max(depth - 1, 0)) * 12)
                Text(session.name).font(.body).lineLimit(1)
                    .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.85))
                Spacer(minLength: 8)
                if let live = model.liveByID[session.id] {
                    LiveMark(status: live.status)
                } else {
                    Text(When.compact(session.lastTs)).font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .padding(.leading, 4).padding(.trailing, 9).frame(height: 28)
            .modifier(RowPlate(id: session.id, selected: selected, hovered: $hovered))
        }
        .buttonStyle(.plain)
        .contextMenu { SessionMenuItems(model: model, session: session) }
    }
}

struct WaitingRow: View {
    let model: SessionStore
    let session: LiveSession
    @Binding var hovered: String?
    var body: some View {
        let id = session.sessionID ?? ""
        Button { model.open(id) } label: {
            HStack(spacing: 7) {
                Beacon(tint: Ink.amber).frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(model.names[id] ?? session.title ?? session.name ?? "Session").font(.body).lineLimit(1)
                        if session.provider == .codex { CodexMark() }
                    }
                    Text(session.waitingFor.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Waiting for you")
                        .font(.subheadline).foregroundStyle(Ink.amber).lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.leading, 4).padding(.trailing, 9).frame(height: 40)
            .modifier(RowPlate(id: id, selected: model.selectedID == id, hovered: $hovered))
        }
        .buttonStyle(.plain)
    }
}

/// Working, or Idle when nothing works, with how many and the memory every live session holds, in one line.
struct RunningHeader: View {
    let model: SessionStore
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).textCase(.uppercase).tracking(0.6).foregroundStyle(.tertiary)
            Text(count.formatted()).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.quaternary)
            Spacer()
            Text(Megabytes.text(model.liveMemory)).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.tertiary)
                .help("Memory held by all \(model.live.count) sessions and everything they started")
        }
        .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 5)
        .accessibilityElement(children: .combine)
    }
}

/// A project's name above its running sessions.
struct ProjectCaption: View {
    let name: String
    var body: some View {
        Text(name).font(.subheadline.weight(.medium)).foregroundStyle(.tertiary).lineLimit(1)
            .padding(.leading, 23).padding(.top, 6).padding(.bottom, 2)
    }
}

/// Idle sessions folded into one row, with those idle half an hour or more a click from quitting.
struct IdleFold: View {
    @Bindable var model: SessionStore
    let sessions: [LiveSession]
    @State private var hovering = false
    var body: some View {
        let stale = model.stale
        HStack(spacing: 7) {
            Button { withAnimation(Ink.ease) { model.idleOpen.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(model.idleOpen ? 90 : 0)).frame(width: 12)
                    Text("\(sessions.count) idle").font(.callout).foregroundStyle(hovering ? .primary : .secondary)
                    Text(Megabytes.text(sessions.compactMap(\.memory).reduce(0, +))).font(.subheadline).monospacedDigit().foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
            .accessibilityLabel("\(sessions.count) idle sessions")
            .accessibilityValue(model.idleOpen ? "Shown" : "Folded")
            if !stale.isEmpty {
                Button("Quit \(stale.count) Idle…") { model.quittingStale = true }.controlSize(.small)
                    .help("Quit the \(stale.count) idle 30 minutes or more. They free about \(Megabytes.text(stale.compactMap(\.memory).reduce(0, +))).")
            }
        }
        .padding(.leading, 4).padding(.trailing, 6).frame(height: 32)
        .confirmationDialog("Quit \(model.stale.count) idle sessions?", isPresented: $model.quittingStale) {
            Button("Quit \(model.stale.count) Sessions", role: .destructive) { model.quitStale() }
        } message: {
            Text("Frees about \(Megabytes.text(model.stale.compactMap(\.memory).reduce(0, +))).")
        }
    }
}

enum Megabytes {
    static func text(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }
}

/// A finished session waiting for its next task; the viewer has the reply box.
struct FinishedRow: View {
    let model: SessionStore
    let item: Island.Ready
    @Binding var hovered: String?
    var body: some View {
        let id = item.finish.sessionID ?? ""
        Button { model.open(id) } label: {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green).frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.names[id] ?? item.title).font(.body).lineLimit(1)
                    Text(item.finish.summary.isEmpty ? "Ready for its next task" : item.finish.summary)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(When.compact(item.at.timeIntervalSince1970)).font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
            }
            .padding(.leading, 4).padding(.trailing, 9).frame(height: 40)
            .modifier(RowPlate(id: id, selected: model.selectedID == id, hovered: $hovered))
        }
        .buttonStyle(.plain)
        .contextMenu { Button("Show in Terminal") { model.store.island.go(item) } }
        .accessibilityLabel("\(model.names[id] ?? item.title) is ready. \(item.finish.summary)")
    }
}

/// A running session: what it is doing now, or what looks wrong, with a note, a stop and its terminal at hand.
struct RunningRow: View {
    let model: SessionStore
    let session: LiveSession
    @Binding var hovered: String?
    var body: some View {
        let id = session.sessionID ?? ""
        let busy = session.status == "busy"
        // What the phone offers for this session, and only that.
        let commands = SessionCommands(store: model.store)
        let abilities = commands.abilities(session, status: commands.status(session))
        let noting = abilities.contains(.note)
        let waiting = model.mail[session.pid]
        let stopping = session.provider == .claude && abilities.contains(.interrupt) && waiting == nil
        let escape = (session.hosted != nil || abilities.contains(.replyTerminal)) && abilities.contains(.interrupt)
        // As on the phone: any interactive session quits; Claude forks a running conversation; Restart Fresh needs a pane.
        let interactive = session.kind.map { $0 == "interactive" } ?? true
        let forks = interactive && session.provider == .claude && session.cwd != nil
        let restarts = interactive && session.cwd != nil && model.store.hostingWanted && model.store.hosted.available
        Button { model.open(id) } label: {
            HStack(spacing: 7) {
                Group {
                    if busy { WorkingMark() } else { Circle().fill(Color.secondary.opacity(0.5)).frame(width: 5, height: 5) }
                }
                .frame(width: 12)
                let title = HStack(spacing: 4) {
                    Text(model.names[id] ?? session.title ?? session.name ?? "Session").font(.body).lineLimit(1)
                    if session.provider == .codex { CodexMark() }
                }
                VStack(alignment: .leading, spacing: 1) {
                    // Measured at a 96pt title: the title truncates first, then ports, then memory drop out.
                    // Hovering leaves this alone; the actions cover the end of the row instead of reflowing it.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) { titleSlot(title); ports; memory }
                        HStack(spacing: 4) { titleSlot(title); memory }
                        title
                    }
                    detail.font(.subheadline).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 4).padding(.trailing, 6).frame(height: 40)
            .modifier(RowPlate(id: id, selected: model.selectedID == id, hovered: $hovered))
        }
        .buttonStyle(.plain)
        .help(session.memory.map { "\(Megabytes.text($0)) in \(session.processes ?? 1) processes" } ?? "")
        .overlay(alignment: .trailing) {
            if hovered == id {
                HStack(spacing: 2) {
                    if noting { RowAction(symbol: "text.bubble", help: "Send a note it reads after its current step") { model.noting = session } }
                    if escape {
                        RowAction(symbol: "stop.circle", help: "Stop its current turn") { model.stop(session, now: true) }
                    } else if stopping {
                        RowAction(symbol: "stop.circle", help: "Stop before its next step") { model.stop(session, now: false) }
                    }
                    RowAction(symbol: "macwindow", help: "Show in its terminal") { model.show(session) }
                }
                .padding(.leading, 18)
                .background {
                    ZStack {
                        Rectangle().fill(.background.secondary)
                        Rectangle().fill(model.selectedID == id ? Ink.selected : Ink.hover)
                    }
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: UnitPoint(x: 0.25, y: 0.5)))
                }
                .padding(.trailing, 6)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.1), value: hovered == id)
        .contextMenu {
            if noting || stopping || escape || waiting != nil {
                if noting { Button("Send a Note…") { model.noting = session } }
                if escape { Button("Stop Now") { model.stop(session, now: true) } }
                if stopping { Button("Stop Before Its Next Step") { model.stop(session, now: false) } }
                if waiting == "note" {
                    Section("Waiting Note") {
                        Button("Edit…") { model.editNote(session) }
                        Button("Copy") { model.noteText(session).map(SessionStore.copy) }
                        Button("Delete", role: .destructive) { model.deleteMail(session) }
                    }
                } else if waiting == "stop" {
                    Button("Don't Stop") { model.deleteMail(session) }
                }
                Divider()
            }
            Button("Show in Terminal") { model.show(session) }
            if !id.isEmpty {
                Button(model.isPinned(id) ? "Unpin" : "Pin") { model.togglePin(id) }
                if forks { Button("Fork") { model.fork(session) } }
                if restarts { Button("Restart Fresh…") { model.restarting = session } }
            }
            if let ports = session.ports, !ports.isEmpty {
                Divider()
                ForEach(ports, id: \.self) { port in
                    Button("Open localhost:\(port.port)") { NSWorkspace.shared.open(URL(string: "http://localhost:\(port.port)")!) }
                }
                ForEach(ports, id: \.self) { port in
                    Button("Stop Server on :\(port.port)…") { model.stoppingServer = port }
                }
            }
            if interactive {
                Divider()
                Button("Quit Session…") { model.quitting = session }
            }
        }
        .accessibilityElement(children: .combine)
        // The same actions the row offers, and only those.
        .accessibilityActions {
            if noting { Button("Send a Note…") { model.noting = session } }
            if escape { Button("Stop Now") { model.stop(session, now: true) } }
            if stopping { Button("Stop Before Its Next Step") { model.stop(session, now: false) } }
            Button("Show in Terminal") { model.show(session) }
            if let port = session.ports?.first {
                Button("Open its server") { NSWorkspace.shared.open(URL(string: "http://localhost:\(port.port)")!) }
            }
            if interactive { Button("Quit Session") { model.quitting = session } }
        }
    }

    private func titleSlot(_ title: some View) -> some View {
        title.frame(minWidth: 96, idealWidth: 96, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var ports: some View {
        if let ports = session.ports, !ports.isEmpty {
            Chip(text: (ports.prefix(2).map { ":\($0.port)" } + (ports.count > 2 ? ["+\(ports.count - 2)"] : [])).joined(separator: " "))
                .help(ports.map { "localhost:\($0.port) · \($0.command ?? "pid \($0.pid)")" }.joined(separator: "\n"))
        }
    }

    /// Only memory worth acting on takes room from the title; the rest is in the row's tooltip.
    @ViewBuilder private var memory: some View {
        if let memory = session.memory, memory >= 1024 {
            Chip(text: Megabytes.text(memory), tint: .orange)
                .help("\(session.processes ?? 1) processes")
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.mail[session.pid] {
        case "note": Text("Note waits for its next step").foregroundStyle(Color.accentColor)
        case "stop": Text("Stops before its next step").foregroundStyle(Color.accentColor)
        default:
            // A large context is common enough that it never takes the place of the step a session is on.
            if let flag = session.flag, flag.kind != "bloated" {
                Label(flag.text, systemImage: Self.symbol(flag.kind)).labelStyle(.titleAndIcon).foregroundStyle(Self.tint(flag.kind))
                    .help(Self.advice(flag.kind))
            } else if session.status == "busy" {
                Text(session.activity ?? "Working").foregroundStyle(.secondary)
            } else if session.status == "unknown" {
                Text("Status unknown").foregroundStyle(.secondary)
                    .help("Codex hasn't written a turn Side A can read yet, so it may be working or idle.")
            } else if session.flag?.kind == "bloated", let context = session.context {
                (Text(idle) + Text(" · \(context / 1000)k context").foregroundStyle(.tertiary)).foregroundStyle(.secondary)
                    .help(Self.advice("bloated"))
            } else {
                Text(idle).foregroundStyle(.secondary)
            }
        }
    }

    private var idle: String {
        guard let since = session.since, session.stale else { return "Idle" }
        return "Idle \(Date(timeIntervalSince1970: since).formatted(.relative(presentation: .named)))"
    }

    static func symbol(_ kind: String) -> String {
        ["stuck": "hourglass", "loop": "arrow.triangle.2.circlepath", "failing": "exclamationmark.triangle", "bloated": "square.stack.3d.up"][kind] ?? "info.circle"
    }

    static func tint(_ kind: String) -> Color { kind == "bloated" ? .secondary : kind == "stuck" ? .orange : .red }

    static func advice(_ kind: String) -> String {
        switch kind {
        case "stuck": "Its transcript hasn't moved in a while. A long command may still be running; show it in its terminal to check."
        case "loop": "It keeps making the same call. A note with a different approach often breaks the loop."
        case "failing": "Its last steps failed. Send a note or stop it and steer it yourself."
        default: "Every step re-reads this context. /compact or a fresh session costs less and keeps it sharp."
        }
    }
}

/// The one badge style for small facts beside a title: ports, memory, markers.
struct Chip: View {
    let text: String
    var tint: Color?
    var body: some View {
        Text(text).font(.subheadline.weight(.medium)).monospacedDigit().lineLimit(1).fixedSize()
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .padding(.horizontal, 6).frame(height: 16)
            .background((tint ?? .primary).opacity(tint == nil ? 0.06 : 0.12), in: Capsule())
    }
}

struct RowAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct SessionMenuItems: View {
    let model: SessionStore
    let session: SessionInfo
    var body: some View {
        Button(model.isPinned(session.id) ? "Unpin" : "Pin") { model.togglePin(session.id) }
        Button("Rename…") { model.renaming = session }
        Button(model.isArchived(session.id) ? "Unarchive" : "Archive") { model.toggleArchive(session.id) }
        Divider()
        Button("Copy Resume Command") { SessionStore.copy(SessionStore.command(session, fork: false)) }
        Button("Copy Session ID") { SessionStore.copy(session.id) }
    }
}

struct SearchResultRow: View {
    let model: SessionStore
    let session: SessionInfo
    @Binding var hovered: String?
    var body: some View {
        let selected = model.selectedID == session.id
        Button { model.open(session.id, at: session.snippets?.first?.uuid) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.name).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let live = model.liveByID[session.id] {
                        LiveMark(status: live.status)
                    } else {
                        Text(When.compact(session.lastTs)).font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                if let snippet = session.snippets?.first {
                    Text(Highlight.attributed(snippet.text))
                        .font(.system(size: 12, design: snippet.role == "tool" ? .monospaced : .default))
                        .foregroundStyle(.secondary).lineLimit(2).lineSpacing(1.5)
                }
                HStack(spacing: 5) {
                    if session.isCodex { Circle().fill(Color.teal).frame(width: 5, height: 5) }
                    Text(session.project.isEmpty ? (session.isCodex ? "Codex" : "Claude Code") : session.project)
                }
                .font(.subheadline).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .modifier(RowPlate(id: session.id, selected: selected, hovered: $hovered, radius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu { SessionMenuItems(model: model, session: session) }
    }
}

enum Highlight {
    static func attributed(_ text: String) -> AttributedString {
        let text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        var result = AttributedString()
        for (index, part) in text.split(separator: "\u{2}", omittingEmptySubsequences: false).enumerated() {
            let pieces = part.split(separator: "\u{3}", maxSplits: 1, omittingEmptySubsequences: false)
            if index > 0, pieces.count == 2 {
                var hit = AttributedString(String(pieces[0]))
                hit.foregroundColor = .primary
                hit.backgroundColor = Color.yellow.opacity(0.32)
                result += hit + AttributedString(String(pieces[1]))
            } else {
                result += AttributedString(String(part))
            }
        }
        return result
    }
}
