import SideAProtocol
import SwiftUI

/// Sessions as a phone stack, or on a full-width iPad as a split view: the list in the sidebar, the session beside it.
enum RootLayout: Equatable {
    case stack, split

    /// iPhone keeps its stack in every orientation, a Plus or Max in landscape too; iPad narrowed by Split View or
    /// Slide Over gets the same stack.
    static func of(idiom: UIUserInterfaceIdiom, width: UserInterfaceSizeClass?) -> RootLayout {
        idiom == .pad && width == .regular ? .split : .stack
    }
}

/// The split view reads the Sessions tab's one path, so deep links, the waiting accessory and a resize between
/// layouts all see the same thing: its first route is the detail column's root, the rest is pushed over it.
enum SplitPath {
    static func root(_ path: [Route]) -> Route? { path.first }

    static func pushed(_ path: [Route]) -> [Route] { Array(path.dropFirst()) }

    /// The detail column's stack changed under its root.
    static func replacing(pushed: [Route], in path: [Route]) -> [Route] {
        guard let root = path.first else { return [] }
        return [root] + pushed
    }

    /// A row picked in the sidebar. Picking the one already open keeps what's pushed over it.
    static func selecting(_ route: Route?, in path: [Route]) -> [Route] {
        guard let route else { return [] }
        return route == path.first ? path : [route]
    }

    /// The sidebar row to highlight. A hosted session opened while starting keeps its page, which turns into the
    /// transcript in place, and its row is the session's once the Mac lists it.
    static func selection(_ path: [Route], session: (_ hosted: String, _ mac: String) -> SessionKey?) -> Route? {
        guard let root = path.first else { return nil }
        if case .starting(let name, let mac) = root, let id = session(name, mac) { return .session(id, mac: mac) }
        return root
    }

    /// The waiting capsule under the sidebar: whenever something waits, except while the session it's about is open
    /// beside the list, where the request is already its last item.
    static func showsWaiting(for session: SessionKey?, path: [Route]) -> Bool {
        guard let session, case .session(let open, _)? = path.first else { return true }
        return open != session
    }

    /// The row `step` places from `current` in the sidebar's order; the first or last when nothing in it is open.
    static func neighbor(of current: Route?, in order: [Route], step: Int) -> Route? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return step > 0 ? order.first : order.last }
        let next = index + step
        return order.indices.contains(next) ? order[next] : nil
    }
}

extension EnvironmentValues {
    /// The split view's sidebar selection; nil in the phone stack, where a row pushes.
    @Entry var sidebarSelection: Binding<Route?>?
    /// The iPad's detail column, beside the sidebar: its pages keep the tab bar, which is the way to the other tabs.
    @Entry var keepsTabBar = false
    /// The window's size, safe areas included. On iPad a window can be far smaller than the screen; sheets read it
    /// from here, since their own geometry is the sheet's.
    @Entry var windowSize = CGSize(width: 390, height: 844)
    /// The window is regular width. A form sheet's own size class is compact even then, so it reads this.
    @Entry var windowIsRegular = false
}

extension View {
    /// Measures the window this view fills and hands its size down as `windowSize`.
    func measuresWindow() -> some View { modifier(MeasuresWindow()) }
}

private struct MeasuresWindow: ViewModifier {
    @State private var size: CGSize?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { proxy in
                let insets = proxy.safeAreaInsets
                return CGSize(width: proxy.size.width + insets.leading + insets.trailing, height: proxy.size.height + insets.top + insets.bottom)
            } action: { size = $0 }
            .environment(\.windowSize, size ?? EnvironmentValues().windowSize)
    }
}

/// A Sessions row: pushes on iPhone; in the iPad's sidebar it opens beside the list and stays marked while open,
/// with a quiet tint rather than the list's solid highlight.
struct SidebarLink<Label: View>: View {
    let route: Route
    @ViewBuilder var label: Label
    @Environment(\.sidebarSelection) private var selection

    init(_ route: Route, @ViewBuilder label: () -> Label) {
        self.route = route
        self.label = label()
    }

    var body: some View {
        if let selection {
            // A button, not the list's own selection: a selected row in a focused list turns its text white for a
            // solid highlight, unreadable on the tint.
            Button { selection.wrappedValue = route } label: {
                HStack {
                    label
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
                // The list highlighted its own rows under the pointer; a plain button doesn't.
                .contentShape(.hoverEffect, .rect(cornerRadius: 12).inset(by: -Space.xs))
                .hoverEffect(.highlight)
            }
            .buttonStyle(.plain)
            .listRowBackground(selection.wrappedValue == route ? SelectedRow() : nil)
            .accessibilityAddTraits(selection.wrappedValue == route ? .isSelected : [])
        } else {
            NavigationLink(value: route) { label }
        }
    }
}

private struct SelectedRow: View {
    var body: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)
            Color.accentColor.opacity(0.14)
        }
    }
}

extension View {
    /// A page pushed over a list takes the screen; in the iPad's detail column the tab bar stays.
    func hidesTabBar() -> some View { modifier(HidesTabBar()) }
}

private struct HidesTabBar: ViewModifier {
    @Environment(\.keepsTabBar) private var keepsTabBar

    func body(content: Content) -> some View {
        content.toolbarVisibility(keepsTabBar ? .automatic : .hidden, for: .tabBar)
    }
}

extension AppRoot {
    /// Open sessions as the sidebar lists them, for the next and previous session: pinned first, then needs you,
    /// working and ready. Idle rows fold away, so they're left out.
    var sidebarOrder: [Route] {
        visible.flatMap { mac in
            let pinned = [SessionPhase.needsYou, .working, .ready, .idle].flatMap { mac.sessions.rows($0) }.filter(mac.tools.isPinned)
            let rest = [SessionPhase.needsYou, .working, .ready].flatMap { mac.sessions.groups($0).flatMap(\.rows) }.filter { !mac.tools.isPinned($0) }
            return (pinned + rest).map { Route.session($0.id, mac: mac.macID) }
        }
    }

    /// The session a hosted name became, once its Mac lists it.
    func session(hosted name: String, mac: String) -> SessionKey? {
        model(for: mac)?.sessions.sessions.first { $0.hosted == name }?.id
    }
}

/// The Sessions tab: `stack` as it is on iPhone, or the split view on a full-width iPad.
struct AdaptiveSessions<Stack: View>: View {
    @Binding var path: [Route]
    /// What the waiting capsule opens: the approval sheet, or a question's session.
    let openWaiting: (RemoteRequest) -> Void
    @ViewBuilder var stack: Stack
    @Environment(\.horizontalSizeClass) private var width

    var body: some View {
        switch RootLayout.of(idiom: UIDevice.current.userInterfaceIdiom, width: width) {
        case .stack: stack
        case .split: SessionsSplit(path: $path, openWaiting: openWaiting)
        }
    }
}

private struct SessionsSplit: View {
    @Binding var path: [Route]
    let openWaiting: (RemoteRequest) -> Void
    @Environment(AppRoot.self) private var root
    @State private var columns = NavigationSplitViewVisibility.all

    private var selection: Binding<Route?> {
        Binding { SplitPath.selection(path, session: root.session(hosted:mac:)) } set: { path = SplitPath.selecting($0, in: path) }
    }

    private var canStart: Bool { root.canStartSession }

    private var pushed: Binding<[Route]> {
        Binding { SplitPath.pushed(path) } set: { path = SplitPath.replacing(pushed: $0, in: path) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SessionsView()
                .environment(\.sidebarSelection, selection)
                // Inline, the title shares one row with the Mac chip and the buttons and is cut to "S…".
                .navigationBarTitleDisplayMode(.large)
                // Rows end above the capsule instead of showing through its glass; at the top they still pass
                // under the title bar.
                .mask { Rectangle().ignoresSafeArea(edges: .top) }
                // The phone's capsule spans the window over the tab bar; here it belongs to the list.
                // New Session sits beside it: in the column's own bar the system folds it into an overflow menu once
                // the bar runs short, as it does in a narrow window or at the larger text sizes.
                .safeAreaInset(edge: .bottom) {
                    let waits = !root.waiting.isEmpty && SplitPath.showsWaiting(for: root.waiting.first?.sessionID, path: path)
                    if waits || canStart {
                        HStack(spacing: Space.s) {
                            if waits {
                                WaitingAccessory(open: openWaiting)
                                    .frame(height: 48)
                                    .glassEffect(.regular.interactive(), in: .capsule)
                            } else {
                                Spacer()
                            }
                            if canStart { NewSessionButton() }
                        }
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.xs)
                    }
                }
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 440)
                // The rows are buttons, so the list has no selection to move: with the sidebar focused, ↑ and ↓ open
                // the row above or below, as a selecting list would. The open row's tint shows where it is.
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    let step = press.key == .upArrow ? -1 : 1
                    guard let route = SplitPath.neighbor(of: selection.wrappedValue, in: root.sidebarOrder, step: step) else { return .ignored }
                    selection.wrappedValue = route
                    return .handled
                }
        } detail: {
            NavigationStack(path: pushed) {
                Group {
                    if let route = SplitPath.root(path) {
                        RoutePage(route: route, path: path)
                    } else {
                        ContentUnavailableView {
                            Label { Text("No Session Selected") } icon: { DiscGlyph(size: 44) }
                        }
                    }
                }
                .routeDestinations(path: path)
            }
            // Another session is a new page, not the last one's stack with its scroll position.
            .id(SplitPath.root(path))
            .environment(\.keepsTabBar, true)
        }
        .onAppear(perform: restoreOpen)
        .onChange(of: SplitPath.root(path)) { _, route in
            guard !root.model.isDemo else { return }
            switch route {
            case .session(let id, let mac)?: ListPrefsStore.setOpen((mac, id))
            case nil: ListPrefsStore.setOpen(nil)
            default: break
            }
        }
    }

    /// Once a launch: the session open at the last one, if its Mac still lists it. Later, a window widened from the
    /// stack keeps what that stack showed.
    private static var restored = false

    private func restoreOpen() {
        guard !Self.restored else { return }
        Self.restored = true
        guard path.isEmpty, !root.model.isDemo, let open = ListPrefsStore.open(),
              root.model(for: open.mac)?.sessions.session(open.session) != nil else { return }
        path = [.session(open.session, mac: open.mac)]
    }
}

/// The sidebar's New Session: the sheet ⌘N opens, which the list presents.
private struct NewSessionButton: View {
    @Environment(KeyRequests.self) private var keys

    var body: some View {
        Menu {
            QuickSessionsMenu { keys.newSession += 1 }
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 19, weight: .medium))
                .frame(width: 48, height: 48)
                .contentShape(.circle)
                .hoverEffect(.highlight)
        } primaryAction: {
            keys.newSession += 1
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityHint("Touch and hold for recent sessions")
        .foregroundStyle(.tint)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("New Session")
        .needsMac()
    }
}
