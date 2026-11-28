import SideAProtocol
import SwiftUI

/// The move sheet's choice for a working session. One waiting on an answer only goes after its turn, so it has none.
struct MoveWhenSection: View {
    let session: RemoteSession
    @Binding var when: MoveRequest.When

    var body: some View {
        let asks = MoveWhen.asksYou(session)
        Section {
            if asks {
                LabeledContent("When", value: "After This Turn")
            } else {
                Picker("When", selection: $when) {
                    Text("After This Turn").tag(MoveRequest.When.afterTurn)
                    Text("Now").tag(MoveRequest.When.now)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        } footer: {
            if !asks, when == .now { Text("Now interrupts its turn, so the tool call in progress is cut off.") }
        }
    }
}

/// A row's third line while its move waits for the turn to end.
struct MoveWaitingFact: View {
    let record: MoveRecord

    var body: some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: "desktopcomputer.and.arrow.down").imageScale(.small)
            Text(MoveText.status(record))
        }
        .font(.footnote)
        .foregroundStyle(.tint)
    }
}

/// Under the field of a conversation whose move waits for its turn: it takes messages as before, and Cancel keeps it here.
struct MoveWaitingLine: View {
    let record: MoveRecord
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    var body: some View {
        HStack(spacing: Space.xs) {
            Label(MoveText.status(record), systemImage: "desktopcomputer.and.arrow.down")
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Button("Cancel") { actions.on(model).cancelMove(record) }
                .fontWeight(.semibold)
                .buttonStyle(.borderless)
                .disabled(actions.isBusy(CancelMoveButton.key(record)))
                .accessibilityLabel("Cancel Move to \(record.computerName)")
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, minHeight: 32)
        .padding(.horizontal, Space.m)
    }
}

/// A conversation that showed its move waiting follows the session to the computer it lands on when this phone is paired
/// with that one, as the move sheet does, and what was typed and not sent goes with it.
struct FollowsWaitingMove: ViewModifier {
    let conversation: String?
    let sessionID: SessionKey
    @Environment(AppModel.self) private var model
    @Environment(AppRoot.self) private var root
    @Environment(\.openSession) private var openSession
    @State private var waited: String?

    func body(content: Content) -> some View {
        let record = conversation.flatMap { conversation in model.tools.moves.records.first { $0.conversationID == conversation } }
        content
            .onChange(of: record?.state == .waiting ? record?.id : nil, initial: true) { _, id in if let id { waited = id } }
            .onChange(of: record.flatMap { $0.id == waited ? MovedActions($0, root: root).open : nil }) { _, route in
                guard let route, case .session(let landed, let mac) = route, let there = root.model(for: mac) else { return }
                waited = nil
                model.handDraft(of: sessionID, to: there, as: landed)
                openSession?(route)
            }
    }
}

extension View {
    func followsWaitingMove(_ conversation: String?, from sessionID: SessionKey) -> some View {
        modifier(FollowsWaitingMove(conversation: conversation, sessionID: sessionID))
    }
}

/// Move to…'s place in the menus while a move waits.
struct CancelMoveButton: View {
    let record: MoveRecord
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions

    static func key(_ record: MoveRecord) -> String { "cancel-\(record.id)" }

    var body: some View {
        Button("Cancel Move to \(record.computerName)", systemImage: "xmark.circle") { actions.on(model).cancelMove(record) }
            .disabled(actions.isBusy(Self.key(record)))
    }
}

extension SessionActions {
    func cancelMove(_ record: MoveRecord) {
        let here = model?.mac.name
        run(CancelMoveButton.key(record), failed: "Couldn't Cancel the Move") { tools in
            if try await tools.cancelMove(record), let here { AccessibilityNotification.Announcement("Stays on \(here)").post() }
        }
    }
}
