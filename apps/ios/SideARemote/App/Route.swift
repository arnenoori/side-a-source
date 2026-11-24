import SideAProtocol
import SwiftUI

/// Every destination a tab's `NavigationStack` can push. Notification taps, widgets and deep links
/// resolve to one of these.
enum Route: Hashable {
    /// A session on one Mac: two Macs can't be told apart by a session id alone.
    case session(SessionKey, mac: String)
    case step(SessionKey, TranscriptTool)
    /// `session`: where the diff's file can be opened, when that's known.
    case diff(FileDiff, sourceID: String, session: SessionKey? = nil)
    /// Everything one turn of a session changed.
    case turnDiff(SessionKey, turn: String)
    case code(CodePayload)
    /// `tool`: the step that wrote it, whose text shows while the file loads.
    case file(SessionKey, TranscriptTool?, path: String)
    case images(SessionKey, [ImageRef], start: String)
    /// An account as one Mac sees it: the same account can be signed in on two.
    case account(String, mac: String)
    /// The sessions stopped on a limit, on one Mac.
    case waiting(mac: String)
    /// A hosted session with no row yet, by its tmux name: "Starting…" until its transcript takes over.
    case starting(String, mac: String)
    /// One of a session's subagents, read-only.
    case subagent(SubagentRef)

    /// The session a page is about, which says which Mac it's on.
    var session: SessionKey? {
        switch self {
        case .session(let id, _), .step(let id, _), .file(let id, _, _), .images(let id, _, _), .turnDiff(let id, _): id
        case .subagent(let ref): ref.parent
        case .diff(_, _, let id?): id
        default: nil
        }
    }
}

/// A subagent of `parent`, by the id its Task/Agent call names.
struct SubagentRef: Hashable {
    let parent: SessionKey
    let agentID: String
    let title: String
    /// Where its messages sit in `TranscriptStore`, beside the parent's.
    var key: SessionKey { "\(parent)\(Self.separator)\(agentID)" }
    private static let separator = "~agent~"

    init(parent: SessionKey, agentID: String, title: String) { self.parent = parent; self.agentID = agentID; self.title = title }

    /// From a `key`; nil for a session's own key.
    init?(key: SessionKey) {
        let parts = key.components(separatedBy: Self.separator)
        guard parts.count == 2 else { return nil }
        self.init(parent: parts[0], agentID: parts[1], title: "")
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
    /// A row or tile that a pushed page zooms out of.
    @ViewBuilder func zoomSource(_ id: String) -> some View {
        modifier(ZoomSource(id: id))
    }

    /// The pushed page side of the same zoom; none for nil.
    @ViewBuilder func zoomDestination(_ id: String?) -> some View {
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
    let id: String?
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace, let id { content.navigationTransition(.zoom(sourceID: id, in: namespace)) } else { content }
    }
}

/// Pushes shared by every tab.
struct RouteDestinations: ViewModifier {
    /// The tab's stack, so a page inside a session's transcript stays on that session's Mac.
    var path: [Route] = []

    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { RoutePage(route: $0, path: path) }
    }
}

/// One route's page with the model of the Mac it's about: pushed, or the root of the iPad's detail column.
struct RoutePage: View {
    let route: Route
    var path: [Route] = []
    @Environment(AppRoot.self) private var root
    @Environment(AppModel.self) private var model

    var body: some View {
        page(route).environment(owner(route))
    }

    private func owner(_ route: Route) -> AppModel {
        switch route {
        case .account(_, let mac), .session(_, let mac), .waiting(let mac), .starting(_, let mac): if let owner = root.model(for: mac) { return owner }
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
        case .diff(let diff, let source, let session): DiffPage(diff: diff, sessionID: session).zoomDestination(source)
        case .turnDiff(let session, let turn): TurnDiffPage(sessionID: session, turnID: turn)
        case .code(let payload): CodePage(payload: payload).zoomDestination(payload.id)
        case .file(let session, let tool, let path): FilePage(sessionID: session, tool: tool, path: path).zoomDestination("file-\(tool?.id ?? path)")
        case .images(_, let images, let start): ImageViewer(images: images, start: start)
        case .account(let id, _): AccountDetailView(accountID: id)
        case .waiting: WaitingSessionsView()
        case .starting(let name, _): StartingRoute(name: name)
        case .subagent(let ref): TranscriptView(sessionID: ref.key, subagent: ref)
        }
    }
}

/// `Route.starting`, from the hosted session the Mac last listed under that name.
private struct StartingRoute: View {
    let name: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if let hosted = model.tools.hosted[name] {
            StartingSessionView(started: hosted)
        } else {
            ContentUnavailableView("Session Ended", systemImage: "xmark.octagon")
        }
    }
}

extension View {
    func routeDestinations(path: [Route] = []) -> some View { modifier(RouteDestinations(path: path)) }
}
