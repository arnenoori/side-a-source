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
    /// Past this long, Starting… is probably a prompt or a stuck screen only the terminal shows: Open Terminal leads.
    @State private var stuck = false

    static let stuckAfter = Duration.seconds(30)

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
        // A row alone doesn't say the agent took the handoff: one that fails its sign-in or its resume is listed, then ends.
        .onChange(of: tookFirstTurn, initial: true) { _, took in
            if took, let giveBackTo { model.handoffs.move(giveBackTo, .arrived(name: name)) }
        }
        .onChange(of: ended) { _, ended in
            guard ended else { return }
            model.transcripts.dropFirstPrompt(name, giveBackTo: giveBackTo)
            // A handoff's message went as part of its first prompt, so it isn't a first prompt here to give back.
            if let giveBackTo, let message = model.handoffs.move(giveBackTo, .ended(name: name)) {
                model.transcripts.restore(message, in: giveBackTo)
                model.transcripts.notice("It ended before it took this.", in: giveBackTo)
            }
        }
    }

    /// At work, or a user turn from about the handoff on: a resumed conversation already has older ones.
    private var tookFirstTurn: Bool {
        guard let session else { return false }
        if [.working, .waiting, .finished].contains(session.status) { return true }
        let since = (model.handoffs.started[name]?.at ?? .infinity) - 30
        return model.transcripts.messages[session.id]?.contains { $0.role == .user && ($0.at ?? 0) >= since } == true
    }

    /// The Mac drops a dead pane without ever marking it, so a row it listed and then removed, with no session in its
    /// place, is the process ending too.
    private var ended: Bool {
        session == nil && (hosted?.alive == false || model.tools.dropped.contains(name))
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
            if ended {
                ContentUnavailableView("Process Exited", systemImage: "xmark.octagon",
                                       description: Text(hosted?.exitStatus.map { "It ended with status \($0)." } ?? "It ended before it started."))
            } else {
                // Laid out as the transcript will be: what was asked, then the line where the answer will start.
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.m) {
                        if let prompt = model.transcripts.firstPrompts[name] ?? model.transcripts.waitingReplies[name] {
                            OutgoingBubble(sessionID: name, turn: prompt)
                        }
                        HStack(spacing: Space.s) {
                            ProgressView().controlSize(.small)
                            Text("Starting").foregroundStyle(.secondary)
                        }
                        .padding(.leading, Space.xs)
                        .accessibilityElement(children: .combine)
                        if model.tools.can(.terminal) || model.tools.can(.hostedShow) {
                            VStack(alignment: .leading, spacing: Space.s) {
                                if model.tools.can(.terminal) { OpenTerminalButton(name: name, prominent: stuck) }
                                ShowOnMacButton(name: name).buttonStyle(.glass)
                            }
                        }
                    }
                    .padding(Space.m)
                }
            }
        }
        // A trust dialog or a stuck screen before the session starts: the card says so.
        .safeAreaInset(edge: .bottom) {
            if let attention = model.tools.attention[name] {
                AttentionCard(attention: attention).padding(Space.m)
            }
        }
        .task {
            try? await Task.sleep(for: Self.stuckAfter)
            stuck = true
        }
        .navigationTitle(hosted?.project ?? "New Session")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .sessionActions()
    }
}

private struct OpenTerminalButton: View {
    let name: String
    let prominent: Bool
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        let open = Button("Open Terminal", systemImage: "terminal") { actions.on(model).openTerminal(name) }
        if prominent { open.buttonStyle(.glassProminent) } else { open.buttonStyle(.glass) }
    }
}
