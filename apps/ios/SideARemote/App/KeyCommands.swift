import SwiftUI

struct RemoteCommandActions {
    var canStart: () -> Bool
    var newSession: () -> Void
    var show: (AppTab) -> Void
    var sheet: (AppSheet) -> Void
    var previousSession: () -> Void
    var nextSession: () -> Void
}

/// The one window's actions for the menu bar, and New Session asked for from the keyboard (Sessions owns the sheet, so
/// it watches the count). Held by the app rather than read as a focused value: those are empty until something in the
/// window has keyboard focus, which left ⌘N and ⌘2 dead on a freshly opened app.
@Observable
final class KeyRequests {
    nonisolated deinit {}

    var newSession = 0
    var actions: RemoteCommandActions?

    static var coverIsUp: Bool {
        let window = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.windows.first { !$0.isHidden && $0.windowLevel == .normal } }.first
        var presented = window?.rootViewController?.presentedViewController
        while let controller = presented {
            if [.fullScreen, .overFullScreen].contains(controller.modalPresentationStyle) { return true }
            presented = controller.presentedViewController
        }
        return false
    }
}

struct RemoteCommands: Commands {
    let keys: KeyRequests
    let lock: AppLock

    private var off: Bool { lock.covered || keys.actions == nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { run { $0.newSession() } }
                .keyboardShortcut("n")
                .disabled(off || keys.actions?.canStart() != true)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings") { run { $0.sheet(.settings) } }
                .keyboardShortcut(",")
                .disabled(off)
        }
        CommandMenu("Go") {
            Group {
                Button("Sessions") { run { $0.show(.sessions) } }.keyboardShortcut("1")
                Button("Accounts") { run { $0.show(.accounts) } }.keyboardShortcut("2")
                Button("Search") { run { $0.sheet(.search) } }.keyboardShortcut("f")
                Divider()
                Button("Previous Session") { run { $0.previousSession() } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Next Session") { run { $0.nextSession() } }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
            .disabled(off)
        }
    }

    private func run(_ action: (RemoteCommandActions) -> Void) {
        guard !lock.covered, !KeyRequests.coverIsUp, let actions = keys.actions else { return }
        action(actions)
    }
}

extension View {
    func closesOnEscape() -> some View { modifier(CloseOnEscape()) }
}

private struct CloseOnEscape: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.background {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

#if DEBUG
enum LaunchLinks {
    static var url: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count else { return nil }
        return URL(string: arguments[index + 1])
    }

    static var newSession: Bool { ProcessInfo.processInfo.arguments.contains("--new-session") }
}
#endif
