import UIKit
import SwiftUI

private extension EnvironmentValues {
    /// Whether the text size is an accessibility one, read before the chip holds its own type at `xxxLarge`.
    @Entry var macChipCompact = false
}

extension View {
    /// As the bar's own buttons do, past the largest standard size the chip stays put. It also drops the Mac's name there
    /// (see `MacChipName`).
    func chipTypeSize() -> some View { modifier(ChipTypeSize()) }
}

private struct ChipTypeSize: ViewModifier {
    // The bar hands its items a size already held at xxxLarge, so the person's own setting is read from the system.
    @State private var accessibilitySize = UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory

    func body(content: Content) -> some View {
        content
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .environment(\.macChipCompact, accessibilitySize)
            .onReceive(NotificationCenter.default.publisher(for: UIContentSizeCategory.didChangeNotification)) { _ in
                accessibilitySize = UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory
            }
    }
}

/// The Mac's name in the Sessions chip. At accessibility sizes it is left out: the name would take the width the
/// collapsed "Sessions" title needs, and the dot and the chip's label still say which Mac this is.
struct MacChipName: View {
    let name: String
    let inSidebar: Bool
    @Environment(\.macChipCompact) private var compact

    var body: some View {
        if inSidebar || !compact {
            Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
        }
    }
}
