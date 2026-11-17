import SwiftUI
import UIKit

/// The drawer lives in a window of its own, over the app, so the menu and the sheet can cover the composer and
/// the transcript. The window never becomes key, so the field keeps the keyboard and the caret.
final class DrawerWindow: UIWindow {
    nonisolated deinit {}

    @MainActor static func show(in scene: UIWindowScene, controller: DrawerController) -> DrawerWindow {
        let window = DrawerWindow(windowScene: scene)
        window.backgroundColor = .clear
        // Above the app and any sheet it presents. Not above the keyboard: on iOS 26 the keyboard is composited
        // by the system outside every app window (a window at the maximum level, 10,000,000, still sits under
        // it), so the drawer is laid out above the keyboard instead; see `DrawerLayout.keyboardTop`.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        let host = UIHostingController(rootView: DrawerRoot(controller: controller))
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        window.rootViewController = host
        window.isHidden = false
        return window
    }

    func hide() {
        isHidden = true
        rootViewController = nil
    }
}

/// Reports the scene, the window's size and safe area, and the frame of a sheet it sits in that stops short of the
/// window's bottom, without taking part in layout.
struct SceneAnchor: UIViewRepresentable {
    let onChange: (UIWindowScene?, CGSize, EdgeInsets, CGRect?) -> Void

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: Anchor, context: Context) { view.onChange = onChange }

    final class Anchor: UIView {
        var onChange: ((UIWindowScene?, CGSize, EdgeInsets, CGRect?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }

        private func report() {
            guard let window else { onChange?(nil, .zero, EdgeInsets(), nil); return }
            let inset = window.safeAreaInsets
            onChange?(window.windowScene, window.bounds.size,
                      EdgeInsets(top: inset.top, leading: inset.left, bottom: inset.bottom, trailing: inset.right), container(in: window))
        }

        private func container(in window: UIWindow) -> CGRect? {
            var responder: UIResponder? = next
            while let current = responder {
                if let controller = current as? UIViewController, controller.presentingViewController != nil {
                    let frame = controller.view.convert(controller.view.bounds, to: window)
                    return frame.maxY < window.bounds.height - 1 ? frame : nil
                }
                responder = current.next
            }
            return nil
        }
    }
}
