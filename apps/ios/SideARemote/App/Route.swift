import SideAProtocol
import SwiftUI

/// Every destination a tab's `NavigationStack` can push. Notification taps, widgets and deep links
/// resolve to one of these (M2).
enum Route: Hashable {
    /// A session on one Mac: two Macs can't be told apart by a session id alone.
    case session(SessionKey, mac: String)
    case step(SessionKey, TranscriptTool)
    case diff(FileDiff, sourceID: String)
    /// Everything one turn of a session changed.
    case turnDiff(SessionKey, turn: String)
    case code(CodePayload)
    case file(SessionKey, TranscriptTool, path: String)
    case images(SessionKey, [ImageRef], start: String)
    /// An account as one Mac sees it: the same account can be signed in on two.
    case account(String, mac: String)
    /// The sessions stopped on a limit, on one Mac.
    case waiting(mac: String)
    case settings

    /// The session a page is about, which says which Mac it's on.
    var session: SessionKey? {
        switch self {
        case .session(let id, _), .step(let id, _), .file(let id, _, _), .images(let id, _, _), .turnDiff(let id, _): id
        default: nil
        }
    }
}

struct CodePayload: Hashable {
    let id: String
    let language: String?
    let code: String
}

/// The zoom transitions' shared namespace: the tab's stack owns it, sources and destinations read it.
extension EnvironmentValues {
    @Entry var zoomNamespace: Namespace.ID?
}

extension View {
    /// A row or tile that a pushed page zooms out of (section 6.2).
    @ViewBuilder func zoomSource(_ id: String) -> some View {
        modifier(ZoomSource(id: id))
    }

    /// The pushed page side of the same zoom.
    @ViewBuilder func zoomDestination(_ id: String) -> some View {
        modifier(ZoomDestination(id: id))
    }
}

private struct ZoomSource: ViewModifier {
    let id: String
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace { content.matchedTransitionSource(id: id, in: namespace) } else { content }
    }
}

private struct ZoomDestination: ViewModifier {
    let id: String
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace { content.navigationTransition(.zoom(sourceID: id, in: namespace)) } else { content }
    }
}

/// Pushes shared by every tab. Each page gets the model of the Mac it's about.
struct RouteDestinations: ViewModifier {
    /// The tab's stack, so a page inside a session's transcript stays on that session's Mac.
    var path: [Route] = []
    @Environment(AppRoot.self) private var root
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            page(route).environment(owner(route))
        }
    }

    private func owner(_ route: Route) -> AppModel {
        switch route {
        case .account(_, let mac), .session(_, let mac), .waiting(let mac): if let owner = root.model(for: mac) { return owner }
        default: break
        }
        guard let session = route.session else { return model }
        for case .session(let id, let mac) in path.reversed() where id == session {
            if let owner = root.model(for: mac) { return owner }
        }
        return root.model(owning: session) ?? model
    }

    @ViewBuilder private func page(_ route: Route) -> some View {
        switch route {
        case .session(let id, _): TranscriptView(sessionID: id)
        case .step(let session, let tool): ToolStepPage(sessionID: session, tool: tool).zoomDestination(tool.id)
        case .diff(let diff, let source): DiffPage(diff: diff).zoomDestination(source)
        case .turnDiff(let session, let turn): TurnDiffPage(sessionID: session, turnID: turn)
        case .code(let payload): CodePage(payload: payload).zoomDestination(payload.id)
        case .file(let session, let tool, let path): FilePage(sessionID: session, tool: tool, path: path).zoomDestination("file-\(tool.id)")
        case .images(_, let images, let start): ImageViewer(images: images, start: start)
        case .account(let id, _): AccountDetailView(accountID: id)
        case .waiting: WaitingSessionsView()
        case .settings: SettingsView()
        }
    }
}

extension View {
    func routeDestinations(path: [Route] = []) -> some View { modifier(RouteDestinations(path: path)) }
}
