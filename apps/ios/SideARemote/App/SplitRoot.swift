import SideAProtocol
import SwiftUI

enum RootLayout: Equatable {
    case stack, split

    static func of(idiom: UIUserInterfaceIdiom, width: UserInterfaceSizeClass?) -> RootLayout {
        idiom == .pad && width == .regular ? .split : .stack
    }
}

enum SplitPath {
    static func root(_ path: [Route]) -> Route? { path.first }

    static func pushed(_ path: [Route]) -> [Route] { Array(path.dropFirst()) }

    static func replacing(pushed: [Route], in path: [Route]) -> [Route] {
        guard let root = path.first else { return [] }
        return [root] + pushed
    }

    static func selecting(_ route: Route?, in path: [Route]) -> [Route] {
        guard let route else { return [] }
        return route == path.first ? path : [route]
    }

    static func selection(_ path: [Route], session: (_ hosted: String, _ mac: String) -> SessionKey?) -> Route? {
        guard let root = path.first else { return nil }
        if case .starting(let name, let mac) = root, let id = session(name, mac) { return .session(id, mac: mac) }
        return root
    }

    static func showsWaiting(for session: SessionKey?, path: [Route]) -> Bool {
        guard let session, case .session(let open, _)? = path.first else { return true }
        return open != session
    }

    static func neighbor(of current: Route?, in order: [Route], step: Int) -> Route? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return step > 0 ? order.first : order.last }
        let next = index + step
        return order.indices.contains(next) ? order[next] : nil
    }
}

extension EnvironmentValues {
    @Entry var sidebarSelection: Binding<Route?>?
    @Entry var keepsTabBar = false
    @Entry var windowSize = CGSize(width: 390, height: 844)
    /// The window is regular width. A form sheet's own size class is compact even then, so it reads this.
    @Entry var windowIsRegular = false
}

extension View {
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
    func hidesTabBar() -> some View { modifier(HidesTabBar()) }
}

private struct HidesTabBar: ViewModifier {
    @Environment(\.keepsTabBar) private var keepsTabBar

    func body(content: Content) -> some View {
        content.toolbarVisibility(keepsTabBar ? .automatic : .hidden, for: .tabBar)
    }
}

extension AppRoot {
    var sidebarOrder: [Route] {
        visible.flatMap { mac in
            let pinned = [SessionPhase.needsYou, .working, .ready, .idle].flatMap { mac.sessions.rows($0) }.filter(mac.tools.isPinned)
            let rest = [SessionPhase.needsYou, .working, .ready].flatMap { mac.sessions.groups($0).flatMap(\.rows) }.filter { !mac.tools.isPinned($0) }
            return (pinned + rest).map { Route.session($0.id, mac: mac.macID) }
        }
    }

    func session(hosted name: String, mac: String) -> SessionKey? {
        model(for: mac)?.sessions.sessions.first { $0.hosted == name }?.id
    }
}

struct AdaptiveSessions<Stack: View>: View {
    @Binding var path: [Route]
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

    private static var restored = false

    private func restoreOpen() {
        guard !Self.restored else { return }
        Self.restored = true
        guard path.isEmpty, !root.model.isDemo, let open = ListPrefsStore.open(),
              root.model(for: open.mac)?.sessions.session(open.session) != nil else { return }
        path = [.session(open.session, mac: open.mac)]
    }
}

private struct NewSessionButton: View {
    @Environment(KeyRequests.self) private var keys

    var body: some View {
        NewSessionMenuButton(hint: "Touch and hold for recent sessions") {
            QuickSessionsMenu { keys.newSession += 1 }
        }
        .foregroundStyle(.tint)
        .needsMac()
    }
}
