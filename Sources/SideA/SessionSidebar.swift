import AppKit
import SideACore
import SideAProtocol
import SideASessionKit
import SwiftUI

/// Something just done to the list that can be taken back for a few seconds.
struct ListUndo: Identifiable {
    let id = UUID()
    let text: String
    /// Nil: nothing to take back, the line only says what happened.
    var undo: (@MainActor () -> Void)?
}

extension SessionDesk {
    /// How long a list action can be taken back, and how long an idle session's quit waits to be.
    static let undoTime: Duration = .seconds(5)

    func offer(_ text: String, undo: (@MainActor () -> Void)? = nil) { self.undo = ListUndo(text: text, undo: undo) }

    func takeBack() {
        let last = undo
        undo = nil
        last?.undo?()
    }
}

// MARK: Snooze

extension SessionStore {
    /// Snoozes are the phone's, kept by Remote's controller whether Remote is on or not. This window hears of a change
    /// itself, since the event hub that tells the phone is only there while Remote runs.
    func listenForSnoozes() {
        guard !desk.snoozeHeard else { return }
        desk.snoozeHeard = true
        let remote = store.remote
        remote.snoozes.changed = { [weak self, weak remote] in
            remote?.events?.liveChanged()
            self?.desk.snoozeTick += 1
        }
    }

    /// The snooze a running session is under, if it still holds: building its row is what wakes one that came to
    /// need the user.
    func snooze(of live: LiveSession) -> SessionSnooze? {
        _ = desk.snoozeTick
        guard store.remote.snoozes.entries[WireBuilders.key(live)] != nil else { return nil }
        return WireBuilders.session(live, store: store, finished: []).snooze
    }

    func snooze(_ live: LiveSession, _ choice: SessionSnooze.Choice, now: Date = Date()) {
        let row = WireBuilders.session(live, store: store, finished: [])
        switch Snoozes.refusal(row) {
        case .failure?: error = "It has failed or stalled, so it would wake at once. Sort that out first."
        case .some: error = "It's asking something. Answer it first."
        case nil:
            guard store.remote.snoozes.snooze(row, choice, until: choice.until(from: now)?.timeIntervalSince1970, now: now) != nil else { return }
            snoozeChanged()
            let name = live.sessionID.flatMap { names[$0] } ?? live.title ?? live.name ?? "Session"
            desk.offer("Snoozed “\(name)”") { [weak self] in self?.wake(live) }
        }
    }

    func wake(_ live: LiveSession) {
        store.remote.snoozes.wake(WireBuilders.key(live))
        snoozeChanged()
    }

    private func snoozeChanged() {
        store.remote.events?.liveChanged()
        withAnimation(Ink.ease) { desk.snoozeTick += 1 }
    }

    /// The running list with the snoozed sessions taken out of Working and Idle. One that needs the user is never
    /// among them: needing the user wakes it.
    var sidebar: (listed: Listed, asleep: [LiveSession], behind: Bool) {
        let shown = self.shown
        var listed = shown.listed
        let asleep = (listed.working + listed.idle).filter { snooze(of: $0) != nil }
        guard !asleep.isEmpty else { return (listed, [], shown.behind) }
        let pids = Set(asleep.map(\.pid))
        listed.working.removeAll { pids.contains($0.pid) }
        listed.idle.removeAll { pids.contains($0.pid) }
        return (listed, asleep, shown.behind)
    }
}

/// The Snooze choices, for a row's menu and the Session menu.
struct SnoozeItems: View {
    let model: SessionStore
    let session: LiveSession
    var body: some View {
        if model.snooze(of: session) != nil {
            Button("Wake") { model.wake(session) }
        } else {
            Menu("Snooze") {
                ForEach(SessionSnooze.Choice.offered, id: \.self) { choice in
                    Button(choice.title) { model.snooze(session, choice) }
                }
            }
        }
    }
}

struct SnoozedFold: View {
    let model: SessionStore
    let sessions: [LiveSession]
    @State private var hovering = false
    var body: some View {
        let open = model.desk.snoozedOpen
        Button { withAnimation(Ink.ease) { model.desk.snoozedOpen.toggle() } } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                Image(systemName: "moon.zzz").font(.subheadline).foregroundStyle(.tertiary)
                Text("\(sessions.count) snoozed").font(.callout).foregroundStyle(hovering ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4).padding(.trailing, 6).frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
        .accessibilityLabel("\(sessions.count) snoozed sessions")
        .accessibilityValue(open ? "Shown" : "Folded")
    }
}

// MARK: Undo, and a quit that waits

extension SessionStore {
    func archive(_ id: String) {
        let was = isArchived(id)
        toggleArchive(id)
        desk.offer(was ? "Unarchived" : "Archived") { [weak self] in
            guard let self, isArchived(id) != was else { return }
            toggleArchive(id)
        }
    }

    func pin(_ id: String) {
        let was = isPinned(id)
        togglePin(id)
        if was { desk.offer("Unpinned") { [weak self] in if self?.isPinned(id) == false { self?.togglePin(id) } } }
    }

    /// It is doing nothing anyone would lose: no turn running, nothing asked, no server listening.
    nonisolated static func quitsQuietly(_ session: LiveSession) -> Bool {
        !["busy", "waiting"].contains(session.status) && (session.ports ?? []).isEmpty
    }

    /// An idle session quits after a few seconds unless that is undone, and only if it is still idle then. One that is
    /// working, asking or serving a port asks first, as it always has.
    func requestQuit(_ session: LiveSession) {
        guard Self.quitsQuietly(session) else { return quitting = session }
        let pid = session.pid
        let name = session.sessionID.flatMap { names[$0] } ?? session.title ?? session.name ?? "Session"
        desk.quits[pid]?.cancel()
        desk.quits[pid] = Task { [weak self] in
            try? await Task.sleep(for: SessionDesk.undoTime)
            guard !Task.isCancelled, let self else { return }
            desk.quits[pid] = nil
            guard let now = live.first(where: { $0.pid == pid }), Self.quitsQuietly(now) else { return }
            desk.quitNow(now, self)
        }
        desk.offer("Quitting “\(name)”") { [weak self] in
            self?.desk.quits[pid]?.cancel()
            self?.desk.quits[pid] = nil
        }
    }
}

// MARK: Several rows at once

extension SessionStore {
    /// Whether a row draws as chosen: the open conversation, or one of several picked.
    func shows(_ id: String) -> Bool { desk.picked.isEmpty ? selectedID == id : desk.picked.contains(id) }

    /// A click on a row. ⌘ adds it to the rows picked or takes it out; ⇧ picks every row from the open one to it; a
    /// plain click opens it and lets the others go.
    func click(_ id: String, flags: NSEvent.ModifierFlags = NSApp.currentEvent?.modifierFlags ?? []) {
        desk.picked = Self.picked(desk.picked, clicking: id, command: flags.contains(.command), shift: flags.contains(.shift),
                                  open: selectedID, order: orderedIDs)
        if desk.picked.isEmpty { open(id) }
    }

    nonisolated static func picked(_ picked: Set<String>, clicking id: String, command: Bool, shift: Bool, open: String?, order: [String]) -> Set<String> {
        if shift, let open, let from = order.firstIndex(of: open), let to = order.firstIndex(of: id) {
            return Set(order[min(from, to)...max(from, to)]).union(picked)
        }
        guard command else { return [] }
        var next = picked.isEmpty ? Set([open].compactMap { $0 }) : picked
        next.formSymmetricDifference([id])
        return next.count == 1 && next.first == open ? [] : next
    }

    private func running(_ ids: Set<String>) -> [LiveSession] { live.filter { $0.sessionID.map(ids.contains) ?? false } }

    func archivePicked() {
        let ids = desk.picked.filter { liveByID[$0] == nil && !isArchived($0) }
        ids.forEach { setArchived($0, true) }
        desk.picked = []
        guard !ids.isEmpty else { return }
        desk.offer("Archived \(ids.count)") { [weak self] in ids.forEach { self?.setArchived($0, false) } }
    }

    func pinPicked() {
        let ids = desk.picked.filter { !isPinned($0) }
        ids.forEach { setPinned($0, true) }
        desk.picked = []
        if !ids.isEmpty { Task { await refresh() } }
    }

    func snoozePicked(_ choice: SessionSnooze.Choice) {
        let sessions = running(desk.picked)
        let refused = sessions.filter { live in
            let row = WireBuilders.session(live, store: store, finished: [])
            return store.remote.snoozes.snooze(row, choice, until: choice.until()?.timeIntervalSince1970) == nil
        }
        store.remote.events?.liveChanged()
        withAnimation(Ink.ease) { desk.snoozeTick += 1 }
        // The ones that couldn't be snoozed stay picked, so it is plain which they were.
        desk.picked = Set(refused.compactMap(\.sessionID))
        let done = sessions.filter { live in !refused.contains { $0.pid == live.pid } }
        if !refused.isEmpty { error = "\(refused.count) need you, so they weren't snoozed." }
        if !done.isEmpty { desk.offer("Snoozed \(done.count)") { [weak self] in done.forEach { self?.wake($0) } } }
    }

    func quitPicked() {
        running(desk.picked).filter { $0.kind.map { $0 == "interactive" } ?? true }.forEach(quit)
        desk.picked = []
    }

    var pickedRunning: Int { running(desk.picked).count }
}

/// What can be done to the rows picked, at the foot of the list.
struct PickedBar: View {
    let model: SessionStore
    @State private var quitting = false
    var body: some View {
        let running = model.pickedRunning
        let past = model.desk.picked.count - running
        HStack(spacing: 8) {
            Text("\(model.desk.picked.count) selected").font(.callout.weight(.medium)).monospacedDigit()
            Spacer(minLength: 4)
            Menu {
                Button("Pin") { model.pinPicked() }
                if past > 0 { Button(past == model.desk.picked.count ? "Archive" : "Archive \(past) Ended") { model.archivePicked() } }
                if running > 0 {
                    Menu("Snooze") {
                        ForEach(SessionSnooze.Choice.offered, id: \.self) { choice in Button(choice.title) { model.snoozePicked(choice) } }
                    }
                    Divider()
                    Button("Quit \(running) Running…", role: .destructive) { quitting = true }
                }
            } label: { Text("Actions") }
                .menuStyle(.borderlessButton).fixedSize()
            Button { model.desk.picked = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                .help("Clear the selection (esc)").accessibilityLabel("Clear the selection")
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
        .confirmationDialog("Quit \(running) sessions?", isPresented: $quitting) {
            Button("Quit \(running) Sessions", role: .destructive) { model.quitPicked() }
        }
    }
}

/// The line that says what was just done to the list, with Undo while it can be taken back.
struct UndoToast: View {
    let desk: SessionDesk
    let item: ListUndo
    var body: some View {
        HStack(spacing: 10) {
            Text(item.text).font(.callout).lineLimit(1)
            if item.undo != nil {
                Button("Undo") { withAnimation(Ink.ease) { desk.takeBack() } }.buttonStyle(.link).fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 12).frame(height: 30)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.line))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .task(id: item.id) {
            try? await Task.sleep(for: SessionDesk.undoTime)
            if !Task.isCancelled, desk.undo?.id == item.id { withAnimation(Ink.ease) { desk.undo = nil } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Undo") { desk.takeBack() }
    }
}

// MARK: Settled

extension SessionStore {
    /// History split into what is current and what has settled: a conversation nothing has been added to for a week
    /// moves under Earlier without being filed. Search, filters and ⌘K still find it.
    func history(now: Double = Date().timeIntervalSince1970) -> (recent: [ProjectGroup], earlier: [ProjectGroup]) {
        guard showsSections else { return (groups, []) }
        var recent: [ProjectGroup] = [], earlier: [ProjectGroup] = []
        for group in groups {
            let split = Self.settle(group.rows.map { ($0.session.id, $0.session.lastTs, $0.depth) }, now: now)
            let old = group.rows.filter { split.contains($0.session.id) }
            let new = group.rows.filter { !split.contains($0.session.id) }
            if !new.isEmpty { recent.append(ProjectGroup(path: group.path, name: group.name, rows: new)) }
            if !old.isEmpty { earlier.append(ProjectGroup(path: "earlier:" + group.path, name: group.name, rows: old)) }
        }
        return (recent, earlier)
    }

    /// The ids that have settled. A fork stays with the conversation it came from, so a tree is never split.
    nonisolated static func settle(_ rows: [(id: String, last: Double?, depth: Int)], now: Double) -> Set<String> {
        var settled = Set<String>(), tree: [(id: String, last: Double?)] = []
        func close() {
            // The tree is as current as its newest conversation.
            let newest = tree.compactMap(\.last).max()
            if Settled.isSettled(lastMessage: newest, pinned: false, running: false, now: now) { settled.formUnion(tree.map(\.id)) }
            tree = []
        }
        for row in rows {
            if row.depth == 0 { close() }
            tree.append((row.id, row.last))
        }
        close()
        return settled
    }
}

struct EarlierFold: View {
    let model: SessionStore
    let count: Int
    @State private var hovering = false
    var body: some View {
        let open = model.desk.earlierOpen
        Button { withAnimation(Ink.ease) { model.desk.earlierOpen.toggle() } } label: {
            HStack(spacing: 6) {
                Text("Earlier").font(.subheadline.weight(.semibold)).textCase(.uppercase).tracking(0.6).foregroundStyle(hovering ? .secondary : .tertiary)
                Text(count.formatted()).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.quaternary)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 0 : -90))
            }
            .padding(.horizontal, 8).padding(.top, 20).padding(.bottom, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Ink.glide) { hovering = inside } }
        .accessibilityLabel("Earlier, \(count) conversations")
        .accessibilityValue(open ? "Shown" : "Folded")
    }
}
