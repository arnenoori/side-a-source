import SideARemoteShared
import SwiftUI
import UIKit

/// Text the user can select part of, as in Notes or Safari: long-press for handles, the magnifier and the system's
/// Copy, Look Up and Share. SwiftUI's `.textSelection` selects whole blocks, and a context menu on top lifts the
/// view instead, so transcript prose sits on a read-only UITextView. A tap can show `menu` as an edit-menu callout
/// anchored to the text, with no lifted preview.
struct SelectableText: UIViewRepresentable {
    struct Style: Equatable {
        var textStyle: UIFont.TextStyle = .body
        var weight: UIFont.Weight = .regular
        var monospaced = false
        var secondary = false
        var lineSpacing: CGFloat = 3
        /// False for code: lines keep their length and the view grows sideways, inside a horizontal scroll.
        var wraps = true
    }

    struct Action {
        let title: String
        let image: String
        var destructive = false
        let perform: () -> Void
    }

    let text: AttributedString
    var style = Style()
    /// What a tap offers; none, and a tap does nothing.
    var menu: [Action] = []

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL
    /// UIKit doesn't see SwiftUI's tint: the selection handles and highlight take the accent from here.
    @AppStorage(Accent.key, store: Accent.store) private var accent = Accent.blue

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.delegate = context.coordinator
        context.coordinator.view = view
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addInteraction(context.coordinator.editMenu)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.tintColor = accent.uiColor
        let rendered = Self.render(text, style: style, size: typeSize)
        // Reassigning the same text drops a selection the user is making.
        if view.attributedText != rendered { view.attributedText = rendered }
        view.textContainer.widthTracksTextView = style.wraps
        view.textContainer.lineBreakMode = style.wraps ? .byWordWrapping : .byClipping
        if !style.wraps { view.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        if !style.wraps {
            let bounds = uiView.attributedText.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            return CGSize(width: ceil(bounds.width) + 1, height: ceil(bounds.height))
        }
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: proposal.width == nil ? fitted.width : min(width, fitted.width), height: fitted.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Drops every selection on screen, as a tap elsewhere in the transcript does.
    static func clearSelection(except keep: UITextView? = nil) {
        NotificationCenter.default.post(name: .selectableTextClear, object: keep)
    }

    /// SwiftUI's Markdown attributes (inline code, emphasis, links) as UIKit's, at the environment's type size.
    static func render(_ text: AttributedString, style: Style, size: DynamicTypeSize) -> NSAttributedString {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let base = UIFont.preferredFont(forTextStyle: style.textStyle, compatibleWith: traits)
        let body = style.monospaced ? UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: style.weight)
            : UIFont.systemFont(ofSize: base.pointSize, weight: style.weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        let result = NSMutableAttributedString()
        for run in text.runs {
            let piece = String(text[run.range].characters)
            var font = body
            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph,
                                                             .foregroundColor: style.secondary ? UIColor.secondaryLabel : UIColor.label]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: base.pointSize * 0.94, weight: style.weight)
                    attributes[.backgroundColor] = UIColor.tertiarySystemFill
                }
                var symbolic: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { symbolic.insert(.traitBold) }
                if intent.contains(.emphasized) { symbolic.insert(.traitItalic) }
                if !symbolic.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(symbolic)) {
                    font = UIFont(descriptor: descriptor, size: font.pointSize)
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            // Only http(s) links reach here (MarkdownParser drops the rest); they open through SwiftUI's openURL.
            if let link = run.link {
                attributes[.link] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            attributes[.font] = font
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
        nonisolated deinit {}

        var parent: SelectableText
        weak var view: UITextView?
        lazy var editMenu = UIEditMenuInteraction(delegate: self)

        init(_ parent: SelectableText) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(clear(_:)), name: .selectableTextClear, object: nil)
        }

        @objc private func clear(_ note: Notification) {
            guard let view, note.object as? UITextView !== view, view.selectedRange.length > 0 else { return }
            view.selectedRange = NSRange(location: 0, length: 0)
            view.resignFirstResponder()
        }

        /// One selection at a time, as in Notes.
        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length > 0 { SelectableText.clearSelection(except: textView) }
        }

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard !parent.menu.isEmpty, let view = tap.view as? UITextView, view.selectedRange.length == 0 else { return }
            let point = tap.location(in: view)
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                 suggestedActions: [UIMenuElement]) -> UIMenu? {
            UIMenu(children: parent.menu.map { action in
                UIAction(title: action.title, image: UIImage(systemName: action.image),
                         attributes: action.destructive ? .destructive : []) { _ in action.perform() }
            })
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [parent] _ in parent.openURL(url) }
        }
    }
}

extension Notification.Name {
    fileprivate static let selectableTextClear = Notification.Name("SelectableText.clear")
}

private extension UIContentSizeCategory {
    init(_ size: DynamicTypeSize) {
        self = switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

/// A tap or long-press on the content shows `menu` as an edit-menu callout, the way SelectableText's tap does,
/// for rows with no text of their own to select.
struct EditMenuArea: UIViewRepresentable {
    let menu: [SelectableText.Action]

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(context.coordinator.editMenu)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:))))
        view.addGestureRecognizer(UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:))))
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.menu = menu }

    func makeCoordinator() -> Coordinator { Coordinator(menu) }

    final class Coordinator: NSObject, UIEditMenuInteractionDelegate {
        nonisolated deinit {}

        var menu: [SelectableText.Action]
        lazy var editMenu = UIEditMenuInteraction(delegate: self)

        init(_ menu: [SelectableText.Action]) { self.menu = menu }

        @objc func pressed(_ gesture: UIGestureRecognizer) {
            guard gesture.state == .ended || gesture.state == .began, !menu.isEmpty, let view = gesture.view else { return }
            SelectableText.clearSelection()
            let point = CGPoint(x: view.bounds.midX, y: view.bounds.minY)
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                 suggestedActions: [UIMenuElement]) -> UIMenu? {
            UIMenu(children: menu.map { action in
                UIAction(title: action.title, image: UIImage(systemName: action.image),
                         attributes: action.destructive ? .destructive : []) { _ in action.perform() }
            })
        }
    }
}
