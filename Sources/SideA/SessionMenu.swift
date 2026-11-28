import SideAProtocol
import SideASessionKit
import SwiftUI

/// The Player menu. Its account keys (⌘↩, ⌘←, ⌘→) are also text-editing keys, and a menu's key is taken before the
/// focused text sees it, so they stand down while the Sessions window has the keyboard.
struct PlayerMenu: View {
    let store: AccountStore
    var body: some View {
        let sessions = store.sessions.desk.windowActive
        Button("Use Selected Account on This Mac") { store.play() }.keyboardShortcut(.return, modifiers: .command).disabled(sessions)
        Button("Previous Account") { store.step(-1) }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(sessions)
        Button("Next Account") { store.step(1) }.keyboardShortcut(.rightArrow, modifiers: .command).disabled(sessions)
        Divider()
        Button("Accounts…") { store.openLibrary() }.keyboardShortcut("l", modifiers: .command)
        Button("Hold Controls") { store.held.toggle() }.keyboardShortcut("h", modifiers: [.command, .shift])
    }
}

/// Everything the Sessions window does from the keyboard, where it can be found and where VoiceOver reaches it.
struct SessionMenu: View {
    let store: AccountStore
    private var model: SessionStore { store.sessions }

    var body: some View {
        let desk = model.desk
        let here = desk.windowKey
        let open = here ? model.openSession : nil
        let live = here ? model.openLive : nil
        Button("New Session…") {
            store.openSessions()
            model.creating = true
        }
        .keyboardShortcut("n")
        Button("Go to Session…") { desk.switching.toggle() }.keyboardShortcut("k").disabled(!here)
        Divider()
        Button("Next Session") { model.step(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(!here)
        Button("Previous Session") { model.step(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(!here)
        Button("Next Session That Needs You") { model.nextNeedingYou() }
            .keyboardShortcut("a", modifiers: [.command, .option]).disabled(!here || model.attentionIDs.isEmpty)
        Button("Last Session") { model.goPrevious() }.keyboardShortcut(.tab, modifiers: .control).disabled(!here || desk.previous == nil)
        Button("Back") { model.goBack() }.keyboardShortcut("[").disabled(!here || !desk.canGoBack)
        Button("Forward") { model.goForward() }.keyboardShortcut("]").disabled(!here || !desk.canGoForward)
        Menu("Go to Session") {
            ForEach(1...9, id: \.self) { number in
                Button(title(number)) { model.jump(to: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .disabled(!here || model.runningIDs.count < number)
            }
        }
        Divider()
        Button("Type a Message") { desk.composerFocus += 1 }.keyboardShortcut("j").disabled(open == nil)
        Button("Go to the List") { desk.sidebarHidden = false; desk.listFocus += 1 }.keyboardShortcut("j", modifiers: [.command, .shift]).disabled(!here)
        Button(desk.sidebarHidden ? "Show Sidebar" : "Hide Sidebar") { withAnimation(Ink.glide) { desk.sidebarHidden.toggle() } }
            .keyboardShortcut("0").disabled(!here)
        Divider()
        Button("Stop") { if let live { model.stop(live, now: true) } }.keyboardShortcut(".").disabled(live?.status != "busy")
        Button(showTitle(open, live)) { if let open { model.showOrResume(open) } }.keyboardShortcut("t").disabled(open == nil)
        Divider()
        Button(open.map { model.isPinned($0.id) } == true ? "Unpin" : "Pin") { if let open { model.pin(open.id) } }
            .keyboardShortcut("p", modifiers: [.command, .option]).disabled(open == nil)
        Button("Rename…") { model.renaming = open }.keyboardShortcut("r", modifiers: [.command, .option]).disabled(open == nil)
        Button(open.map { model.isArchived($0.id) } == true ? "Unarchive" : "Archive") { if let open { model.archive(open.id) } }
            .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(open == nil || live != nil)
        Menu("Snooze") {
            if let live, model.snooze(of: live) != nil {
                Button("Wake") { model.wake(live) }
            } else {
                ForEach(SessionSnooze.Choice.offered, id: \.self) { choice in
                    Button(choice.title) { if let live { model.snooze(live, choice) } }
                }
            }
        }
        .disabled(live == nil)
        Menu("Run") {
            ForEach(Array(model.projectActions.prefix(9).enumerated()), id: \.element.id) { index, action in
                Button { model.run(action) } label: { Text(action.name); Text(action.command) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .option])
            }
        }
        .disabled(!here || model.projectActions.isEmpty)
        Button("Snooze for an Hour") { if let live { model.snooze(live, .hour) } }.keyboardShortcut("s", modifiers: [.command, .option]).disabled(live == nil)
        Button("Undo \(desk.undo?.text ?? "")") { desk.takeBack() }.disabled(!here || desk.undo?.undo == nil)
    }

    private func title(_ number: Int) -> String {
        let ids = model.desk.windowKey ? model.runningIDs : []
        guard ids.indices.contains(number - 1) else { return "Session \(number)" }
        return model.title(of: ids[number - 1]) ?? "Session \(number)"
    }

    private func showTitle(_ session: SessionInfo?, _ live: LiveSession?) -> String {
        guard session != nil else { return "Show in Terminal" }
        guard let live else { return "Resume in \(model.resumeTerminal.title)" }
        return model.hostName(live).map { "Show in \($0)" } ?? "Branch in \(model.resumeTerminal.title)"
    }
}
