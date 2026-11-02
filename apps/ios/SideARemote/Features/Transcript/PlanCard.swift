import SideAProtocol
import SwiftUI

/// The turn's live plan (Codex `turn/plan/updated`) above the field: folded to the step in progress and how far along
/// it is, open to every step.
struct PlanCard: View {
    let plan: TurnPlan
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var done: Int { plan.done }
    private var current: TranscriptTodo? { plan.current }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withAnimation(Motion.smooth(reduceMotion)) { open.toggle() }
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "list.bullet.clipboard").foregroundStyle(.secondary)
                    Text(open || current == nil ? "Plan" : (current?.activeForm ?? current?.text ?? ""))
                        .lineLimit(1)
                    Spacer(minLength: Space.xs)
                    Text("\(done) of \(plan.steps.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.up")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 0 : 180))
                }
                .font(.subheadline)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Plan, \(done) of \(plan.steps.count) done" + (current.map { ", now \($0.text)" } ?? ""))
            .accessibilityHint(open ? "Hides the steps" : "Shows every step")
            if open {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if let explanation = plan.explanation, !explanation.isEmpty {
                        Text(explanation).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                        PlanStep(step: step)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.inlineCard, style: .continuous))
        .animation(Motion.smooth(reduceMotion), value: plan)
    }
}

private struct PlanStep: View {
    let step: TranscriptTodo

    var body: some View {
        Label {
            Text(step.text)
                .strikethrough(step.status == .completed)
                .foregroundStyle(step.status == .completed ? .secondary : .primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(step.status == .inProgress ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .font(.subheadline)
        .accessibilityLabel("\(step.text), \(state)")
    }

    private var symbol: String {
        switch step.status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted.circle"
        default: "circle"
        }
    }

    private var state: String {
        switch step.status {
        case .completed: "done"
        case .inProgress: "in progress"
        default: "to do"
        }
    }
}
