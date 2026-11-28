import SideAProtocol
import SwiftUI

/// The line under a session's title while a move waits for its turn to end, in place of what it is doing.
struct MoveWaitingDetail<Detail: View>: View {
    let store: AccountStore
    let session: LiveSession
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        let moves = store.remote.moves
        if let waiting = moves.waitingMove(for: session.sessionID) {
            Text(moves.firing.contains(waiting.id) ? "Moving to \(waiting.computerName)…" : "Moves to \(waiting.computerName) after this turn")
                .foregroundStyle(Color.accentColor)
        } else {
            detail()
        }
    }
}

/// The row's hover button that cancels a waiting move.
struct MoveCancelAction: View {
    let store: AccountStore
    let session: LiveSession

    var body: some View {
        let moves = store.remote.moves
        if let waiting = moves.waitingMove(for: session.sessionID), !moves.firing.contains(waiting.id) {
            RowAction(symbol: "xmark.circle", help: "Cancel the move to \(waiting.computerName)") { moves.cancel(waiting.id) }
        }
    }
}

/// Move and Sleep's two questions: how the working sessions go, and whether to sleep with one still working here.
struct MoveAndSleepHost: ViewModifier {
    let store: AccountStore

    func body(content: Content) -> some View {
        let moves = store.remote.moves
        let working = store.sessions.live.filter { $0.hosted != nil && $0.status != "idle" }.count
        content
            .confirmationDialog("Move every session to \(moves.sleepProposal?.name ?? "") and sleep?",
                                isPresented: Binding(get: { moves.sleepProposal != nil }, set: { if !$0 { moves.sleepProposal = nil } }),
                                presenting: moves.sleepProposal) { computer in
                Button("After This Turn") { MoveMenu.leave(store, to: computer, working: .afterTurn) }
                Button("Now") { MoveMenu.leave(store, to: computer, working: .now) }
            } message: { _ in
                Text(working == 1 ? "One is working. Now interrupts it, so the tool call in progress is cut off."
                     : "\(working) are working. Now interrupts them, so the tool calls in progress are cut off.")
            }
            .alert(Self.title(moves.leftWorking ?? []), isPresented: Binding(get: { moves.leftWorking != nil }, set: { if !$0 { moves.leftWorking = nil } }),
                   presenting: moves.leftWorking) { _ in
                Button("Don't Sleep", role: .cancel) { moves.stayAwake() }
                Button("Sleep Anyway") { Task { await moves.sleepAnyway() } }
            } message: { stayed in
                Text(stayed.map { "\($0.title): \($0.reason)" }.joined(separator: "\n"))
            }
    }

    static func title(_ stayed: [Moves.Stayed]) -> String {
        guard let first = stayed.first else { return "" }
        return stayed.count == 1 ? "\(first.title) stayed here and is working" : "\(stayed.count) sessions stayed here"
    }
}

/// While Move and Sleep waits for sessions to leave: the way to keep the Mac awake.
struct SleepsAfterRow: View {
    let moves: Moves

    var body: some View {
        if let name = moves.sleepsAfter {
            HStack(spacing: 8) {
                Image(systemName: "moon").foregroundStyle(.secondary)
                Text("Sleeps once the sessions have moved to \(name)").lineLimit(1)
                Spacer(minLength: 4)
                Button("Don't Sleep") { moves.stayAwake() }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .accessibilityElement(children: .combine)
        }
    }
}
