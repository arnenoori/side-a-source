import SideARemoteShared
import SwiftUI

/// Seven swatches in a row, as in Settings › Accessibility › Display: the picked one ringed with a check.
struct AccentPicker: View {
    @AppStorage(Accent.key, store: Accent.store) private var accent = Accent.blue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Accent.allCases) { option in
                Button {
                    withAnimation(Motion.smooth(reduceMotion)) { accent = option }
                } label: {
                    Circle()
                        .fill(option.color.gradient)
                        .frame(width: 30, height: 30)
                        .overlay {
                            if option == accent {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                            }
                        }
                        .padding(3)
                        .overlay { if option == accent { Circle().strokeBorder(option.color, lineWidth: 2) } }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(option == accent ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: accent)
    }
}
