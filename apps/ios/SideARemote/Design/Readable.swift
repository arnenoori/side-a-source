import SwiftUI

/// The widest a column of prose gets. A phone held upright never reaches it; on iPad the transcript and its composer
/// stay this wide, centred, rather than running a line across the whole display.
enum Readable {
    static let width: CGFloat = 720

    /// A tab's side margins in a window `width` wide: cards `Readable.width` wide, centred, and never less than the
    /// usual inset.
    static func margin(in window: CGFloat) -> CGFloat { max((window - Self.width) / 2, Space.l) }
}

extension View {
    /// The transcript and its composer at most `Readable.width` wide on iPad; an iPhone, landscape included, keeps
    /// its full width.
    func readableWidth() -> some View { modifier(ReadableWidth()) }

    /// A tab of lists and forms on a full-width iPad: its cards in one centred column. The margins are the scroll
    /// view's own, so they scroll and its indicator stays at the window's edge.
    func readableColumn() -> some View { modifier(ReadableColumn()) }
}

private struct ReadableWidth: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.frame(maxWidth: Readable.width).frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

private struct ReadableColumn: ViewModifier {
    @Environment(\.horizontalSizeClass) private var width
    @State private var margin: CGFloat = 0

    func body(content: Content) -> some View {
        if RootLayout.of(idiom: UIDevice.current.userInterfaceIdiom, width: width) == .split {
            content
                .contentMargins(.horizontal, margin, for: .scrollContent)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { margin = Readable.margin(in: $0) }
        } else {
            content
        }
    }
}
