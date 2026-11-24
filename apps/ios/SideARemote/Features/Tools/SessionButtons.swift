import SideAProtocol
import SideARemoteShared
import SwiftUI

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

struct ShowOnMacButton: View {
    let name: String?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let name, model.tools.can(.hostedShow) {
            Button(model.tools.onMac(name) ? "Show on \(model.mac.name)" : "Open on \(model.mac.name)", systemImage: "macwindow") {
                actions.on(model).showOnMac(name)
            }
            .disabled(actions.isBusy("show-\(name)"))
        }
    }
}

struct ContinueButton: View {
    let session: RemoteSession?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session, session.hosted == nil, session.abilities.contains(.continueOnPhone), model.tools.can(.continueOnPhone) {
            Button("Continue on \(ThisDevice.kind)", systemImage: ThisDevice.symbol) { actions.on(model).continuing = session }
                .disabled(actions.isBusy(session.id))
        }
    }
}

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

struct QuitButton: View {
    let session: RemoteSession?
    var title: String?
    var undoable = false
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        if let session, !session.headless, model.tools.can(.quit) {
            Button(title ?? (SessionActions.quitAsks(session) ? "Quit Session…" : "Quit Session"), systemImage: "xmark.circle", role: .destructive) {
                actions.on(model).requestQuit(session, undoable: undoable)
            }
                .disabled(actions.isBusy(session.id))
        }
    }
}

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
                Button(SessionActions.stopAsks(session) ? "Stop Server on :\(String(port.port))…" : "Stop Server on :\(String(port.port))", systemImage: "stop.circle") {
                    actions.on(model).requestStop(SessionActions.Port(session: session.id, port: port.port))
                }
            }
        }
    }
}

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
