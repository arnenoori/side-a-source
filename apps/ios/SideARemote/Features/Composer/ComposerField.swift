import SideARemoteShared
import SwiftUI
import UIKit

enum HardwareKey: Equatable {
    case up, down, tab, escape
    case enter(shift: Bool)

    init?(_ key: UIKey) {
        switch key.keyCode {
        case .keyboardUpArrow: self = .up
        case .keyboardDownArrow: self = .down
        case .keyboardTab: self = .tab
        case .keyboardEscape: self = .escape
        case .keyboardReturnOrEnter, .keypadEnter: self = .enter(shift: key.modifierFlags.contains(.shift))
        default: return nil
        }
    }
}

final class ComposerTextView: UITextView {
    nonisolated deinit {}

    var onKey: ((HardwareKey) -> Bool)?
    var pasteboard: UIPasteboard = .general
    var pasteRoom: () -> Int = { 0 }
    var onPasteImage: (Data) -> Void = { _ in }
    let placeholderLabel = UILabel()

    /// What Paste does with the clipboard as it is now: only a clipboard that is nothing but a picture, with room for it,
    /// becomes a photo. Nothing is read until the user pastes; `hasImages` and `hasStrings` don't raise the system's banner.
    var pasteDecision: PasteDecision {
        PasteDecision.decide(hasText: pasteboard.hasStrings || pasteboard.hasURLs, hasImage: pasteboard.hasImages, room: pasteRoom())
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.paste(_:)), pasteDecision == .image { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if pasteDecision == .image, let data = pasteboard.image?.jpegData(compressionQuality: 0.95) {
            onPasteImage(data)
            return
        }
        super.paste(sender)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A key during composition (an IME's candidate, dictation's marked text) belongs to the text system.
        if markedTextRange == nil, let key = presses.compactMap(\.key).first, let hardware = HardwareKey(key), onKey?(hardware) == true { return }
        super.pressesBegan(presses, with: event)
    }

    func updatePlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    /// The words that are commands, tinted; everything else the text colour. Only the colour changes, so no glyph moves and
    /// the caret stays where it was; and never while the user is composing, when the text is not yet theirs to restyle.
    /// What is typed next is plain, so a word typed after a command doesn't join it.
    func restyle(_ ranges: [NSRange], tint: UIColor) {
        guard markedTextRange == nil else { return }
        let whole = NSRange(location: 0, length: textStorage.length)
        let saved = selectedRange
        textStorage.beginEditing()
        textStorage.addAttribute(.foregroundColor, value: UIColor.label, range: whole)
        for range in ranges where NSMaxRange(range) <= whole.length {
            textStorage.addAttribute(.foregroundColor, value: tint, range: range)
        }
        textStorage.endEditing()
        typingAttributes = [.font: font ?? UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
        if selectedRange != saved { selectedRange = saved }
    }
}

struct ComposerField: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isFocused: Bool
    let placeholder: String
    var label: String?
    var minLines = 1
    var maxLines: Int? = 6
    var insets = UIEdgeInsets(top: 13, left: Space.m, bottom: 13, right: 0)
    var drawer: AttachDrawer?
    var paste: AttachTarget?
    var onKey: (HardwareKey) -> Bool = { _ in false }
    var highlights: (String) -> [NSRange] = { _ in [] }
    @Environment(\.isEnabled) private var isEnabled
    /// UIKit doesn't see SwiftUI's tint: the user's accent comes from here.
    @AppStorage(Accent.key, store: SharedStorage.defaults) private var accent = Accent.blue

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = insets
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.isScrollEnabled = false
        view.autocorrectionType = .default
        view.returnKeyType = .default
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = label ?? placeholder
        // Styled text doesn't follow Dynamic Type by itself; the size is set again, and the tint put back, when it changes.
        let coordinator = context.coordinator
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ComposerTextView, _) in
            view.font = .preferredFont(forTextStyle: .body)
            view.restyle(coordinator.parent.highlights(view.text), tint: coordinator.parent.accent.uiColor)
        }

        let hint = view.placeholderLabel
        hint.text = placeholder
        hint.font = .preferredFont(forTextStyle: .body)
        hint.adjustsFontForContentSizeCategory = true
        hint.adjustsFontSizeToFitWidth = true
        hint.minimumScaleFactor = 0.85
        hint.textColor = .placeholderText
        hint.isAccessibilityElement = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: insets.left),
            hint.topAnchor.constraint(equalTo: view.topAnchor, constant: insets.top),
            // The text view is a scroll view: its own edges are the content's, so the frame's width is what a long hint must fit.
            hint.widthAnchor.constraint(lessThanOrEqualTo: view.frameLayoutGuide.widthAnchor, constant: -(insets.left + Space.xs))
        ])
        hint.lineBreakMode = .byTruncatingTail
        hint.numberOfLines = 1
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        drawer?.field.view = view
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.onKey = onKey
        view.isEditable = isEnabled
        view.pasteRoom = { [paste] in paste?.room ?? 0 }
        view.onPasteImage = { [paste] data in paste?.add(data) }
        if view.placeholderLabel.text != placeholder {
            view.placeholderLabel.text = placeholder
            view.accessibilityLabel = label ?? placeholder
        }
        view.tintColor = accent.uiColor
        coordinator.apply(text: text, selection: selection, to: view)
        view.restyle(highlights(view.text), tint: accent.uiColor)
        view.updatePlaceholder()
        coordinator.syncFocus(isFocused, of: view)
        coordinator.syncPanel(of: view, drawer: drawer)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: ComposerTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitting = ceil(view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let line = view.font?.lineHeight ?? 20
        let padding = insets.top + insets.bottom
        let least = ceil(line * CGFloat(minLines) + padding)
        let most = maxLines.map { ceil(line * CGFloat($0) + padding) }
        let height = min(max(fitting, least), most ?? .greatestFiniteMagnitude)
        view.isScrollEnabled = most.map { fitting > $0 } ?? false
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        nonisolated deinit {}

        var parent: ComposerField
        weak var view: ComposerTextView?
        private var applying = false
        private var panel: PanelInputView?
        private var focusTask: Task<Void, Never>?

        init(_ parent: ComposerField) {
            self.parent = parent
            super.init()
        }

        func apply(text: String, selection: NSRange, to view: ComposerTextView) {
            applying = true
            defer { applying = false }
            // Never rewrite the text while the user is composing; it is theirs until they commit.
            if view.text != text, view.markedTextRange == nil {
                view.text = text
            }
            let length = (view.text as NSString).length
            let wanted = NSRange(location: min(selection.location, length), length: min(selection.length, max(length - selection.location, 0)))
            if view.selectedRange != wanted, view.markedTextRange == nil { view.selectedRange = wanted }
        }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? ComposerTextView)?.updatePlaceholder()
            (textView as? ComposerTextView)?.restyle(parent.highlights(textView.text), tint: parent.accent.uiColor)
            guard !applying else { return }
            parent.text = textView.text
            parent.selection = textView.selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !applying, parent.selection != textView.selectedRange else { return }
            parent.selection = textView.selectedRange
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
            parent.drawer?.fieldEnded()
        }

        func syncFocus(_ wanted: Bool, of view: ComposerTextView) {
            guard wanted != view.isFirstResponder else { return }
            // Not inside the update that asked: first responder changes lay out, and SwiftUI is mid-layout.
            focusTask?.cancel()
            focusTask = Task { @MainActor [weak view] in
                guard let view, !Task.isCancelled else { return }
                if wanted { view.becomeFirstResponder() } else { view.resignFirstResponder() }
            }
        }

        func syncPanel(of view: ComposerTextView, drawer: AttachDrawer?) {
            guard let drawer else { return }
            let wanted = drawer.takesKeyboard
            if wanted {
                let panel = panel ?? PanelInputView(drawer: drawer)
                self.panel = panel
                drawer.heightSink = { [weak panel] height, animated in panel?.setHeight(height, animated: animated) }
                panel.onShrink = { [weak view] in view?.reloadInputViews() }
                if view.inputView !== panel {
                    panel.setHeight(drawer.height, animated: false)
                    view.inputView = panel
                    if view.isFirstResponder {
                        view.reloadInputViews()
                    } else {
                        Task { @MainActor [weak view] in _ = view?.becomeFirstResponder() }
                    }
                }
            } else if view.inputView != nil {
                view.inputView = nil
                if view.isFirstResponder { view.reloadInputViews() }
                drawer.heightSink = nil
            }
            installTapIfNeeded(on: view)
        }

        private var tap: UITapGestureRecognizer?

        private func installTapIfNeeded(on view: ComposerTextView) {
            guard tap == nil else { return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
            tap = recognizer
        }

        @objc private func tapped() {
            guard let drawer = parent.drawer, drawer.takesKeyboard else { return }
            drawer.showKeyboard()
        }

        nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// The panel as the keyboard: an input view in the keyboard's own style, as tall as the keyboard it replaced, holding the
/// SwiftUI panel. Its height is the one thing it is told; the system lays the rest of the screen out around it, which is why
/// the composer rides it exactly as it rides the keyboard.
@MainActor
final class PanelInputView: UIInputView, UIGestureRecognizerDelegate {
    nonisolated deinit {}

    private let drawer: AttachDrawer
    private var heightConstraint: NSLayoutConstraint?
    private var lastHeight: CGFloat?
    /// Asks the field to lay its keyboard out again, which is how a shorter panel is noticed.
    var onShrink: (() -> Void)?

    init(drawer: AttachDrawer) {
        self.drawer = drawer
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: drawer.height), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        let height = heightAnchor.constraint(equalToConstant: drawer.height)
        height.priority = .required
        height.isActive = true
        heightConstraint = height

        let content = UIHostingConfiguration { AttachPanel(drawer: drawer) }.margins(.all, 0).makeContentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.backgroundColor = .clear
        // The keyboard style's own backdrop blurs whatever is behind the keyboard, and the app's chrome ghosts through it.
        backgroundColor = .systemGray5
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PanelInputView is made in code") }

    func setHeight(_ height: CGFloat, animated: Bool) {
        guard heightConstraint?.constant != height else { return }
        heightConstraint?.constant = height
        invalidateIntrinsicContentSize()
        let layout = { [self] in
            setNeedsLayout()
            superview?.setNeedsLayout()
            window?.layoutIfNeeded()
        }
        // A taller input view is noticed by the keyboard's layout; a shorter one is not, until it is asked to look again.
        let shrinking = height < (lastHeight ?? height)
        lastHeight = height
        defer { if shrinking { onShrink?() } }
        guard animated else { return layout() }
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: layout)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .changed: drawer.drag(by: pan.translation(in: self).y)
        case .ended, .cancelled, .failed: drawer.endDrag(velocity: pan.velocity(in: self).y)
        default: break
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        guard abs(velocity.y) > abs(velocity.x), !drawer.camera.shooting else { return false }
        if let region = drawer.dragRegion, pan.location(in: self).y > region { return false }
        if drawer.showsGrid { return velocity.y > 0 && drawer.gridScrolled <= 1 }
        return true
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
