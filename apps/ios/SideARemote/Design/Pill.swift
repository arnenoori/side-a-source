import SwiftUI

/// The quiet confirmation at the bottom: a result with nothing else on screen to show it ("Restarted"), and the one Undo
/// notice every list action shares. One at a time; a new one replaces the old. No haptic: the action that caused it had one.
@Observable
final class Pill {
    nonisolated deinit {}

    static let shared = Pill()
    static let undoWindow: Duration = .seconds(5)

    struct Item: Identifiable {
        let id = UUID()
        let text: String
        let undo: (() -> Void)?
        /// Runs once the Undo can no longer be taken: for work held back until then, like deleting a discarded draft's photos.
        var expired: (() -> Void)?
        /// A spinner leads and the pill stays until its work reports (`Pill.working`).
        var working = false
    }

    private(set) var current: Item?
    /// Set by the tab view while the waiting accessory shows, so the pill sits above it rather than on it.
    var aboveAccessory = false
    /// Where a composer at the bottom of the screen starts, in global coordinates, while one shows: the pill sits above it.
    var composerTop: CGFloat?
    @ObservationIgnored private var hiding: Task<Void, Never>?

    /// Shows `text` for 2 s, or 5 s with an Undo to reach for.
    static func show(_ text: String, undo: (() -> Void)? = nil) { _ = shared.show(text, undo: undo) }

    /// The Undo notice. `expired` runs if Undo isn't taken, including when another notice replaces this one or `end` takes
    /// it down.
    @discardableResult
    static func undoable(_ text: String, expired: (() -> Void)? = nil, undo: @escaping () -> Void) -> Item.ID {
        shared.show(text, undo: undo, expired: expired)
    }

    /// A spinner and one word while a call runs, until `show` or `end` replaces it. Returns what to end it with.
    @discardableResult
    static func working(_ text: String) -> Item.ID { shared.working(text) }

    /// Takes the working pill down, unless something newer already replaced it.
    static func end(_ id: Item.ID) { shared.end(id) }

    func working(_ text: String) -> Item.ID {
        let item = Item(text: text, undo: nil, working: true)
        replace(with: item)
        hiding?.cancel()
        return item.id
    }

    func end(_ id: Item.ID) {
        if current?.id == id { dismiss() }
    }

    @discardableResult
    func show(_ text: String, undo: (() -> Void)? = nil, expired: (() -> Void)? = nil) -> Item.ID {
        let item = Item(text: text, undo: undo, expired: expired)
        replace(with: item)
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: undo == nil ? .seconds(2) : Self.undoWindow)
            guard !Task.isCancelled, self?.current?.id == item.id else { return }
            self?.dismiss()
        }
        return item.id
    }

    func undo() {
        guard let item = current, let undo = item.undo else { return }
        hiding?.cancel()
        current = nil
        undo()
    }

    func dismiss() {
        hiding?.cancel()
        let gone = current
        current = nil
        gone?.expired?()
    }

    private func replace(with item: Item) {
        let gone = current
        current = item
        gone?.expired?()
    }
}

/// Where the pill shows: above the bottom bars, over every screen.
struct PillOverlay: View {
    @State private var pill = Pill.shared
    @State private var bottom: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer()
            if let item = pill.current {
                HStack(spacing: item.working ? Space.s : Space.m) {
                    if item.working { ProgressView().controlSize(.small) }
                    Text(item.text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if item.undo != nil {
                        Button("Undo") { pill.undo() }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                            .keyboardShortcut("z", modifiers: .command)
                    }
                }
                .padding(.horizontal, Space.l)
                .frame(minHeight: 44)
                // Tinted near-opaque: rows behind it mustn't read through.
                .glassEffect(.regular.tint(Color(.tertiarySystemBackground).opacity(0.9)).interactive(), in: .capsule)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
                .padding(.horizontal, Space.l)
                // 12 pt clear of the tab bar's top, or of the accessory's, or of a composer.
                .padding(.bottom, pill.composerTop.map { max(bottom - $0, 0) + 12 } ?? (pill.aboveAccessory ? 117 : 61))
                .id(item.id)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityAction(named: "Undo") { pill.undo() }
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom = $0 }
        .animation(Motion.snappy(reduceMotion), value: pill.current?.id)
        .allowsHitTesting(pill.current?.undo != nil)
        .onChange(of: pill.current?.id) { _, id in
            guard id != nil, let item = pill.current else { return }
            AccessibilityNotification.Announcement(item.undo == nil ? item.text : "\(item.text). Undo available.").post()
        }
    }
}

extension View {
    /// For a composer pinned to the bottom of the screen: the pill sits above it while it shows.
    func pillClearance() -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { Pill.shared.composerTop = $0 }
            .onDisappear { Pill.shared.composerTop = nil }
    }
}
