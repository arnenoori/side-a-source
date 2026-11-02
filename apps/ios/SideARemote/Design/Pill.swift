import SwiftUI

/// The quiet confirmation at the bottom: a result with nothing else on screen to show it ("Restarted"), and Undo
/// where the Mac allows one. One at a time; a new one replaces the old. No haptic: the action that caused it had one.
@Observable
final class Pill {
    nonisolated deinit {}

    static let shared = Pill()

    struct Item: Identifiable {
        let id = UUID()
        let text: String
        let undo: (() -> Void)?
    }

    private(set) var current: Item?
    /// Set by the tab view while the waiting accessory shows, so the pill sits above it rather than on it.
    var aboveAccessory = false
    @ObservationIgnored private var hiding: Task<Void, Never>?

    /// Shows `text` for 2 s, or 4 s with an Undo to reach for.
    static func show(_ text: String, undo: (() -> Void)? = nil) { shared.show(text, undo: undo) }

    func show(_ text: String, undo: (() -> Void)? = nil) {
        let item = Item(text: text, undo: undo)
        current = item
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(undo == nil ? 2 : 4))
            guard !Task.isCancelled, self?.current?.id == item.id else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        hiding?.cancel()
        current = nil
    }
}

/// Where the pill shows: above the bottom bars, over every screen.
struct PillOverlay: View {
    @State private var pill = Pill.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer()
            if let item = pill.current {
                HStack(spacing: Space.m) {
                    Text(item.text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let undo = item.undo {
                        Button("Undo") {
                            undo()
                            pill.dismiss()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                    }
                }
                .padding(.horizontal, Space.l)
                .frame(minHeight: 44)
                // Tinted near-opaque: rows behind it mustn't read through.
                .glassEffect(.regular.tint(Color(.tertiarySystemBackground).opacity(0.9)).interactive(), in: .capsule)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
                .padding(.horizontal, Space.l)
                // 12 pt clear of the tab bar's top, or of the accessory's.
                .padding(.bottom, pill.aboveAccessory ? 117 : 61)
                .id(item.id)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.snappy(reduceMotion), value: pill.current?.id)
        .allowsHitTesting(pill.current?.undo != nil)
        .onChange(of: pill.current?.id) { _, id in
            if id != nil, let text = pill.current?.text { AccessibilityNotification.Announcement(text).post() }
        }
    }
}
