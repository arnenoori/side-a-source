import ObjectiveC
import UIKit

/// Makes the message field's own Paste (the edit menu's, and ⌘V on a hardware keyboard) take a picture.
///
/// The field is a SwiftUI `TextField`, whose text view isn't ours, and UIKit offers a text view no hook for this:
/// it enables Paste only when the clipboard holds text. So the one text view that has the keyboard is given a
/// subclass, made at run time the way key-value observing makes one, that answers two questions differently
/// when, and only when, the clipboard is nothing but a picture: Paste is available, and Paste attaches it.
/// Everything else goes to the original implementation untouched, so text paste behaves as it always did.
///
/// Nothing is read until the user pastes. `UIPasteboard.hasImages` and `hasStrings`, which the menu asks, don't
/// raise the "pasted from" banner; reading the image after an explicit Paste raises it once, as the system requires.
@MainActor
final class PasteBridge {
    nonisolated deinit {}

    var room: () -> Int = { 0 }
    var onImage: (Data) -> Void = { _ in }
    private weak var installed: UITextView?
    /// The pasteboard Paste reads. The general one in the app; tests give their own, which doesn't reach the Mac's clipboard.
    var pasteboard: UIPasteboard = .general
    var isInstalled: Bool { installed != nil }

    /// What Paste does with the clipboard as it is now.
    var decision: PasteDecision {
        let board = pasteboard
        return PasteDecision.decide(hasText: board.hasStrings || board.hasURLs, hasImage: board.hasImages, room: room())
    }

    /// Joins whichever text view has the keyboard now. Safe to call again; a field is joined once.
    func install() {
        guard let view = UIResponder.currentFirstResponder as? UITextView, view !== installed else { return }
        _ = attach(view)
    }

    /// Hooks one text view and routes its paste here. False, and nothing changed, when the view isn't one that
    /// can be hooked safely; the drawer's Paste row is the path that always works.
    func attach(_ view: UITextView) -> Bool {
        guard PasteSubclass.hook(view) else { return false }
        Self.bridges.setObject(Box(self), forKey: view)
        installed = view
        return true
    }

    /// Reads the picture and hands it over; false when there isn't one to take.
    fileprivate func paste() -> Bool {
        guard decision == .image, let image = pasteboard.image, let data = image.jpegData(compressionQuality: 0.95) else { return false }
        onImage(data)
        return true
    }

    private final class Box {
        nonisolated deinit {}
        weak var bridge: PasteBridge?
        init(_ bridge: PasteBridge) { self.bridge = bridge }
    }

    private static let bridges = NSMapTable<UITextView, Box>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    fileprivate static func bridge(for view: UITextView) -> PasteBridge? { bridges.object(forKey: view)?.bridge }
}

/// The run-time subclass, one per text view class.
@MainActor
enum PasteSubclass {
    private static var made: [ObjectIdentifier: AnyClass] = [:]
    private static let prefix = "SideAPaste_"

    /// Whether this view can be given the subclass. Anything unexpected is left exactly as it is: a view that
    /// isn't a text view, one whose real class isn't the class it reports (key-value observing has swapped it),
    /// or a class that lacks either method.
    static func eligible(_ view: AnyObject) -> Bool {
        guard let object = view as? UITextView, let actual = object_getClass(object), actual == type(of: object) else { return false }
        // `class_getMethodImplementation` hands back a forwarding stub for a selector nobody implements, so it can't
        // tell; the instance method itself can.
        return class_getInstanceMethod(actual, #selector(UIResponder.canPerformAction(_:withSender:))) != nil
            && class_getInstanceMethod(actual, #selector(UIResponder.paste(_:))) != nil
            && !NSStringFromClass(actual).hasPrefix("NSKVONotifying_")
    }

    /// Gives the view the subclass once per class (a view that already has it is left alone). False when it can't.
    static func hook(_ view: AnyObject) -> Bool {
        guard eligible(view) else { return false }
        let base = type(of: view)
        if NSStringFromClass(base).hasPrefix(prefix) { return true }
        guard let subclass = make(for: base) else { return false }
        object_setClass(view, subclass)
        return true
    }

    static var createdCount: Int { made.count }

    private typealias CanPerform = @convention(c) (AnyObject, Selector, Selector, Any?) -> Bool
    private typealias Paste = @convention(c) (AnyObject, Selector, Any?) -> Void

    private static func make(for base: AnyClass) -> AnyClass? {
        if let existing = made[ObjectIdentifier(base)] { return existing }
        let canSelector = #selector(UIResponder.canPerformAction(_:withSender:))
        let pasteSelector = #selector(UIResponder.paste(_:))
        guard let canMethod = class_getInstanceMethod(base, canSelector),
              let pasteMethod = class_getInstanceMethod(base, pasteSelector),
              let subclass = objc_allocateClassPair(base, "\(prefix)\(NSStringFromClass(base))", 0) else { return nil }
        let originalCan = unsafeBitCast(method_getImplementation(canMethod), to: CanPerform.self)
        let originalPaste = unsafeBitCast(method_getImplementation(pasteMethod), to: Paste.self)

        let can: @convention(block) (AnyObject, Selector, Any?) -> Bool = { view, action, sender in
            if action == pasteSelector, let text = view as? UITextView,
               MainActor.assumeIsolated({ PasteBridge.bridge(for: text)?.decision == .image }) { return true }
            return originalCan(view, canSelector, action, sender)
        }
        let paste: @convention(block) (AnyObject, Any?) -> Void = { view, sender in
            if let text = view as? UITextView, MainActor.assumeIsolated({ PasteBridge.bridge(for: text)?.paste() == true }) { return }
            originalPaste(view, pasteSelector, sender)
        }
        class_addMethod(subclass, canSelector, imp_implementationWithBlock(can), "B@::@")
        class_addMethod(subclass, pasteSelector, imp_implementationWithBlock(paste), "v@:@")
        objc_registerClassPair(subclass)
        made[ObjectIdentifier(base)] = subclass
        return subclass
    }
}

extension UIResponder {
    private static weak var found: UIResponder?

    /// The view that has the keyboard, found by sending an action down the responder chain, which is the one
    /// way UIKit offers to ask.
    static var currentFirstResponder: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(reportFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func reportFirstResponder() { UIResponder.found = self }
}
