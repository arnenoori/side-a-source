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

    /// The option for the name iOS reports; one it doesn't know reads as the default.
    init(iconName: String?) {
        self = Self.allCases.first { $0.iconName == iconName } ?? .standard
    }
}

/// Settings › Appearance › App Icon: every icon masked the way the Home Screen masks it, the current one checked.
struct AppIconPickerView: View {
    @State private var current = AppIconOption(iconName: UIApplication.shared.alternateIconName)
    @State private var failed = 0

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: Space.m, alignment: .top)]

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: Space.m) {
                    ForEach(AppIconOption.allCases) { option in
                        Button { choose(option) } label: { cell(option) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.name)
                            .accessibilityAddTraits(option == current ? .isSelected : [])
                    }
                }
                .padding(.vertical, Space.xs)
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: current)
        .sensoryFeedback(.error, trigger: failed)
    }

    private func cell(_ option: AppIconOption) -> some View {
        VStack(spacing: Space.xs) {
            Image(option.preview)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(.rect(cornerRadius: 72 * 0.2237, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 72 * 0.2237, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
                .padding(3)
                .overlay {
                    if option == current { RoundedRectangle(cornerRadius: 72 * 0.2237 + 3, style: .continuous).strokeBorder(.tint, lineWidth: 2.5) }
                }
            HStack(spacing: 3) {
                if option == current { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.tint) }
                Text(option.name).font(.caption).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
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
