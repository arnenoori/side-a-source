import SwiftUI

/// Settings' "App Icon" row: every icon, the picked one ringed.
struct AppIconPicker: View {
    @AppStorage(AppIconChoice.key) private var selected = AppIconChoice.defaultChoice.id

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(AppIconChoice.all) { choice in
                Button { select(choice) } label: { cell(choice) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.name)
                    .accessibilityAddTraits(choice.id == selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private func cell(_ choice: AppIconChoice) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image = choice.preview { Image(nsImage: image).resizable().interpolation(.high) } else { Color.clear }
            }
            .frame(width: 56, height: 56)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: choice.id == selected ? 2.5 : 0))
            Text(choice.name).font(.caption).lineLimit(1)
                .foregroundStyle(choice.id == selected ? Color.primary : Color.secondary)
        }
        .contentShape(Rectangle())
    }

    private func select(_ choice: AppIconChoice) {
        selected = choice.id
        AppIconChoice.apply()
    }
}

/// The 3D player toggle, here so Settings' General tab keeps its size.
struct PlayerToggle: View {
    @AppStorage(MenuPlayer.enabledKey) private var playerEnabled: Bool = PreferencesMirror.fallback(MenuPlayer.enabledKey)

    var body: some View { Toggle("3D player", isOn: $playerEnabled) }
}
