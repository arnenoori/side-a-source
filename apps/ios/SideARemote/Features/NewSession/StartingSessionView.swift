import SideAProtocol
import SwiftUI

/// Pushed as Start returns: "Starting…" until the session the Mac hosts in `name` appears, then its
/// transcript in place.
struct StartingSessionView: View {
    /// As Start returned it; the Mac's later word on it replaces it.
    let started: HostedSession
    /// Where a reply that never went is put back: the session it was meant for.
    var giveBackTo: SessionKey? = nil
    @Environment(AppModel.self) private var model

    private var name: String { started.name }
    private var hosted: HostedSession? { model.tools.hosted[name] ?? started }
    private var session: RemoteSession? {
        model.sessions.sessions.first { $0.hosted == name } ?? hosted?.sessionID.flatMap(model.sessions.session)
    }

    var body: some View {
        Group {
            if let session {
                TranscriptView(sessionID: session.id)
            } else {
                starting
            }
        }
        .onChange(of: session?.id, initial: true) { _, id in arrived(id) }
        .onChange(of: session?.hosted) { _, _ in arrived(session?.id) }
        .onChange(of: hosted?.alive) { _, alive in
            if alive == false { model.transcripts.dropFirstPrompt(name, giveBackTo: giveBackTo) }
        }
    }

    /// The session is listed: its first prompt shows in its transcript, and a reply that waited for Continue is typed
    /// once the row says Side A hosts it.
    private func arrived(_ id: SessionKey?) {
        guard let id, let session else { return }
        model.transcripts.carryFirstPrompt(name, to: id)
        if session.hosted == name, let text = model.transcripts.takeWaitingReply(name) { model.reply(text, to: id) }
    }

    private var starting: some View {
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
                    ShowOnMacButton(name: name).buttonStyle(.glass)
                }
            }
        }
        // What was asked, at once, where the transcript will put it.
        .safeAreaInset(edge: .top) {
            if let prompt = model.transcripts.firstPrompts[name] ?? model.transcripts.waitingReplies[name] {
                OutgoingBubble(sessionID: name, turn: prompt)
                    .padding(.horizontal, Space.m)
                    .padding(.top, Space.s)
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

private struct OpenTerminalButton: View {
    let name: String
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        Button("Open Terminal", systemImage: "terminal") { actions.on(model).openTerminal(name) }.buttonStyle(.glass)
    }
}
