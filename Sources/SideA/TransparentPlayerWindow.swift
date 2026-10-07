import AppKit
import SwiftUI

/// Keeps the native titled-window semantics (keyboard focus, Cmd-W, sheets),
/// while making every pixel outside the model transparent.
struct TransparentPlayerWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowStyler { WindowStyler() }
    func updateNSView(_ nsView: WindowStyler, context: Context) {}

    final class WindowStyler: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.identifier = NSUserInterfaceItemIdentifier("side-a-player")
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.toolbar = nil
        }
    }
}

struct ClearWindowSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.clear, for: .window)
        } else {
            content
        }
    }
}
