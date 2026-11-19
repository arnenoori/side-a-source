import GameController
import UIKit

/// What the keyboard last looked like, so the attachment panel can take its exact place: its height for each way the
/// screen is held (kept between launches, so the first opening after a launch is right too), and whether it is docked.
/// One set of observers for the whole app, made the first time anything asks.
@MainActor
final class KeyboardMetrics {
    static let shared = KeyboardMetrics()
    nonisolated deinit {}

    private(set) var heights: KeyboardHeights
    /// False while the keyboard floats, is split, or is undocked: there is no area at the bottom for a panel to take.
    private(set) var isDocked = true
    /// The panel is the keyboard right now, so what the system reports is the panel's own height, not a keyboard's.
    var panelIsShowing = false

    private let store = UserDefaults(suiteName: "SideARemote.keyboard") ?? UserDefaults()

    private init() {
        heights = KeyboardHeights(portrait: store.object(forKey: "portrait") as? CGFloat,
                                  landscape: store.object(forKey: "landscape") as? CGFloat)
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillChangeFrameNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                let local = note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool ?? true
                let screen = (note.object as? UIScreen)?.bounds
                MainActor.assumeIsolated { if local, let end, let screen { self?.saw(end, in: screen) } }
            }
        }
    }

    /// Makes the observers before the first keyboard, so none is missed.
    static func start() { _ = shared }

    var hasHardwareKeyboard: Bool { GCKeyboard.coalesced != nil }

    /// The height the panel takes for the screen as it is held now.
    func panelHeight(landscape: Bool, isPad: Bool) -> CGFloat { heights.height(landscape: landscape, isPad: isPad) }

    /// Where a panel goes, for this device and keyboard.
    var presentation: PanelPresentation {
        #if DEBUG
        // `--panel-popover`: the iPad hardware-keyboard path, on a simulator that has none.
        if ProcessInfo.processInfo.arguments.contains("--panel-popover") { return .popover }
        #endif
        return .decide(isPad: UIDevice.current.userInterfaceIdiom == .pad, hardwareKeyboard: hasHardwareKeyboard, keyboardDocked: isDocked)
    }

    private func saw(_ frame: CGRect, in screen: CGRect) {
        let docked = frame.maxY >= screen.height - 1 && frame.width >= screen.width - 1
        isDocked = docked
        guard docked, !panelIsShowing else { return }
        let landscape = screen.width > screen.height
        heights.remember(frame.height, landscape: landscape)
        if let height = landscape ? heights.landscape : heights.portrait { store.set(height, forKey: landscape ? "landscape" : "portrait") }
    }
}
