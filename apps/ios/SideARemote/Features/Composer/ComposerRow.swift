import SideAProtocol
import SideARemoteKit
import SwiftUI

nonisolated enum ComposerSlot: LayoutValueKey {
    nonisolated enum Kind { case plus, chip, field }
    static let defaultValue = Kind.field
}

/// One layout for both arrangements, so the three keep their identity and glide between them instead of being rebuilt.
struct ComposerRow: Layout {
    var stacked: Bool
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        return CGSize(width: width, height: frames(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = frames(width: bounds.width, subviews: subviews)
        for (subview, rect) in zip(subviews, placed.rects) {
            subview.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY), proposal: ProposedViewSize(rect.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> (rects: [CGRect], height: CGFloat) {
        let kinds = subviews.map { $0[ComposerSlot.self] }
        let plus = subviews.first { $0[ComposerSlot.self] == .plus }?.sizeThatFits(.unspecified) ?? .zero
        let chip = subviews.first { $0[ComposerSlot.self] == .chip }?.sizeThatFits(.unspecified)
        let besideField = plus.width + spacing + (chip.map { $0.width + spacing } ?? 0)
        let fieldWidth = max(stacked ? width : width - besideField, 0)
        let fieldHeight = subviews.first { $0[ComposerSlot.self] == .field }?
            .sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil)).height ?? 0
        let row = max(plus.height, chip?.height ?? 0)
        let height = stacked ? fieldHeight + spacing + row : max(fieldHeight, row)
        let rowBottom = height
        let rects = kinds.map { kind -> CGRect in
            switch kind {
            case .plus:
                return CGRect(x: 0, y: rowBottom - plus.height, width: plus.width, height: plus.height)
            case .chip:
                let size = chip ?? .zero
                return CGRect(x: plus.width + spacing, y: rowBottom - size.height, width: size.width, height: size.height)
            case .field:
                return stacked ? CGRect(x: 0, y: 0, width: fieldWidth, height: fieldHeight)
                    : CGRect(x: besideField, y: height - fieldHeight, width: fieldWidth, height: fieldHeight)
            }
        }
        return (rects, height)
    }
}

struct ModelChip: View {
    let session: RemoteSession
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var model

    static func offers(_ session: RemoteSession, tools: MacTools) -> Bool {
        (session.takesModelSettings && !tools.models(for: session).isEmpty) || tools.otherAgent(for: session) != nil
    }

    /// Where a handoff goes, for VoiceOver: while it waits for Send the chip is only "⇄", so the field keeps its width.
    /// The line under the field says what happens, and the chip shows only while the field is empty.
    static func handoffTarget(draft: HandoffDraft, tools: MacTools) -> String {
        draft.modelID.map { id in tools.models(for: draft.agent).first { $0.id == id }?.title ?? ModelName.short(id) } ?? draft.agent.title
    }

    /// None for "Default": the chip names no model there, so it shows no model's default effort either.
    private static func current(_ session: RemoteSession, tools: MacTools) -> ModelOption? {
        guard let id = tools.settings(of: session).model else { return nil }
        return tools.models(for: session).first { $0.id == id || $0.title == id }
    }

    var body: some View {
        let settings = model.tools.settings(of: session)
        let current = Self.current(session, tools: model.tools)
        let effort = settings.effort ?? current?.defaultEffort
        let draft = model.handoffs[session.id]
        Button { isPresented = true } label: {
            HStack(spacing: 5) {
                if draft != nil {
                    Image(systemName: "arrow.left.arrow.right").font(.body.weight(.medium))
                } else {
                    Text(model.tools.modelTitle(of: session))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                if draft == nil, let effort {
                    Image(systemName: effort.gauge)
                        .font(.footnote.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(.capsule)
            .hoverEffect(.highlight)
        }
        .buttonStyle(ChipStyle(open: isPresented))
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Model")
        .accessibilityValue(draft.map { "Hands off to \(Self.handoffTarget(draft: $0, tools: model.tools)) when you send" }
            ?? [model.tools.modelTitle(of: session), effort.flatMap { $0 == .auto ? nil : $0.title }].compactMap { $0 }.joined(separator: " · "))
        .accessibilityHint("Changes the model and effort")
    }
}

private struct ChipStyle: ButtonStyle {
    let open: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pressedBacking(configuration.isPressed || open, in: Capsule().inset(by: 4))
    }
}

extension Effort {
    /// By how hard, not by place in a model's list, so the same effort looks the same on every model.
    var gauge: String {
        switch self {
        case .auto: "sparkles"
        case .none, .minimal: "gauge.with.dots.needle.0percent"
        case .low: "gauge.with.dots.needle.33percent"
        case .medium: "gauge.with.dots.needle.50percent"
        case .high: "gauge.with.dots.needle.67percent"
        default: "gauge.with.dots.needle.100percent"
        }
    }
}
