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
    @State private var showsNewSession = false
    /// The hosted session New Session just started, pushed until its transcript takes over.
    @State private var started: Started?
    @State private var idleExpanded = false

    private struct Started: Identifiable, Hashable {
        let session: HostedSession
        let mac: String
        var id: String { session.name }
    }

    /// Any Mac that can start one.
    private var canStart: Bool { root.visible.contains { $0.tools.can(.hosted) } }

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
                    MacSessions(idleExpanded: $idleExpanded, header: true) { showsMac = MacPick(id: mac.macID) }
                        .environment(mac)
                }
            } else {
                MacSessions(idleExpanded: $idleExpanded, header: false) {}
                    .environment(model)
            }
        }
        .listStyle(.insetGrouped)
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
            if everyMac {
                if root.macs.allSatisfy({ $0.sessions.sessions.isEmpty && $0.mac.state == .live }) {
                    ContentUnavailableView {
                        Label { Text("No sessions running") } icon: { DiscGlyph(size: 44) }
                    } actions: {
                        if canStart { Button("New Session") { showsNewSession = true }.buttonStyle(.glassProminent) }
                    }
                }
            } else if case .offline(let reason) = model.mac.state, reason.needsPairing, model.sessions.sessions.isEmpty {
                PairAgainView(reason: reason, mac: model.mac.name)
                    .background(Color(.systemGroupedBackground))
            } else if model.sessions.sessions.isEmpty, model.mac.state == .live {
                ContentUnavailableView {
                    Label { Text("No sessions running") } icon: { DiscGlyph(size: 44) }
                } actions: {
                    if model.tools.can(.hosted) {
                        Button("New Session") { showsNewSession = true }.buttonStyle(.glassProminent)
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
            if canStart {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Session", systemImage: "square.and.pencil") { showsNewSession = true }
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Picker("Group By", systemImage: "rectangle.3.group", selection: groupBy) {
                        ForEach(GroupBy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Toggle("Show Idle Sessions", systemImage: "circle.dashed", isOn: $idleExpanded)
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
        .sheet(isPresented: $showsNewSession) {
            NewSessionSheet { started = Started(session: $0, mac: $1.macID) }
                .environment(model)
        }
        .navigationDestination(item: $started) { started in
            StartingSessionView(started: started.session)
                .environment(root.model(for: started.mac) ?? model)
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
                mac.sessions.rows(phase).map { "\(mac.macID)/\(mac.tools.isPinned($0) ? "pinned" : "\(phase)")/\($0.id)" }
            }
        }
    }

    /// One grouping for every Mac's list.
    private var groupBy: Binding<GroupBy> {
        Binding { model.sessions.groupBy } set: { value in for mac in root.macs { mac.sessions.groupBy = value } }
    }
}

struct MacPick: Identifiable {
    let id: String
}

/// One Mac's part of Sessions: its banners, then needs-you, working and ready, then the idle fold. With
/// several Macs, its name heads it; tapping the name opens the Mac's sheet, as the chip does with one Mac.
private struct MacSessions: View {
    @Binding var idleExpanded: Bool
    let header: Bool
    let status: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var pairingAgain = false

    var body: some View {
        if header {
            Section {
                if model.sessions.sessions.isEmpty, model.mac.state == .live {
                    Text("No sessions running").foregroundStyle(.secondary)
                }
            } header: {
                Button(action: status) {
                    HStack(spacing: 6) {
                        ConnectionDot(state: model.mac.state)
                        Text(model.mac.name)
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(model.mac.name), \(model.mac.status)")
                .accessibilityHint("Shows the Mac's status")
            }
            .headerProminence(.increased)
        }
        IncidentBanner()
        banners
        pinnedSection
        ForEach([SessionPhase.needsYou, .working, .ready], id: \.self) { phase in
            let groups = unpinned(model.sessions.groups(phase))
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
    }

    /// Under the navigation bar as an inset row, never a toast; the content below keeps its age.
    @ViewBuilder private var banners: some View {
        switch model.mac.state {
        case .reconnecting:
            // The chip says "Reconnecting…"; the row joins once the data is a minute old.
            if let age = Formatting.age(of: model.mac.lastSeen) {
                Section { BannerRow(symbol: "arrow.trianglehead.2.clockwise", text: "\(age) · Reconnecting…") }
            }
        case .offline(let reason) where reason.needsPairing:
            Section {
                BannerRow(symbol: reason == .keyChanged ? "key.slash" : "iphone.slash", text: reason.message(mac: model.mac.name),
                          age: Formatting.age(of: model.mac.lastSeen))
                Button("Pair Again", systemImage: "qrcode.viewfinder") { pairingAgain = true }
            }
            .pairAgain($pairingAgain, mac: model.mac.name)
        case .offline(let reason):
            Section {
                BannerRow(symbol: reason.symbol, text: reason.message(mac: model.mac.name),
                          age: Formatting.age(of: model.mac.lastSeen))
                if reason == .tailscaleOff {
                    Button("Open Tailscale", systemImage: "arrow.up.forward.app") { openURL(Tailscale.installed ? Tailscale.app : Tailscale.appStore) }
                }
                if let link = model.link {
                    NavigationLink { TestConnectionView(link: link) } label: { Label("Test Connection", systemImage: "stethoscope") }
                }
                if reason.offersPairAgain {
                    Button("Pair Again", systemImage: "qrcode.viewfinder") { pairingAgain = true }
                }
            }
            .pairAgain($pairingAgain, mac: model.mac.name)
        case .live where model.tools.needsKeys:
            Section {
                BannerRow(symbol: "faceid", text: "Pair this iPhone again with \(model.mac.name) to approve, change settings or open the terminal from it.")
                Button("Pair Again", systemImage: "qrcode.viewfinder") { pairingAgain = true }
            }
            .pairAgain($pairingAgain, mac: model.mac.name)
        default:
            EmptyView()
        }
    }

    /// Pinned from a row's long-press, whatever they're doing, above the rest; each keeps its status glyph.
    private var pinned: [RemoteSession] {
        [SessionPhase.needsYou, .working, .ready, .idle].flatMap { model.sessions.rows($0) }.filter(model.tools.isPinned)
    }

    private func unpinned(_ groups: [(title: String?, rows: [RemoteSession])]) -> [(title: String?, rows: [RemoteSession])] {
        groups.map { ($0.title, $0.rows.filter { !model.tools.isPinned($0) }) }.filter { !$0.rows.isEmpty || $0.title == nil }
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
        let idle = model.sessions.rows(.idle).filter { !model.tools.isPinned($0) }
        if !idle.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $idleExpanded) {
                    ForEach(unpinned(model.sessions.groups(.idle)), id: \.title) { group in
                        if let title = group.title { ProjectSubheader(title: title, grouping: model.sessions.groupBy) }
                        ForEach(group.rows) { SessionLink(session: $0) }
                    }
                } label: {
                    Text("^[\(idle.count) idle session](inflect: true)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    QuitIdleButton(title: "Quit Idle")
                }
                .contextMenu { QuitIdleButton(title: "Quit Idle…") }
            }
        }
    }
}

/// The row, pushed into its transcript. A row isn't the same object as a screen, so a plain push.
private struct SessionLink: View {
    let session: RemoteSession
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationLink(value: Route.session(session.id, mac: model.macID)) {
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
        default: "wifi.exclamationmark"
        }
    }

    func message(mac: String) -> String {
        switch self {
        case .tailscaleOff: "Tailscale is off on this iPhone"
        case .macUnreachable: "Can't reach \(mac). It may be asleep or Side A is closed."
        case .macAsleep: "\(mac) is asleep"
        case .relayRefused: RelayRefused().localizedDescription
        case .revoked: "This iPhone was removed from \(mac)"
        case .keyChanged: "\(mac) has a new security key, so this iPhone has to pair again."
        case .incompatible(let installed?): "Update Side A on \(mac) from \(installed) to use it with this iPhone"
        case .incompatible(nil): "Update Side A on \(mac) to use it with this iPhone"
        case .appOutdated: "Update Side A Remote to use it with \(mac)"
        }
    }
}

/// The glass capsule naming the Mac, with its connection dot.
struct MacChip: View {
    let mac: MacConnection
    let action: () -> Void
    /// A first connect that's quick shows nothing; after 600 ms the chip says it's working on it.
    @State private var slow = false

    private var showsProgress: Bool {
        switch mac.state {
        case .reconnecting: true
        case .connecting: slow
        default: false
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ConnectionDot(state: mac.state)
                Text(mac.name).font(.subheadline.weight(.medium))
                if showsProgress {
                    Image(systemName: "ellipsis").font(.caption).symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
                }
            }
            .padding(.horizontal, 6)
            .fixedSize()
        }
        .task(id: mac.state == .connecting) {
            slow = false
            guard mac.state == .connecting else { return }
            try? await Task.sleep(for: .milliseconds(600))
            slow = true
        }
        .accessibilityLabel("\(mac.name), \(mac.status)")
        .accessibilityHint("Shows the Mac's status")
    }

}

/// The chip with several Macs: which ones a tab shows, each with its status under its name.
struct MacsMenu: View {
    /// Search reads one Mac's history at a time, so it has no All Macs.
    var allowsAll = true
    @Environment(AppRoot.self) private var root
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: Binding<String?> {
        Binding { allowsAll ? root.shown : root.current.macID } set: { root.shown = $0 }
    }

    var body: some View {
        Menu {
            // Toggles rather than a picker: a menu shows a toggle's subtitle, the Mac's status.
            if allowsAll { pick(nil) { Text("All Macs") } }
            ForEach(root.macs, id: \.macID) { mac in
                pick(mac.macID) {
                    Text(mac.mac.name)
                    Text(mac.mac.status)
                }
            }
        } label: {
            HStack(spacing: 6) {
                ConnectionDot(state: state)
                Text(shown.wrappedValue.flatMap(root.model(for:))?.mac.name ?? "All Macs")
                    .font(.subheadline.weight(.medium))
                    .contentTransition(.opacity)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .fixedSize()
            .animation(Motion.smooth(reduceMotion), value: state)
        }
        .accessibilityLabel(shown.wrappedValue.flatMap(root.model(for:)).map { "\($0.mac.name), \($0.mac.status)" } ?? "All Macs")
        .accessibilityHint("Chooses which Macs to show")
    }

    /// The menu's toggles tick on their own, so picking a Mac adds no haptic.
    private func pick(_ id: String?, @ViewBuilder label: () -> some View) -> some View {
        Toggle(isOn: Binding { shown.wrappedValue == id } set: { if $0 { withAnimation(Motion.smooth(reduceMotion)) { shown.wrappedValue = id } } }, label: label)
    }

    /// Green only when every shown Mac is; red when any is offline.
    private var state: MacConnection.State {
        let states = (allowsAll ? root.visible : [root.current]).map(\.mac.state)
        if states.allSatisfy({ $0 == .live }) { return .live }
        if let offline = states.first(where: { if case .offline = $0 { true } else { false } }) { return offline }
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
