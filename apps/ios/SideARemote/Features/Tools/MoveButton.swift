import SideAProtocol
import SwiftUI

struct MoveButton: View {
    let session: RemoteSession?
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    /// The host says this one can go, and it can send sessions at all: a working one only where it can go after its turn.
    static func shows(_ session: RemoteSession, tools: MacTools) -> Bool {
        session.abilities.contains(.move) && tools.can(.moves) && (!MoveWhen.isWorking(session) || tools.can(.movesWhen))
    }

    var body: some View {
        if let session, let waiting = model.tools.moves.waiting(for: session) {
            CancelMoveButton(record: waiting)
        } else if let session, Self.shows(session, tools: model.tools) {
            Button("Move to…", systemImage: "desktopcomputer.and.arrow.down") { actions.on(model).moving = session }
                .disabled(actions.isBusy(session.id))
        }
    }
}

extension SessionActions {
    func checkMove(_ record: MoveRecord) {
        run("check-\(record.id)", failed: "Couldn't Check") { tools in
            let checked = try await tools.checkMove(record.id)
            if checked.state != record.state { AccessibilityNotification.Announcement(MoveText.status(checked)).post() }
        }
    }
}
