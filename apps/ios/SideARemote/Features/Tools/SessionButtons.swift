import SideAProtocol
import SwiftUI

/// Open Terminal, for a session the Mac hosts and serves a terminal for; nothing otherwise.
struct TerminalButton: View {
    let session: RemoteSession?
    var title = "Terminal"
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let name = session?.hosted, model.tools.can(.terminal) {
            Button(title, systemImage: "terminal") { actions.on(model).openTerminal(name) }
        }
    }
}

/// Continue on iPhone, where the Mac offers it for this session.
struct ContinueButton: View {
    let session: RemoteSession?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session, session.hosted == nil, session.abilities.contains(.continueOnPhone), model.tools.can(.continueOnPhone) {
            Button("Continue on iPhone", systemImage: "iphone") { actions.on(model).continuing = session }
                .disabled(actions.isBusy(session.id))
        }
    }
}

/// Restart Fresh…, where the Mac can draft a handoff.
struct RestartButton: View {
    let session: RemoteSession?
    var title = "Restart Fresh…"
    var symbol: String? = "arrow.trianglehead.counterclockwise"
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session, !session.headless, model.tools.can(.restart) {
            Button { actions.on(model).restarting = session } label: {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
        }
    }
}

/// Quit Session…, asked first; headless sessions are the Mac's own and stay.
struct QuitButton: View {
    let session: RemoteSession?
    var title = "Quit Session…"
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session, !session.headless, model.tools.can(.quit) {
            Button(title, systemImage: "xmark.circle", role: .destructive) { actions.on(model).quitting = session }
                .disabled(actions.isBusy(session.id))
        }
    }
}

/// Preview :port and Stop Server on :port…, for each port the session listens on.
struct PortButtons: View {
    let session: RemoteSession?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session, model.tools.can(.ports) {
            ForEach(session.ports ?? [], id: \.port) { port in
                Button("Preview :\(String(port.port))", systemImage: "safari") {
                    actions.on(model).previewing = SessionActions.Port(session: session.id, port: port.port)
                }
                Button("Stop Server on :\(String(port.port))…", systemImage: "stop.circle") {
                    actions.on(model).stopping = SessionActions.Port(session: session.id, port: port.port)
                }
            }
        }
    }
}

/// Quit Idle…, when any session has sat idle for half an hour.
struct QuitIdleButton: View {
    var title = "Quit Idle Sessions…"
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        let count = SessionActions.idleCount(model.sessions.sessions)
        if model.tools.can(.quit), count > 0 {
            Button(title, systemImage: "xmark.circle", role: .destructive) { actions.on(model).quittingIdle = count }
                .disabled(actions.isBusy(SessionActions.quitIdleKey))
        }
    }
}

/// Fork: a new hosted session from where this one is now.
struct ForkButton: View {
    let session: RemoteSession?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session, SessionActions.canFork(session, tools: model.tools) {
            Button("Fork", systemImage: "arrow.triangle.branch") { actions.on(model).fork(session) }
                .disabled(actions.isBusy("fork-\(session.id)"))
        }
    }
}

/// Fork from Here, for a message's long-press menu. The Mac forks only from the latest state, so this
/// shows on the session's last message alone and nowhere else.
struct ForkFromHereButton: View {
    let sessionID: SessionKey
    let message: TranscriptMessage
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session = model.sessions.session(sessionID), SessionActions.canFork(session, tools: model.tools),
           model.transcripts.messages[sessionID]?.last?.seq == message.seq {
            Button("Fork from Here", systemImage: "arrow.triangle.branch") { actions.on(model).fork(session) }
                .disabled(actions.isBusy("fork-\(session.id)"))
        }
    }
}

/// Reply…, for a session that finished its turn and takes a follow-up.
struct ReplyButton: View {
    let session: RemoteSession?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session, session.abilities.contains(.followUp) || session.abilities.contains(.type) {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { actions.on(model).replying = session }
        }
    }
}

/// Pin or Unpin the conversation in History; Side A keeps it.
struct PinButton: View {
    let session: RemoteSession?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session, session.conversationID != nil, model.tools.can(.history) {
            let pinned = model.tools.isPinned(session)
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") { actions.on(model).setPinned(session, !pinned) }
                .disabled(actions.isBusy("pin-\(session.id)"))
        }
    }
}

/// Rename…: Side A's own title for the conversation.
struct RenameButton: View {
    let session: RemoteSession?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session, session.conversationID != nil, model.tools.can(.history) {
            Button("Rename…", systemImage: "pencil") {
                actions.on(model).newTitle = model.tools.title(for: session)
                actions.on(model).renaming = session
            }
        }
    }
}

/// Review Changes, where the session takes it (Codex `review/start`, idle).
struct ReviewButton: View {
    let session: RemoteSession?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session, session.abilities.contains(.review) {
            Button("Review Changes", systemImage: "text.magnifyingglass") { actions.on(model).review(session) }
                .disabled(actions.isBusy("review-\(session.id)"))
        }
    }
}

/// Compact, where the session takes it (idle).
struct CompactButton: View {
    let session: RemoteSession?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session, session.abilities.contains(.compact) {
            Button("Compact", systemImage: "arrow.down.right.and.arrow.up.left") { actions.on(model).compact(session) }
                .disabled(actions.isBusy("compact-\(session.id)"))
        }
    }
}
