import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

struct RootView: View {
    @Environment(AppRoot.self) private var root
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.paired {
                MainTabs()
            } else {
                WelcomeView()
            }
        }
        .id(root.epoch)
        .onAppear { Launch.drawn() }
    }
}

enum AppTab: Hashable { case sessions, accounts }

enum AppSheet: String, Identifiable {
    case settings, search
    var id: String { rawValue }
}

struct LinkLanding: Equatable {
    var tab: AppTab
    var sessions: [Route]?
    var accounts: [Route]?
    var sheet: AppSheet?
}

extension EnvironmentValues {
    @Entry var showSheet: ((AppSheet) -> Void)?
    @Entry var searchHistory: ((String) -> Void)?
}

struct SheetButton: View {
    let sheet: AppSheet
    @Environment(\.showSheet) private var show

    var body: some View {
        Button(sheet == .settings ? "Settings" : "Search", systemImage: sheet == .settings ? "gearshape" : "magnifyingglass") { show?(sheet) }
    }
}

extension DeepLink {
    func landing(mac current: String) -> LinkLanding {
        switch self {
        case .session(let id, let mac), .compose(let id, let mac): LinkLanding(tab: .sessions, sessions: [.session(id, mac: mac)])
        case .request: LinkLanding(tab: .sessions)
        case .mac: LinkLanding(tab: .sessions, sessions: [])
        case .accounts: LinkLanding(tab: .accounts)
        case .account(let id): LinkLanding(tab: .accounts, accounts: [.account(id, mac: current)])
        case .search: LinkLanding(tab: .sessions, sheet: .search)
        case .settings: LinkLanding(tab: .sessions, sheet: .settings)
        }
    }
}

enum DeepLink: Equatable {
    case session(SessionKey, mac: String), request(RequestID, mac: String), mac(String), accounts, account(String), search, settings
    case compose(SessionKey, mac: String)

    init?(_ url: URL) {
        guard url.scheme == "sidea-remote", let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "session" where parts.count == 2: self = .session(parts[1], mac: parts[0])
        case "compose" where parts.count == 2: self = .compose(parts[1], mac: parts[0])
        case "mac" where parts.count == 1: self = .mac(parts[0])
        case "request" where parts.count == 2: self = .request(parts[1], mac: parts[0])
        case "accounts" where parts.count == 1: self = .account(parts[0])
        case "accounts": self = .accounts
        case "search": self = .search
        case "settings": self = .settings
        default: return nil
        }
    }
}

enum LinkAction: Equatable {
    case openDemo, confirmDemo, pair(PairingClient.Invitation), deep(DeepLink), none

    static func of(_ url: URL, pairedMacs: Int) -> LinkAction {
        if ReviewDemo.matches(url) { return pairedMacs == 0 ? .openDemo : .confirmDemo }
        if let invitation = PairingLink.invitation(url) { return .pair(invitation) }
        return DeepLink(url).map(LinkAction.deep) ?? .none
    }
}

extension View {
    func demoConfirmation(isPresented: Binding<Bool>, open: @escaping () -> Void) -> some View {
        alert("Open the Demo?", isPresented: isPresented) {
            Button("Open Demo", role: .destructive, action: open)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your \(PairedMac.all().map(\.endpoint.kind).shared.plural) disconnect until you leave the demo.")
        }
    }
}

@Observable
final class ApprovalPresenter {
    nonisolated deinit {}

    var request: RemoteRequest?
    var note: NoteTarget?
}

struct NoteTarget: Identifiable, Hashable {
    let session: SessionKey
    var delivery: Delivery? = .nextStep
    var id: SessionKey { session }
}

struct MainTabs: View {
    @Environment(AppRoot.self) private var root
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .sessions
    @State private var sessionsPath: [Route] = []
    @State private var accountsPath: [Route] = []
    @State private var settingsPath: [SettingsPage] = []
    @State private var showsNewSession = false
    @State private var sheet: AppSheet?
    @State private var approvals = ApprovalPresenter()
    @State private var linked: PairingTarget?
    @State private var awaited: DeepLink?
    @State private var askingDemo = false
    @State private var historyQuery = ""
    @Environment(KeyRequests.self) private var keys
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sessionsZoom
    @Namespace private var accountsZoom
    @Namespace private var searchZoom

    var body: some View {
        TabView(selection: $tab) {
            Tab("Sessions", systemImage: "rectangle.stack", value: .sessions) {
                AdaptiveSessions(path: $sessionsPath, openWaiting: { show($0) }) {
                    NavigationStack(path: $sessionsPath) {
                        SessionsView()
                            .routeDestinations(path: sessionsPath)
                    }
                }
                .environment(\.zoomNamespace, sessionsZoom)
            }
            .badge(root.macs.map(\.requests.open.count).reduce(0, +))

            Tab("Accounts", systemImage: "gauge.with.dots.needle.67percent", value: .accounts) {
                NavigationStack(path: $accountsPath) {
                    AccountsView()
                        .routeDestinations(path: accountsPath)
                }
                .environment(\.zoomNamespace, accountsZoom)
                .readableColumn()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                if showsCompose {
                    ComposeButton()
                        .padding(.trailing, ComposeButton.inset)
                        .padding(.bottom, ComposeButton.lift)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(Motion.snappy(reduceMotion), value: showsCompose)
            .ignoresSafeArea(.keyboard)
        }
        // An iPad window widened past compact keeps the tab bar it had: in the navigation row, over the session's
        // title. Leaving the tab and coming straight back lays the bar out in its own row, as at launch, and unlike
        // building the tab view again it keeps every tab's pages, sheets, terminal and drafts.
        .onChange(of: endedIndex) { _, index in
            if let index { sessionsPath = Array(sessionsPath[..<index]) }
        }
        .onChange(of: width) {
            guard UIDevice.current.userInterfaceIdiom == .pad else { return }
            let current = tab
            tab = current == .sessions ? .accounts : .sessions
            Task { @MainActor in tab = current }
        }
        .environment(\.windowIsRegular, width == .regular)
        .environment(\.showSheet) { sheet = $0 }
        .environment(\.searchHistory) { historyQuery = $0; sheet = .search }
        .sheet(item: $sheet, onDismiss: { settingsPath = []; historyQuery = "" }) { sheet in
            switch sheet {
            case .settings:
                NavigationStack(path: $settingsPath) { SettingsView() }
                    .environment(root.current)
            case .search:
                NavigationStack {
                    HistoryView(query: historyQuery)
                        .routeDestinations()
                        .toolbar {
                            if root.macs.count > 1 {
                                ToolbarItem(placement: .topBarLeading) { MacsMenu() }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", systemImage: "checkmark") { self.sheet = nil }.keyboardShortcut(.cancelAction)
                            }
                        }
                        .environment(root.current)
                }
                .searchable(text: $historyQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Asks, replies, commands")
                .environment(\.zoomNamespace, searchZoom)
                .environment(\.keepsTabBar, true)
                .environment(approvals)
            }
        }
        .environment(\.openSession) { route in
            sheet = nil
            tab = .sessions
            sessionsPath = [route]
        }
        .tabBarMinimizeBehavior(.never)
        .waitingAccessory(showsAccessory) { show($0) }
        .environment(\.zoomNamespace, sessionsZoom)
        .onChange(of: showsAccessory, initial: true) { Pill.shared.aboveAccessory = $1 }
        .environment(approvals)
        .sheet(item: Bindable(approvals).request) { request in
            ApprovalSheet(request: request)
                .environment(root.model(answering: request.id) ?? request.sessionID.flatMap(root.model(owning:)) ?? model)
                .environment(\.zoomNamespace, sessionsZoom)
        }
        .sheet(item: Bindable(approvals).note) { target in
            ComposerSheet(sessionID: target.session, delivery: target.delivery)
                .environment(root.model(owning: target.session) ?? model)
        }
        .sheet(isPresented: $showsNewSession) {
            NewSessionSheet { hosted, mac in
                tab = .sessions
                sessionsPath = [.starting(hosted.name, mac: mac.macID)]
            }
            .environment(model)
            .environment(\.windowIsRegular, width == .regular)
        }
        .onChange(of: keys.newSession) { if root.canStartSession { showsNewSession = true } }
        .onOpenURL(perform: open)
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "--open-session"), index + 1 < arguments.count else { return }
            let id = ["cache": DemoData.ID.cache, "ship": DemoData.ID.ship][arguments[index + 1]] ?? DemoData.ID.lan
            try? await Task.sleep(for: .milliseconds(400))
            if arguments.contains("--compose-sheet") { approvals.note = NoteTarget(session: id) } else { sessionsPath = [.session(id, mac: root.model.macID)] }
        }
        #endif
        .task(id: awaited) { await awaitRequest() }
        .fullScreenCover(item: $linked) { PairingScreen(invitation: $0.invitation) }
        .demoConfirmation(isPresented: $askingDemo) { root.openDemo() }
        .onAppear { keys.actions = commands }
        .onDisappear { keys.actions = nil }
        #if DEBUG
        .task {
            if let url = LaunchLinks.url { open(url) }
            if LaunchLinks.newSession { keys.newSession += 1 }
        }
        #endif
    }

    /// The first page of a session this phone just quit: that page and whatever is pushed over it go, back to the list.
    private var endedIndex: Int? {
        GoneSessions.firstEnded(in: sessionsPath) { id, mac in (root.model(for: mac) ?? model).sessions.ended.contains(id) }
    }

    private var commands: RemoteCommandActions {
        RemoteCommandActions(
            canStart: { root.canStartSession },
            newSession: { tab = .sessions; keys.newSession += 1 },
            show: { tab = $0 },
            sheet: { sheet = $0 },
            previousSession: { openNeighbor(step: -1) },
            nextSession: { openNeighbor(step: 1) })
    }

    private func openNeighbor(step: Int) {
        let current = SplitPath.selection(sessionsPath, session: root.session(hosted:mac:))
        guard let route = SplitPath.neighbor(of: current, in: root.sidebarOrder, step: step) else { return }
        tab = .sessions
        sessionsPath = [route]
    }

    /// `sidea-remote://session/<mac>/<id>`, `request/<mac>/<rid>`, `mac/<mac>`, `accounts`, `accounts/<id>`, `search`, `settings`. Notifications,
    /// widgets and the Live Activity resolve to these too.
    private func open(_ url: URL) {
        let link: DeepLink
        switch root.action(for: url) {
        case .openDemo: return root.openDemo()
        case .confirmDemo: return askingDemo = true
        case .pair(let invitation): return linked = PairingTarget(invitation: invitation)
        case .deep(let deep): link = deep
        case .none: return
        }
        let landing = link.landing(mac: model.macID)
        tab = landing.tab
        sheet = landing.sheet
        if let path = landing.sessions { sessionsPath = path }
        if let path = landing.accounts { accountsPath = path }
        switch link {
        case .request(let id, let mac):
            if let request = (root.model(for: mac) ?? model).requests.request(id) { show(request, mac: mac) } else { awaited = link }
        case .mac(let id):
            if root.macs.count > 1, root.model(for: id) != nil { root.shown = id }
        case .compose(let session, let mac):
            root.takeNotificationDrafts()
            if root.model(for: mac) != nil { approvals.note = NoteTarget(session: session, delivery: nil) }
        default: break
        }
    }

    private func show(_ request: RemoteRequest, mac: String) {
        if let session = request.sessionID { sessionsPath = [.session(session, mac: mac)] }
        if !request.isQuestion { approvals.request = request }
    }

    private func awaitRequest() async {
        guard case .request(let id, let mac) = awaited else { return }
        for _ in 0..<50 {
            if let request = (root.model(for: mac) ?? model).requests.request(id) {
                show(request, mac: mac)
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        awaited = nil
    }

    private func show(_ request: RemoteRequest) {
        if request.isQuestion, let session = request.sessionID {
            tab = .sessions
            sessionsPath = [.session(session, mac: root.model(answering: request.id)?.macID ?? model.macID)]
        } else {
            approvals.request = request
        }
    }

    /// Only where the tab bar is: a pushed page hides the bar, and the wide layout has its own button in the list's column.
    private var showsCompose: Bool {
        guard root.canStartSession, RootLayout.of(idiom: UIDevice.current.userInterfaceIdiom, width: width) != .split else { return false }
        return (tab == .sessions ? sessionsPath : accountsPath).isEmpty
    }

    private var showsAccessory: Bool {
        guard let first = root.waiting.first else { return false }
        if RootLayout.of(idiom: UIDevice.current.userInterfaceIdiom, width: width) == .split { return false }
        // At a tab's root the Sessions badge and the list's own row say it, and the bar there has the compose button beside it.
        guard tab == .sessions else { return false }
        switch sessionsPath.last {
        case nil: return false
        case .session(let id, _)?: return first.sessionID != id
        default: return false
        }
    }
}

private extension View {
    /// 26.1 can hide the accessory when nothing waits; 26.0 gets the same capsule as a bottom inset.
    @ViewBuilder func waitingAccessory(_ shown: Bool, open: @escaping (RemoteRequest) -> Void) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: shown) { WaitingAccessory(open: open) }
        } else {
            safeAreaInset(edge: .bottom) {
                if shown {
                    WaitingAccessory(open: open)
                        .frame(height: 48)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .padding(.horizontal, Space.l)
                }
            }
        }
    }
}

struct WaitingAccessory: View {
    @Environment(AppRoot.self) private var root
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let open: (RemoteRequest) -> Void

    var body: some View {
        let waiting = root.waiting
        if let first = waiting.first {
            Button {
                open(first)
            } label: {
                HStack(spacing: Space.xs) {
                    Circle().fill(Color.amber).frame(width: 8, height: 8)
                    Text(first.accessoryTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .id(first.id)
                        .transition(.opacity)
                    Spacer(minLength: Space.xs)
                    if waiting.count > 1 {
                        Text("+\(waiting.count - 1)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(waiting.count)))
                    }
                }
                .animation(Motion.smooth(reduceMotion), value: waiting.map(\.id))
                .padding(.horizontal, Space.m)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .zoomSource("request-\(first.id)")
            .accessibilityLabel("\(first.sessionID.flatMap { root.model(owning: $0)?.sessions.session($0) }?.title ?? first.title) needs you: \(first.accessoryTitle)" + (waiting.count > 1 ? ", and \(waiting.count - 1) more" : ""))
            .accessibilityHint(first.isQuestion ? "Opens the session" : "Opens the request")
        }
    }
}

extension RemoteRequest {
    var accessoryTitle: String {
        switch action {
        case .question(let questions): RequestText.visible(questions.first?.question ?? headline)
        case .command(let command): RequestText.visible("\(headline) · \(command)")
        case .plan: RequestText.visible(headline)
        default: RequestText.visible(detailFile.isEmpty || headline.contains(detailFile) ? headline : "\(headline) · \(detailFile)")
        }
    }

    private var detailFile: String { (detail as NSString).lastPathComponent }

    var isQuestion: Bool { if case .question = action { true } else { false } }
}
