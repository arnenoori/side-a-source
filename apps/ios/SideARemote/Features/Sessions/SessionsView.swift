import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

struct SessionsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppRoot.self) private var root
    @AppStorage("setup.notificationsCardDone") private var notificationsCardDone = false
    @State private var notificationsUndetermined = false
    @AppStorage("setup.notificationsOffDone") private var notificationsOffDone = false
    @State private var notificationsDenied = false
    @Environment(\.scenePhase) private var scenePhase

    /// The Mac Sessions shows, or with several and none picked, the first one, for what's about a single Mac.
    private var model: AppModel { root.current }
    /// Several Macs and none picked: each Mac gets its own block under its name.
    private var everyMac: Bool { root.macs.count > 1 && root.shown == nil }

    /// Once, after pairing a real Mac; the demo doesn't ask for permissions.
    private var showsNotificationsCard: Bool {
        notificationsUndetermined && !notificationsCardDone
            && (!model.isDemo || ProcessInfo.processInfo.arguments.contains("--setup-cards"))
    }
    /// Denied in iOS Settings: the way back, until it's turned on or waved away.
    private var showsNotificationsOff: Bool { notificationsDenied && !notificationsOffDone && !model.isDemo }
    @State private var showsMac: MacPick?
    @State private var query = ""
    /// On iPad's split view, the row open beside the list; a row there selects rather than pushes.
    @Environment(\.sidebarSelection) private var sidebarSelection
    @Environment(KeyRequests.self) private var keys: KeyRequests?

    /// Any Mac that can start one.
    private var canStart: Bool { root.canStartSession }

    var body: some View {
        List {
            if root.reviewing {
                // App Review's demo never passes for a real Mac.
                Label("Demo · nothing is connected", systemImage: "play.rectangle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if showsNotificationsCard {
                NotificationsCard { withAnimation(Motion.smooth(reduceMotion)) { notificationsCardDone = true } }
            }
            if showsNotificationsOff {
                NotificationsOffSection { withAnimation(Motion.smooth(reduceMotion)) { notificationsOffDone = true } }
            }
            if everyMac {
                ForEach(root.macs, id: \.macID) { mac in
                    MacSessions(query: query, header: true) { showsMac = MacPick(id: mac.macID) }
                        .environment(mac)
                }
            } else {
                MacSessions(query: query, header: false) {}
                    .environment(model)
            }
        }
        .listStyle(.insetGrouped)
        // Live sessions only; past conversations are the Search tab's.
        .searchable(text: $query, placement: .navigationBarDrawer, prompt: "Title, project, branch, model")
        .environment(\.defaultMinListRowHeight, 28)
        // Rows keep their ids across phases, so a change slides them between sections rather than fading out and in.
        .animation(Motion.move(reduceMotion), value: layout)
        .task(id: scenePhase) {
            notificationsUndetermined = await NotificationsCard.undetermined()
            notificationsDenied = await NotificationsCard.denied()
        }
        .task(id: root.macs.map { "\($0.macID):\($0.tools.can(.history))" }) {
            for mac in root.macs { await mac.tools.loadPast() }
        }
        .navigationTitle("Sessions")
        .overlay {
            if noMatches {
                ContentUnavailableView.search(text: query)
            } else if everyMac {
                if root.macs.allSatisfy({ $0.sessions.sessions.isEmpty && $0.tools.unlisted(in: []).isEmpty && $0.mac.shown == .live }) {
                    ContentUnavailableView {
                        Label { Text("No sessions running") } icon: { DiscGlyph(size: 44) }
                    } actions: {
                        if canStart { Button("New Session") { keys?.newSession += 1 }.buttonStyle(.glassProminent) }
                    }
                }
            } else if case .offline(let reason) = model.mac.shown, reason.needsPairing, model.sessions.sessions.isEmpty {
                PairAgainView(reason: reason, mac: model.mac.name)
                    .background(Color(.systemGroupedBackground))
            } else if model.sessions.sessions.isEmpty, model.tools.unlisted(in: []).isEmpty, model.mac.shown == .live {
                ContentUnavailableView {
                    Label { Text("No sessions running") } icon: { DiscGlyph(size: 44) }
                } actions: {
                    if model.tools.can(.hosted) {
                        Button("New Session") { keys?.newSession += 1 }.buttonStyle(.glassProminent)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if root.macs.count > 1 {
                    MacsMenu()
                } else {
                    MacChip(mac: model.mac) { showsMac = MacPick(id: model.macID) }
                }
            }
            // In the iPad sidebar it sits at the column's foot, where the bar can't fold it into an overflow menu.
            if canStart, sidebarSelection == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        QuickSessionsMenu { keys?.newSession += 1 }
                    } label: {
                        Label("New Session", systemImage: "square.and.pencil")
                    } primaryAction: {
                        keys?.newSession += 1
                    }
                    .menuOrder(.fixed)
                    .accessibilityHint("Touch and hold for recent sessions")
                    .needsMac()
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Picker("Group By", systemImage: "rectangle.3.group", selection: choice(\.groupBy)) {
                        ForEach(GroupBy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Picker("Sort By", systemImage: "arrow.up.arrow.down", selection: choice(\.sortBy)) {
                        ForEach(SortBy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        // A fresh snapshot from each Mac shown; one that dropped tries again now rather than at its next retry.
        .refreshable {
            await withTaskGroup { group in
                for mac in root.visible {
                    guard let engine = mac.link?.engine else { continue }
                    group.addTask {
                        await engine.reconnectNow()
                        try? await engine.refresh()
                    }
                }
            }
        }
        .sheet(item: $showsMac) { pick in
            if let mac = root.model(for: pick.id) { MacSheet().environment(mac) }
        }
        .sessionActions()
        .environment(model)
        .accessibilityRotor("Needs you", entries: root.visible.flatMap { $0.sessions.rows(.needsYou) }, entryID: \.id, entryLabel: \.title)
    }


    /// Each row's place, by Mac and phase.
    private var layout: [String] {
        root.visible.flatMap { mac in
            [SessionPhase.needsYou, .working, .ready, .idle].flatMap { phase in
                // A pinned row has its own section, so a pin slides it up rather than fading it.
                mac.sessions.sorted(mac.sessions.rows(phase)).map {
                    "\(mac.macID)/\(mac.tools.snooze(of: $0) != nil ? "snoozed" : mac.tools.isPinned($0) ? "pinned" : "\(phase)")/\($0.id)"
                }
            }
        }
    }

    /// Each Mac keeps its own; with All Macs shown, a pick applies to every one.
    private func choice<Value>(_ key: ReferenceWritableKeyPath<SessionsStore, Value>) -> Binding<Value> {
        Binding { model.sessions[keyPath: key] } set: { value in for mac in root.visible { mac.sessions[keyPath: key] = value } }
    }

    private var noMatches: Bool {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return root.visible.allSatisfy { mac in
            !mac.sessions.sessions.contains { mac.sessions.matches($0, query) }
                && !mac.tools.unlisted(in: mac.sessions.sessions).contains { MacSessions.matches($0, query, prompt: mac.transcripts.firstPrompts[$0.name]?.text) }
        }
    }
}

struct MacPick: Identifiable {
    let id: String
}

/// One Mac's part of Sessions: its banners, then needs-you, working and ready, then the idle fold. With
/// several Macs, its name heads it; tapping the name opens the Mac's sheet, as the chip does with one Mac.
private struct MacSessions: View {
    let query: String
    let header: Bool
    let status: () -> Void
    @Environment(AppModel.self) private var model
    @State private var snoozedExpanded = false

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    static func matches(_ hosted: HostedSession, _ query: String, prompt: String?) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            [hosted.project, prompt, hosted.agent.title].compactMap { $0 }.contains { $0.localizedStandardContains(word) }
        }
    }

    private func shown(_ session: RemoteSession) -> Bool {
        !model.tools.isPinned(session) && model.tools.snooze(of: session) == nil && model.sessions.matches(session, query)
    }

    var body: some View {
        if header {
            Section {
                if model.sessions.sessions.isEmpty, model.tools.unlisted(in: []).isEmpty, model.mac.state == .live {
                    Text("No sessions running").foregroundStyle(.secondary)
                }
            } header: {
                Button(action: status) {
                    HStack(spacing: 6) {
                        ConnectionDot(state: model.mac.shown)
                        Text(model.mac.name)
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(model.mac.name), \(model.mac.status)")
                .accessibilityHint("Shows \(model.mac.kind.the(model.mac.name))'s status")
            }
            .headerProminence(.increased)
        }
        IncidentBanner()
        ConnectionBanners()
        UpdateMacBanner()
        pinnedSection
        startingSection
        ForEach([SessionPhase.needsYou, .working, .ready], id: \.self) { phase in
            let groups = model.sessions.groups(phase, where: shown)
            if !groups.allSatisfy(\.rows.isEmpty) {
                Section {
                    ForEach(groups, id: \.title) { group in
                        if let title = group.title, groups.count > 1 {
                            ProjectSubheader(title: title, grouping: model.sessions.groupBy)
                        }
                        ForEach(group.rows) { session in
                            SessionLink(session: session)
                        }
                    }
                } header: {
                    // Hierarchical .secondary resolves against the header's own grey and fades; name the colour.
                    Text(phase.title)
                        .foregroundStyle(phase == .needsYou ? Color.amberText : Color(.secondaryLabel))
                }
            }
        }
        idleSection
        snoozedSection
    }

    /// Pinned from a row's long-press, whatever they're doing, above the rest; each keeps its status glyph.
    private var pinned: [RemoteSession] {
        [SessionPhase.needsYou, .working, .ready, .idle].flatMap { model.sessions.sorted(model.sessions.rows($0)) }
            .filter { model.tools.isPinned($0) && model.tools.snooze(of: $0) == nil && model.sessions.matches($0, query) }
    }

    /// Out of the way until each wakes, folded under the rest; what wakes one sends it back to its place.
    @ViewBuilder private var snoozedSection: some View {
        let snoozed = [SessionPhase.working, .ready, .idle].flatMap { model.sessions.sorted(model.sessions.rows($0)) }
            .filter { model.tools.snooze(of: $0) != nil && model.sessions.matches($0, query) }
        if !snoozed.isEmpty {
            Section {
                DisclosureGroup(isExpanded: searching ? .constant(true) : $snoozedExpanded) {
                    ForEach(snoozed) { SessionLink(session: $0) }
                } label: {
                    Text("^[\(snoozed.count) snoozed session](inflect: true)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Started a moment ago, here or on the Mac, and not listed by the agent yet: in the list at once, not after it registers.
    @ViewBuilder private var startingSection: some View {
        let starting = model.tools.unlisted(in: model.sessions.sessions).filter {
            Self.matches($0, query, prompt: model.transcripts.firstPrompts[$0.name]?.text)
        }
        if !starting.isEmpty {
            Section {
                ForEach(starting, id: \.name) { hosted in
                    SidebarLink(Route.starting(hosted.name, mac: model.macID)) {
                        StartingRow(hosted: hosted, prompt: model.transcripts.firstPrompts[hosted.name]?.text)
                    }
                    .id("starting-\(hosted.name)")
                }
            } header: {
                Text("Starting").foregroundStyle(Color(.secondaryLabel))
            }
        }
    }

    @ViewBuilder private var pinnedSection: some View {
        let pinned = pinned
        if !pinned.isEmpty {
            Section {
                ForEach(pinned) { SessionLink(session: $0) }
            } header: {
                Text("Pinned").foregroundStyle(Color(.secondaryLabel))
            }
        }
    }

    @ViewBuilder private var idleSection: some View {
        let idle = model.sessions.rows(.idle).filter(shown)
        if !idle.isEmpty {
            Section {
                // A search opens the fold without changing how it's kept.
                DisclosureGroup(isExpanded: searching ? .constant(true) : Bindable(model.sessions).idleExpanded) {
                    ForEach(model.sessions.groups(.idle, where: shown), id: \.title) { group in
                        if let title = group.title { ProjectSubheader(title: title, grouping: model.sessions.groupBy) }
                        ForEach(group.rows) { SessionLink(session: $0) }
                    }
                } label: {
                    Text("^[\(idle.count) idle session](inflect: true)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                // It quits every idle session, so not while a search hides some.
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !searching { QuitIdleButton(title: "Quit Idle") }
                }
                .contextMenu { if !searching { QuitIdleButton(title: "Quit Idle…") } }
            }
        }
    }
}

/// A hosted session before its agent has a row: the folder, what was asked, and how long ago.
private struct StartingRow: View {
    let hosted: HostedSession
    let prompt: String?; @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            ProgressView().controlSize(.small).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(prompt ?? hosted.project).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: Space.xs)
                    ElapsedText(since: Date(timeIntervalSince1970: hosted.createdAt))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text([hosted.agent.title, hosted.project, hosted.macAttached ? "Tab on \(model.mac.kind.isMac ? "Mac" : model.mac.name)" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting, \(prompt ?? hosted.project), \(hosted.agent.title) in \(hosted.project)")
    }
}

/// The row, pushed into its transcript. A row isn't the same object as a screen, so a plain push.
private struct SessionLink: View {
    let session: RemoteSession
    @Environment(AppModel.self) private var model

    var body: some View {
        SidebarLink(Route.session(session.id, mac: model.macID)) {
            SessionRow(session: session)
        }
        .id(session.id)
    }
}

struct ProjectSubheader: View {
    let title: String
    let grouping: GroupBy

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: grouping == .project ? "folder" : "person.crop.circle").imageScale(.small)
            Text(title)
        }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .listRowInsets(EdgeInsets(top: Space.s, leading: Space.m, bottom: Space.xxs, trailing: Space.m))
            .listRowSeparator(.hidden, edges: .bottom)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            .accessibilityAddTraits(.isHeader)
    }
}

struct BannerRow: View {
    let symbol: String
    let text: String
    /// `Formatting.age`, "Updated 12 min ago": stale data says how old it is.
    var age: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                if let age { Text(age).font(.footnote).foregroundStyle(.tertiary) }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// Revoked, or the Mac's key changed: nothing on this Mac can be trusted until it pairs again.
/// Shown in place of the list when there's nothing stale to keep visible.
struct PairAgainView: View {
    let reason: MacConnection.Offline
    let mac: String
    @State private var pairing = false

    var body: some View {
        ContentUnavailableView {
            Label(reason == .keyChanged ? "New Security Key" : "Removed from \(mac)",
                  systemImage: reason == .keyChanged ? "key.slash" : "iphone.slash")
        } description: {
            Text(reason.message(mac: mac))
        } actions: {
            Button("Pair Again") { pairing = true }
                .buttonStyle(.glassProminent)
        }
        .pairAgain($pairing, mac: mac)
    }
}

extension View {
    /// Pair Again goes straight to the scanner. The old pairing stays, stale, until the new one succeeds and `replaces` it on the Mac.
    func pairAgain(_ isPresented: Binding<Bool>, mac: String) -> some View {
        modifier(PairAgainCover(isPresented: isPresented, mac: mac))
    }
}

private struct PairAgainCover: ViewModifier {
    @Binding var isPresented: Bool
    let mac: String

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented) {
            ScannerScreen(title: "Pair Again with \(mac)")
        }
    }
}

extension MacConnection.Offline {
    var symbol: String {
        switch self {
        case .tailscaleOff: "network.slash"
        case .macAsleep: "moon.zzz"
        case .relayRefused: "iphone.slash"
        case .noNetwork: "wifi.slash"
        default: "wifi.exclamationmark"
        }
    }

    func message(mac: String) -> String {
        switch self {
        case .tailscaleOff: "Tailscale is off on this \(ThisDevice.kind)"
        case .macUnreachable: "Can't reach \(mac). It may be asleep or Side A is closed."
        case .macAsleep: "\(mac) is asleep"
        case .relayRefused: RelayRefused().localizedDescription
        case .noNetwork: "This \(ThisDevice.kind) has no internet connection"
        case .revoked: "This \(ThisDevice.kind) was removed from \(mac)"
        case .keyChanged: "\(mac) has a new security key, so this \(ThisDevice.kind) has to pair again."
        case .incompatible(let installed?): "Update Side A on \(mac) from \(installed) to use it with this \(ThisDevice.kind)"
        case .incompatible(nil): "Update Side A on \(mac) to use it with this \(ThisDevice.kind)"
        case .appOutdated: "Update Side A Remote to use it with \(mac)"
        }
    }
}

/// The glass capsule naming the Mac, with its connection dot.
struct MacChip: View {
    let mac: MacConnection
    let action: () -> Void
    @Environment(\.sidebarSelection) private var sidebarSelection
    /// A first connect that's quick shows nothing; after 600 ms the chip says it's working on it.
    @State private var slow = false

    private var showsProgress: Bool {
        switch mac.shown {
        case .reconnecting: true
        case .connecting: slow
        default: false
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ConnectionDot(state: mac.shown)
                MacChipName(name: mac.name, inSidebar: sidebarSelection != nil)
                if showsProgress {
                    Image(systemName: "ellipsis").font(.caption).symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
                }
            }
            .padding(.horizontal, 6)
            .fixedSize(horizontal: sidebarSelection == nil, vertical: false)
            // The iPad sidebar's toolbar shares its column with New Session, which the bar would otherwise fold into
            // an overflow menu; the name gives way instead.
            .frame(maxWidth: sidebarSelection == nil ? nil : 150, alignment: .leading)
        }
        // As the bar's own buttons do, past the largest standard size the chip stays put.
        .chipTypeSize()
        .task(id: mac.state == .connecting) {
            slow = false
            guard mac.state == .connecting else { return }
            try? await Task.sleep(for: .milliseconds(600))
            slow = true
        }
        .accessibilityLabel("\(mac.name), \(mac.status)")
        .accessibilityHint("Shows \(mac.kind.the(mac.name))'s status")
    }

}

/// The chip with several Macs: which ones a tab shows, each with its status under its name.
struct MacsMenu: View {
    /// Search reads one Mac's history at a time, so it has no All Macs.
    var allowsAll = true
    @Environment(AppRoot.self) private var root
    @Environment(\.sidebarSelection) private var sidebarSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: Binding<String?> {
        Binding { allowsAll ? root.shown : root.current.macID } set: { root.shown = $0 }
    }

    var body: some View {
        Menu {
            // Toggles rather than a picker: a menu shows a toggle's subtitle, the Mac's status.
            if allowsAll { pick(nil) { Text("All \(root.macs.map(\.mac.kind).shared.titlePlural)") } }
            ForEach(root.macs, id: \.macID) { mac in
                pick(mac.macID) {
                    Text(mac.mac.name)
                    Text(mac.mac.status)
                }
            }
        } label: {
            HStack(spacing: 6) {
                ConnectionDot(state: state)
                Text(shown.wrappedValue.flatMap(root.model(for:))?.mac.name ?? "All \(root.macs.map(\.mac.kind).shared.titlePlural)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            // As MacChip: in the iPad sidebar the name gives way so New Session keeps its place in the bar.
            .fixedSize(horizontal: sidebarSelection == nil, vertical: false)
            .frame(maxWidth: sidebarSelection == nil ? nil : 150, alignment: .leading)
            .animation(Motion.smooth(reduceMotion), value: state)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel(shown.wrappedValue.flatMap(root.model(for:)).map { "\($0.mac.name), \($0.mac.status)" } ?? "All \(root.macs.map(\.mac.kind).shared.titlePlural)")
        .accessibilityHint("Chooses which \(root.macs.map(\.mac.kind).shared.plural) to show")
    }

    /// The menu's toggles tick on their own, so picking a Mac adds no haptic.
    private func pick(_ id: String?, @ViewBuilder label: () -> some View) -> some View {
        Toggle(isOn: Binding { shown.wrappedValue == id } set: { if $0 { withAnimation(Motion.smooth(reduceMotion)) { shown.wrappedValue = id } } }, label: label)
    }

    /// Green only when every shown Mac is; red when any is offline.
    private var state: MacConnection.State {
        let states = (allowsAll ? root.visible : [root.current]).map(\.mac.shown)
        if states.allSatisfy({ $0 == .live }) { return .live }
        if let offline = states.first(where: \.isOffline) { return offline }
        return .connecting
    }
}

/// The connection's dot: filled green when live, a red ring offline, a grey ring in between.
struct ConnectionDot: View {
    let state: MacConnection.State

    var body: some View {
        switch state {
        case .live: Circle().fill(.green).frame(width: 7, height: 7)
        case .offline: Circle().strokeBorder(.red, lineWidth: 1.5).frame(width: 7, height: 7)
        default: Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 7, height: 7)
        }
    }
}

extension MacConnection.State {
    var title: String {
        switch self {
        case .live: "Connected"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .offline: "Offline"
        }
    }
}

/// Controls that talk to the Mac: enabled while reconnecting (the outbox holds the action), off
/// while offline with the reason as their hint.
private struct NeedsMac: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if case .offline(let reason) = model.mac.state {
            content
                .disabled(true)
                .accessibilityHint(reason.message(mac: model.mac.name))
        } else {
            content
        }
    }
}

extension View {
    func needsMac() -> some View { modifier(NeedsMac()) }
}
