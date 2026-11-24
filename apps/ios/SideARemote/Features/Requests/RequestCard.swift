import SideAProtocol
import SideARemoteShared
import SwiftUI

extension RemoteRequest {
    /// The rule that lasts only until the session ends, when the host offers one and Allow needs no Face ID.
    var sessionRule: RemoteSuggestion? {
        allowGate != .biometric && answers.contains(.always) ? suggestions.first { $0.scope == .session } : nil
    }

    var switchMode: PermissionMode? {
        guard answers.contains(.allowMode), allowGate != .biometric, let mode = modes?.first, !mode.raises else { return nil }
        return mode
    }

    var switchTitle: String { switchMode.map { $0 == .acceptEdits ? "Allow + Accept Edits" : "Allow + \($0.title)" } ?? "Allow" }

    var plan: String? { if case .plan(let markdown) = action { markdown } else { nil } }

    var cardHeadline: String {
        switch action {
        case .command: "Allow \(tool)?"
        case .edit(let path, _, _), .write(let path, _): "Allow edit to \((path as NSString).lastPathComponent)?"
        case .fetch: "Allow \(tool)?"
        case .plan: "Review the plan"
        default: headline.hasSuffix("?") ? headline : headline + "?"
        }
    }
}

struct RiskLabel: View {
    let reason: String?

    var body: some View {
        Label(reason ?? "Destructive", systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.destructive, in: .capsule)
    }
}

struct AnsweredLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let answered: TranscriptStore.AnsweredRequest
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(RequestText.visible(answered.request.headline)).font(.subheadline.weight(.medium))
                Text(RequestText.visible(answered.request.detail)).font(.footnote.monospaced()).foregroundStyle(.secondary)
            }
            .padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(iconStyle)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: answered.delivery == .delivered)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(statusStyle)
                            .transition(.opacity)
                    }
                }
                if answered.delivery == .unknown {
                    Spacer(minLength: Space.xs)
                    Button("Retry") { model.transcripts.onRetry?(answered) }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
            .animation(Motion.smooth(reduceMotion), value: answered.delivery)
        }
        .disclosureGroupStyle(QuietDisclosureStyle())
    }

    private var status: String? {
        switch answered.delivery {
        case .sending: "Sending…"
        case .delivered: nil
        case .answeredElsewhere: "Answered on \(model.mac.kind.the(model.mac.name)) first"
        case .unknown: "May not have reached \(model.mac.kind.the(model.mac.name))"
        case .gone: "No longer open on \(model.mac.kind.the(model.mac.name))"
        case .failed(let message): "Not sent · \(message)"
        }
    }

    private var statusStyle: AnyShapeStyle {
        switch answered.delivery {
        case .unknown: AnyShapeStyle(Color.amberText)
        case .failed: AnyShapeStyle(Color.destructive)
        default: AnyShapeStyle(.tertiary)
        }
    }

    private var line: String {
        switch answered.outcome {
        case .denied where answered.request.plan != nil: return "Kept planning"
        case .allowed, .denied, .elsewhere:
            if case .command(let command) = answered.request.action { return "\(answered.outcome.line) · \(answered.request.tool) \(command)" }
            return "\(answered.outcome.line) · \(answered.request.headline)"
        default: return answered.outcome.line
        }
    }

    private var icon: String {
        switch (answered.delivery, answered.outcome) {
        case (.sending, _): "arrow.up.circle"
        case (.unknown, _), (.failed, _): "exclamationmark.circle"
        case (.gone, _): "questionmark.circle"
        case (_, .denied): "xmark.circle"
        case (_, .elsewhere): "checkmark.circle"
        default: "checkmark.circle.fill"
        }
    }

    private var iconStyle: AnyShapeStyle {
        switch (answered.delivery, answered.outcome) {
        case (.sending, _): AnyShapeStyle(.tertiary)
        case (.unknown, _): AnyShapeStyle(Color.amber)
        case (.failed, _): AnyShapeStyle(Color.destructive)
        case (_, .denied), (_, .elsewhere): AnyShapeStyle(.secondary)
        default: AnyShapeStyle(Color.done)
        }
    }
}
