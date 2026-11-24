import SideAProtocol
import SwiftUI

enum Route: Hashable {
    case session(SessionKey, mac: String)
    case step(SessionKey, TranscriptTool)
    case diff(FileDiff, sourceID: String, session: SessionKey? = nil)
    case turnDiff(SessionKey, turn: String)
    case code(CodePayload)
    case file(SessionKey, TranscriptTool?, path: String)
    case images(SessionKey, [ImageRef], start: String)
    case account(String, mac: String)
    case waiting(mac: String)
    case starting(String, mac: String)
    case subagent(SubagentRef)

    var session: SessionKey? {
        switch self {
        case .session(let id, _), .step(let id, _), .file(let id, _, _), .images(let id, _, _), .turnDiff(let id, _): id
        case .subagent(let ref): ref.parent
        case .diff(_, _, let id?): id
        default: nil
        }
    }
}

struct SubagentRef: Hashable {
    let parent: SessionKey
    let agentID: String
    let title: String
    var key: SessionKey { "\(parent)\(Self.separator)\(agentID)" }
    private static let separator = "~agent~"

    init(parent: SessionKey, agentID: String, title: String) { self.parent = parent; self.agentID = agentID; self.title = title }

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

extension EnvironmentValues {
    @Entry var zoomNamespace: Namespace.ID?
}

extension View {
    @ViewBuilder func zoomSource(_ id: String) -> some View {
        modifier(ZoomSource(id: id))
    }

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

struct RouteDestinations: ViewModifier {
    var path: [Route] = []

    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { RoutePage(route: $0, path: path) }
    }
}

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
