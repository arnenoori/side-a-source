import AppKit
import SwiftUI

/// The composer's text: a text view that grows to six lines, where ↩ sends, ⇧↩ breaks the line, ⌥↩ queues, ⎋ is
/// offered to the composer first, and the arrows, ⇥ and ↩ go to an open suggestion list before the text.
struct ComposerField: NSViewRepresentable {
    enum Key { case send, queue, escape, up, down, tab }

    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var focused: Bool
    /// True when the composer took the key; false leaves it to the text.
    var onKey: (Key) -> Bool
    /// Images pasted or dropped onto the text; true when they were taken.
    var onImages: ([Data]) -> Bool = { _ in false }
    /// Where the caret is, for a suggestion list that reads the word under it.
    var onCaret: (Int) -> Void = { _ in }

    static let font = NSFont.systemFont(ofSize: 13)
    static let lineHeight: CGFloat = 17
    static let maxLines: CGFloat = 6

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = TextView()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.font = Self.font
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        view.setAccessibilityLabel(placeholder)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? TextView else { return }
        if view.string != text {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        view.placeholder = placeholder
        view.setAccessibilityPlaceholderValue(placeholder)
        view.needsDisplay = true
        if focused, view.window != nil, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        context.coordinator.measure(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            measure(view)
            parent.onCaret(view.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.onCaret(view.selectedRange().location)
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if flags.contains(.shift) { view.insertNewlineIgnoringFieldEditor(nil); return true }
                return parent.onKey(flags.contains(.option) ? .queue : .send)
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // ⌥↩ arrives as a line break in a text view.
                if flags.contains(.option) { return parent.onKey(.queue) }
                return false
            case #selector(NSResponder.cancelOperation(_:)): return parent.onKey(.escape)
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)): return parent.onKey(.tab)
            default: return false
            }
        }

        func measure(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let lines = max(1, min(ComposerField.maxLines, ceil(layout.usedRect(for: container).height / ComposerField.lineHeight)))
            let height = lines * ComposerField.lineHeight
            if abs(parent.height - height) > 0.5 { DispatchQueue.main.async { self.parent.height = height } }
        }
    }

    /// Draws the placeholder, and hands pasted or dropped images to the composer rather than the text.
    final class TextView: NSTextView {
        var placeholder = ""
        weak var coordinator: Coordinator?

        override func draw(_ rect: NSRect) {
            super.draw(rect)
            guard string.isEmpty else { return }
            (placeholder as NSString).draw(at: NSPoint(x: 0, y: 0),
                                           withAttributes: [.font: ComposerField.font, .foregroundColor: NSColor.placeholderTextColor])
        }

        override func paste(_ sender: Any?) {
            if take(NSPasteboard.general) { return }
            super.paste(sender)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            take(sender.draggingPasteboard) || super.performDragOperation(sender)
        }

        private func take(_ board: NSPasteboard) -> Bool {
            let images = ComposerField.images(on: board)
            guard !images.isEmpty, let coordinator else { return false }
            return coordinator.parent.onImages(images)
        }
    }

    /// Image files, or image data, on a pasteboard; text and other files are left to the text view.
    static func images(on board: NSPasteboard) -> [Data] {
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let files = urls.filter { url in
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
        }.compactMap { try? Data(contentsOf: $0) }
        if !files.isEmpty { return files }
        guard urls.isEmpty else { return [] }
        if let png = board.data(forType: .png) { return [png] }
        if let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            return [png]
        }
        return []
    }
}
