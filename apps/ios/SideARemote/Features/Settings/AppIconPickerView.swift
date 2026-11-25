import SideARemoteShared
import SwiftUI
import UIKit

/// The icons the app can wear. `iconName` is the alternate's `.appiconset`, nil for the one the app ships with;
/// `art` is an image set of the same art, since an app icon set can't be loaded as an image
/// (design/build_icon_pack.py writes it from the 1024 px icon, so the two can't drift).
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

    var art: String {
        switch self {
        case .standard: "IconArtDefault"
        case .crtPixel: "IconArtCRTPixel"
        default: "IconArt" + name
        }
    }

    /// The icon the app is wearing now; reading it in a view updates the view when the choice changes.
    static var current: AppIconOption { AppIconChoice.shared.option }

    init(iconName: String?) {
        self = Self.allCases.first { $0.iconName == iconName } ?? .standard
    }
}

struct AppIconStrip: View {
    private let choice = AppIconChoice.shared
    @State private var failed = 0
    private static let side: CGFloat = 56

    private var current: AppIconOption { choice.option }

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
            Image(option.art)
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
        Task { if await choice.switchTo(option) == false { failed += 1 } }
    }
}
