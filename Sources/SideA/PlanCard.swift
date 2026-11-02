import SideACore
import SideAProtocol
import SwiftUI

/// The turn's live plan (Codex `turn/plan/updated`) above the field, read from the phone's row: folded to the step in
/// progress and how far along it is, open to every step, as the phone's PlanCard.
struct PlanCard: View {
    let plan: TurnPlan
    @State private var open: Bool

    init(plan: TurnPlan, open: Bool = false) {
        self.plan = plan
        _open = State(initialValue: open)
    }

    var body: some View {
        let current = plan.current
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(Ink.ease) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "list.bullet.clipboard").foregroundStyle(.secondary)
                    Text(open || current == nil ? "Plan" : (current?.activeForm ?? current?.text ?? "")).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(plan.done) of \(plan.steps.count)").monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 0 : 180))
                }
                .font(.system(size: 12.5))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Plan, \(plan.done) of \(plan.steps.count) done" + (current.map { ", now \($0.text)" } ?? ""))
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if let explanation = plan.explanation, !explanation.isEmpty {
                        Text(explanation).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in PlanStep(step: step) }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line))
        .animation(Ink.ease, value: plan)
    }
}

private struct PlanStep: View {
    let step: TranscriptTodo

    var body: some View {
        Label {
            Text(step.text).strikethrough(step.status == .completed)
                .foregroundStyle(step.status == .completed ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(step.status == .inProgress ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .font(.system(size: 12.5))
        .accessibilityLabel("\(step.text), \(step.status == .completed ? "done" : step.status == .inProgress ? "in progress" : "to do")")
    }

    private var symbol: String {
        switch step.status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted.circle"
        default: "circle"
        }
    }
}
