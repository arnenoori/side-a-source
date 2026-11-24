import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

struct SessionsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppRoot.self) private var root
    @AppStorage(PrefKey.notificationsCardDone) private var notificationsCardDone = false
    @State private var notificationsUndetermined = false
    @AppStorage(PrefKey.notificationsOffDone) private var notificationsOffDone = false
    @State private var notificationsDenied = false
    @Environment(\.scenePhase) private var scenePhase

    private var model: AppModel { root.current }
    private var everyMac: Bool { root.macs.count > 1 && root.shown == nil }

    private var showsNotificationsCard: Bool {
        notificationsUndetermined && !notificationsCardDone
            && (!model.isDemo || ProcessInfo.processInfo.arguments.contains("--setup-cards"))
    }
    private var showsNotificationsOff: Bool { notificationsDenied && !notificationsOffDone && !model.isDemo }
    @State private var showsMac: MacPick?
    @State private var query = ""
    @State private var searching = false
    @Environment(\.searchHistory) private var searchHistory
    @Environment(KeyRequests.self) private var keys: KeyRequests?

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
            if !query.isEmpty, !noMatches, let searchHistory {
                Button("Search History", systemImage: "clock.arrow.circlepath") { searchHistory(query) }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer, prompt: "Title, project, branch, model")
        .environment(\.defaultMinListRowHeight, 28)
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
                ContentUnavailableView {
                    Label("No Sessions for \u{201C}\(query)\u{201D}", systemImage: "magnifyingglass")
                } actions: {
                    if let searchHistory { Button("Search History") { searchHistory(query) }.buttonStyle(.glassProminent) }
                }
            } else if everyMac {
                if root.macs.allSatisfy({ $0.sessions.sessions.isEmpty && $0.tools.unlisted(in: []).isEmpty && $0.mac.shown == .live }) {
                    ContentUnavailableView {
                        Label { Text("No sessions running") } icon: { DiscGlyph(size: 44) }
                    } actions: {
                        if canStart { Button("New Session") { keys?.newSession += 1 }.buttonStyle(.glassProminent) }
                    }
                }
            } else if model.mac.shown == .offline(.macAsleep) {
                ContentUnavailableView {
                    Label("\(model.mac.name) Is Asleep", systemImage: "moon.zzz")
                } actions: {
                    if let engine = model.link?.engine {
                        Button("Try Again") { Task { await engine.reconnectNow() } }.buttonStyle(.glassProminent)
                    }
                }
                .background(Color(.systemGroupedBackground))
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
            ToolbarItem(placement: .topBarTrailing) { Button("Search", systemImage: "magnifyingglass") { searching = true } }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) { SheetButton(sheet: .settings) }
        }
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


    private var layout: [String] {
        root.visible.flatMap { mac in
            [SessionPhase.needsYou, .working, .ready, .idle].flatMap { phase in
                mac.sessions.sorted(mac.sessions.rows(phase)).map {
                    "\(mac.macID)/\(mac.tools.snooze(of: $0) != nil ? "snoozed" : mac.tools.isPinned($0) ? "pinned" : "\(phase)")/\($0.id)"
                }
            }
        }
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

    private var pinned: [RemoteSession] {
        [SessionPhase.needsYou, .working, .ready, .idle].flatMap { model.sessions.sorted(model.sessions.rows($0)) }
            .filter { model.tools.isPinned($0) && model.tools.snooze(of: $0) == nil && model.sessions.matches($0, query) }
    }

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
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !searching { QuitIdleButton(title: "Quit Idle") }
                }
                .contextMenu { if !searching { QuitIdleButton(title: "Quit Idle…") } }
            }
        }
    }
}

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

struct MacChip: View {
    let mac: MacConnection
    let action: () -> Void
    @Environment(\.sidebarSelection) private var sidebarSelection
    @State private var slow = false

    private var showsProgress: Bool {
        mac.shown == .connecting && slow
    }

    var body: some View {
        Button(action: action) {
            MacChipLabel(state: mac.shown, symbol: mac.symbol) {
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

struct MacsMenu: View {
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
                    Label(mac.mac.name, systemImage: mac.mac.symbol)
                    Text(mac.mac.status)
                }
            }
        } label: {
            MacChipLabel(state: state, symbol: shown.wrappedValue.flatMap(root.model(for:))?.mac.symbol ?? "display.2") {
                Text(shown.wrappedValue.flatMap(root.model(for:))?.mac.name ?? "All \(root.macs.map(\.mac.kind).shared.titlePlural)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .contentTransition(.opacity)
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

    private var state: MacConnection.State {
        let states = (allowsAll ? root.visible : [root.current]).map(\.mac.shown)
        if states.allSatisfy({ $0 == .live }) { return .live }
        if let offline = states.first(where: \.isOffline) { return offline }
        return states.first { if case .reconnecting = $0 { true } else { false } } ?? .connecting
    }
}

/// A dropped connection reads in the chip itself; a banner for a blip of a second made the list jump.
struct MacChipLabel<Name: View>: View {
    let state: MacConnection.State
    let symbol: String
    @ViewBuilder var name: Name

    var body: some View {
        HStack(spacing: 6) {
            if case .reconnecting = state {
                ProgressView().controlSize(.mini)
                Text("Reconnecting…").font(.subheadline.weight(.medium)).lineLimit(1)
            } else {
                Image(systemName: symbol).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                name
                ConnectionDot(state: state)
            }
        }
    }
}

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
