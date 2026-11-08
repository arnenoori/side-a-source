import SideAProtocol
import SwiftUI

/// The leading glyph on a session row: the state alone. The agent sits inline in the
/// metadata line, where a badge can't crowd it.
struct StatusGlyph: View {
    let phase: SessionPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 26

    var body: some View {
        state
            .font(.title3)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var state: some View {
        switch phase {
        case .needsYou:
            Image(systemName: "circle.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.amber, Color.amber.opacity(0.3))
        case .working:
            if reduceMotion {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            } else {
                Image(systemName: "progress.indicator")
                    .foregroundStyle(.secondary)
                    .symbolEffect(.rotate, options: .repeat(.continuous))
            }
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.done)
        case .idle:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

/// The disc from the Mac's player, flat: a circle with a hub. Stands in for the `sidea.disc` custom symbol.
struct DiscGlyph: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().fill(.secondary.opacity(0.35))
            Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: size * 0.06)
            Circle().fill(.secondary).frame(width: size * 0.3)
            Circle().fill(Color(.systemBackground)).frame(width: size * 0.1)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
