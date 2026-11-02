import SideAProtocol
import SwiftUI

/// Pushed as Start returns: "Starting…" until the session the Mac hosts in `name` appears, then its
/// transcript in place.
struct StartingSessionView: View {
    /// As Start returned it; the Mac's later word on it replaces it.
    let started: HostedSession
    @Environment(AppModel.self) private var model

    private var name: String { started.name }
    private var hosted: HostedSession? { model.tools.hosted[name] ?? started }
    private var session: RemoteSession? {
        model.sessions.sessions.first { $0.hosted == name } ?? hosted?.sessionID.flatMap(model.sessions.session)
    }

    var body: some View {
        if let session {
            TranscriptView(sessionID: session.id)
        } else {
            Group {
                if let hosted, !hosted.alive {
                    ContentUnavailableView("Process Exited", systemImage: "xmark.octagon",
                                           description: Text(hosted.exitStatus.map { "It ended with status \($0)." } ?? "It ended before it started."))
                } else {
                    ContentUnavailableView {
                        Label { Text("Starting…") } icon: { ProgressView().controlSize(.large) }
                    } description: {
                        if let hosted { Text(hosted.project).font(.callout.monospaced()) }
                    } actions: {
                        if model.tools.can(.terminal) {
                            OpenTerminalButton(name: name)
                        }
                    }
                }
            }
            // A trust dialog or a stuck screen before the session starts: the card says so.
            .safeAreaInset(edge: .bottom) {
                if let attention = model.tools.attention[name] {
                    AttentionCard(attention: attention).padding(Space.m)
                }
            }
            .navigationTitle(hosted?.project ?? "New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.hidden, for: .tabBar)
            .sessionActions()
        }
    }
}

private struct OpenTerminalButton: View {
    let name: String
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        Button("Open Terminal", systemImage: "terminal") { actions.on(model).openTerminal(name) }.buttonStyle(.glass)
    }
}
