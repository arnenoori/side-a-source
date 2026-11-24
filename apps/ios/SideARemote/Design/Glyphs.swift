import SideAProtocol
import SwiftUI

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
        if phase == .working, !reduceMotion {
            Image(systemName: "progress.indicator")
                .foregroundStyle(.secondary)
                .symbolEffect(.rotate, options: .repeat(.continuous))
        } else {
            let colors = Self.colors(phase)
            Image(systemName: Self.symbol(phase))
                .symbolRenderingMode(.palette)
                .foregroundStyle(colors.primary, colors.secondary)
        }
    }

    static func symbol(_ phase: SessionPhase) -> String {
        switch phase {
        case .needsYou: "circle.circle.fill"
        case .working: "ellipsis.circle"
        case .ready: "checkmark.circle.fill"
        case .idle: "circle"
        }
    }

    static func colors(_ phase: SessionPhase) -> (primary: Color, secondary: Color) {
        switch phase {
        case .needsYou: (.amber, .amber.opacity(0.3))
        case .working: (Color(.secondaryLabel), Color(.secondaryLabel))
        case .ready: (.white, .done)
        case .idle: (Color(.tertiaryLabel), Color(.tertiaryLabel))
        }
    }

    /// For a menu row, which draws its icons as templates: the row's colours are baked into the image.
    static func menuImage(_ phase: SessionPhase) -> UIImage {
        let colors = Self.colors(phase)
        let palette = UIImage.SymbolConfiguration(paletteColors: [UIColor(colors.primary), UIColor(colors.secondary)])
        return UIImage(systemName: symbol(phase), withConfiguration: palette)?.withRenderingMode(.alwaysOriginal) ?? UIImage()
    }
}

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
