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
        // Paired the first Mac, left the demo or forgot the last Mac: a new app state, never a carried-over one.
        .id(root.epoch)
        .onAppear { Launch.drawn() }
    }
}

enum AppTab: Hashable { case sessions, accounts, settings, search }

enum DeepLink: Equatable {
    case session(SessionKey, mac: String), request(RequestID, mac: String), mac(String), accounts, account(String), search, settings

    init?(_ url: URL) {
        guard url.scheme == "sidea-remote", let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch host {
        // The Mac id comes first.
        case "session" where parts.count == 2: self = .session(parts[1], mac: parts[0])
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

/// What an incoming link does. A crafted one mustn't stop the Macs' links unasked, so with a Mac paired the review
/// code asks first.
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
            Text("Your Macs disconnect until you leave the demo.")
        }
    }
}

/// Requests the user is being asked to answer, shown as the approval sheet from anywhere.
@Observable
final class ApprovalPresenter {
    nonisolated deinit {}

    var request: RemoteRequest?
    /// The note sheet, opened from a row's swipe, a context menu, the toolbar or the health card.
    var note: NoteTarget?
}

struct NoteTarget: Identifiable, Hashable {
    let session: SessionKey
    var id: SessionKey { session }
}

struct MainTabs: View {
    @Environment(AppRoot.self) private var root
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .sessions
    @State private var sessionsPath: [Route] = []
    @State private var accountsPath: [Route] = []
    @State private var approvals = ApprovalPresenter()
    /// A pairing link opened while paired: Pair Again, or another Mac.
    @State private var linked: PairingTarget?
    @State private var askingDemo = false
    @State private var historyQuery = ""
    @Namespace private var sessionsZoom
    @Namespace private var accountsZoom
    @Namespace private var searchZoom

    var body: some View {
        TabView(selection: $tab) {
            Tab("Sessions", systemImage: "rectangle.stack", value: .sessions) {
                NavigationStack(path: $sessionsPath) {
                    SessionsView()
                        .routeDestinations(path: sessionsPath)
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
            }

            Tab("Settings", systemImage: "gear", value: .settings) {
                NavigationStack {
                    SettingsView()
                }
                .environment(root.current)
            }

            Tab(value: .search, role: .search) {
                NavigationStack {
                    HistoryView(query: historyQuery)
                        .routeDestinations()
                        .toolbar {
                            if root.macs.count > 1 {
                                ToolbarItem(placement: .topBarLeading) { MacsMenu() }
                            }
                        }
                        .environment(root.current)
                }
                // The Search tab is for searching, so the field never hides under the title.
                .searchable(text: $historyQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Asks, replies, commands")
                .environment(\.zoomNamespace, searchZoom)
            }
        }
        // Minimized, the bar split into the current tab and a separate search button; it stays whole.
        .tabBarMinimizeBehavior(.never)
        .waitingAccessory(showsAccessory) { show($0) }
        // Only the Sessions tab shows the accessory; its zoom into the approval sheet shares that stack's namespace.
        .environment(\.zoomNamespace, sessionsZoom)
        .onChange(of: showsAccessory, initial: true) { Pill.shared.aboveAccessory = $1 }
        .environment(approvals)
        .sheet(item: Bindable(approvals).request) { request in
            ApprovalSheet(request: request)
                .environment(root.model(answering: request.id) ?? model)
                // Zooms out of the request card or the accessory, whichever opened it; Sessions is where both live.
                .environment(\.zoomNamespace, sessionsZoom)
        }
        .sheet(item: Bindable(approvals).note) { target in
            MessageSheet(sessionID: target.session)
                .environment(root.model(owning: target.session) ?? model)
        }
        .onOpenURL(perform: open)
        .fullScreenCover(item: $linked) { PairingScreen(invitation: $0.invitation) }
        .demoConfirmation(isPresented: $askingDemo) { root.openDemo() }
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
        switch link {
        case .session(let id, let mac):
            tab = .sessions
            sessionsPath = [.session(id, mac: mac)]
        case .request(let id, let mac):
            guard let request = (root.model(for: mac) ?? model).requests.request(id) else { return }
            tab = .sessions
            if let session = request.sessionID { sessionsPath = [.session(session, mac: mac)] }
            if !request.isQuestion { approvals.request = request }
        case .mac(let id):
            tab = .sessions
            sessionsPath = []
            if root.macs.count > 1, root.model(for: id) != nil { root.shown = id }
        case .accounts:
            tab = .accounts
        case .account(let id):
            tab = .accounts
            accountsPath = [.account(id, mac: model.macID)]
        case .search:
            tab = .search
        case .settings:
            tab = .settings
        }
    }

    /// A question is answered in its card, so it opens its session; everything else opens the sheet
    /// where the user is.
    private func show(_ request: RemoteRequest) {
        if request.isQuestion, let session = request.sessionID {
            tab = .sessions
            sessionsPath = [.session(session, mac: root.model(answering: request.id)?.macID ?? model.macID)]
        } else {
            approvals.request = request
        }
    }

    /// Only on Sessions while something waits: on the list, or in a transcript other than the one
    /// it points to, where the request is already the last item. Never on Accounts, Search or Settings.
    private var showsAccessory: Bool {
        guard let first = root.waiting.first, tab == .sessions else { return false }
        switch sessionsPath.last {
        case nil: return true
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

/// "● Allow Bash · npm test  +2" floating over the tab bar.
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
                // The next request crossfades in as one is answered; the count rolls. No haptic: the push sounded.
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
    /// "Allow Bash · npm test", or the question itself.
    var accessoryTitle: String {
        switch action {
        case .question(let questions): RequestText.visible(questions.first?.question ?? headline)
        case .command(let command): RequestText.visible("\(headline) · \(command)")
        case .plan: RequestText.visible(headline)
        // "Read README.md" already names the file the detail's path ends in.
        default: RequestText.visible(detailFile.isEmpty || headline.contains(detailFile) ? headline : "\(headline) · \(detailFile)")
        }
    }

    private var detailFile: String { (detail as NSString).lastPathComponent }

    var isQuestion: Bool { if case .question = action { true } else { false } }
}
