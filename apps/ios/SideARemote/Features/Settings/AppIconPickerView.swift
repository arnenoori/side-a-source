import SideARemoteShared
import SwiftUI
import UIKit

/// The icons the app can wear. `iconName` is the alternate's `.appiconset`, nil for the one the app ships with;
/// `preview` is a small image set of the same art, since an app icon set can't be loaded as an image.
enum AppIconOption: String, CaseIterable, Identifiable {
    case standard, midnight, cobalt, gold, glass, chrome, crtPixel

    var id: String { rawValue }

    var name: String {
        switch self {
        case .standard: "Default"
        case .midnight: "Midnight"
        case .cobalt: "Cobalt"
        case .gold: "Gold"
        case .glass: "Glass"
        case .chrome: "Chrome"
        case .crtPixel: "CRT Pixel"
        }
    }

    var iconName: String? {
        switch self {
        case .standard: nil
        case .crtPixel: "AppIconCRTPixel"
        default: "AppIcon" + name
        }
    }

    var preview: String {
        switch self {
        case .standard: "IconPreviewDefault"
        case .crtPixel: "IconPreviewCRTPixel"
        default: "IconPreview" + name
        }
    }

    init(iconName: String?) {
        self = Self.allCases.first { $0.iconName == iconName } ?? .standard
    }
}

struct AppIconStrip: View {
    @State private var current = AppIconOption(iconName: UIApplication.shared.alternateIconName)
    @State private var failed = 0
    private static let side: CGFloat = 56

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Space.s) {
                ForEach(AppIconOption.allCases) { option in
                    Button { choose(option) } label: { cell(option) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(option.name) app icon")
                        .accessibilityAddTraits(option == current ? .isSelected : [])
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.xs)
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets())
        .sensoryFeedback(.selection, trigger: current)
        .sensoryFeedback(.error, trigger: failed)
    }

    private func cell(_ option: AppIconOption) -> some View {
        let corner = Self.side * 0.2237
        return VStack(spacing: Space.xxs) {
            Image(option.preview)
                .resizable()
                .scaledToFit()
                .frame(width: Self.side, height: Self.side)
                .clipShape(.rect(cornerRadius: corner, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
                .padding(3)
                .overlay {
                    if option == current { RoundedRectangle(cornerRadius: corner + 3, style: .continuous).strokeBorder(.tint, lineWidth: 2.5) }
                }
            Text(option.name)
                .font(.caption2.weight(option == current ? .semibold : .regular))
                .foregroundStyle(option == current ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 64, minHeight: 44)
        .contentShape(.rect)
    }

    private func choose(_ option: AppIconOption) {
        guard option != current else { return }
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(option.iconName)
                current = option
            } catch {
                RemoteLog.error(.app, "app icon: could not switch to \(option.name): \(error.localizedDescription)")
                // The Simulator reports a failure after it has switched; what iOS now says is the truth.
                let actual = AppIconOption(iconName: UIApplication.shared.alternateIconName)
                if actual == current { failed += 1 } else { current = actual }
            }
        }
    }
}
