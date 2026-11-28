import AppKit
import SwiftUI

/// The composer's text: a text view that grows to six lines, where ↩ sends, ⇧↩ breaks the line, ⌥↩ queues, ⎋ is
/// offered to the composer first, and the arrows, ⇥ and ↩ go to an open suggestion list before the text.
struct ComposerField: NSViewRepresentable {
    enum Key { case send, queue, other, stash, escape, up, down, tab }

    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    /// True when the composer took the key; false leaves it to the text.
    var onKey: (Key) -> Bool
    /// Images pasted or dropped onto the text; true when they were taken.
    var onImages: ([Data]) -> Bool = { _ in false }
    var onCaret: (Int) -> Void = { _ in }
    /// The composer has been asked to take the keyboard and hasn't yet. It never takes it otherwise: a field that
    /// took it on every update pulled it out of the search and find fields.
    var wantsFocus = false
    var onFocus: () -> Void = {}

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
        if wantsFocus, view.window != nil, !context.coordinator.focusing {
            context.coordinator.focusing = true
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
            Task { @MainActor [coordinator = context.coordinator] in
                coordinator.focusing = false
                coordinator.parent.onFocus()
            }
        }
        context.coordinator.measure(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        /// A focus request is on its way to the window, so the updates before it lands don't ask again.
        var focusing = false
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

    final class TextView: NSTextView {
        var placeholder = ""
        weak var coordinator: Coordinator?

        override func draw(_ rect: NSRect) {
            super.draw(rect)
            guard string.isEmpty else { return }
            (placeholder as NSString).draw(at: NSPoint(x: 0, y: 0),
                                           withAttributes: [.font: ComposerField.font, .foregroundColor: NSColor.placeholderTextColor])
        }

        /// ⌘↩ never reaches a text view as a command, so it is taken here, before the menu bar is asked.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
            if event.type == .keyDown, [36, 76].contains(event.keyCode), flags == .command, window?.firstResponder === self, let coordinator {
                return coordinator.parent.onKey(.other)
            }
            if event.type == .keyDown, event.charactersIgnoringModifiers == "s", flags == .command, window?.firstResponder === self, let coordinator {
                return coordinator.parent.onKey(.stash)
            }
            return super.performKeyEquivalent(with: event)
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
