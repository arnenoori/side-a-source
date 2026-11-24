import SideAProtocol
import SideARemoteKit
import SwiftUI

struct ModelChip: View {
    let session: RemoteSession
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var model

    /// Where a handoff goes, for VoiceOver: while it waits for Send the chip is only "⇄", so the field keeps its width.
    /// The line under the field says what happens, and the chip shows only while the field is empty.
    static func handoffTarget(draft: HandoffDraft, tools: MacTools) -> String {
        draft.modelID.map { id in tools.models(for: draft.agent).first { $0.id == id }?.title ?? ModelName.short(id) } ?? draft.agent.title
    }

    /// A session whose model the host doesn't report still says which agent runs it.
    static func family(_ session: RemoteSession, tools: MacTools) -> String {
        let title = tools.modelTitle(of: session)
        return title == "Default" ? session.model.map(ModelName.brief) ?? session.agent.title : ModelName.brief(title)
    }

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
                    Text(Self.family(session, tools: model.tools))
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
            .padding(.leading, Space.xxs)
            .padding(.trailing, Space.s)
            .frame(height: 44)
            .contentShape(.capsule)
            .hoverEffect(.highlight)
        }
        .buttonStyle(ChipStyle(open: isPresented))
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
