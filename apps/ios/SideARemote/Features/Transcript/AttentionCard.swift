import SideAProtocol
import SwiftUI

/// The Mac's `hosted.attention` for a hosted session: something on its screen needs a person, so the card says what and
/// opens the terminal. Side A never presses Enter on ambiguity (hosting.md), so the decision is the user's.
struct AttentionCard: View {
    let attention: HostedAttention
    @Environment(AppModel.self) private var model
    @Environment(SessionActions.self) private var actions
    @State private var trusting = false
    @State private var failure: String?

    /// Only the Mac's trust call starts the agent; it needs Face ID, so never from the Lock Screen.
    private var canTrust: Bool { attention.kind == .trust && model.tools.can(.hostedTrust) && model.tools.hosted[attention.name] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label(attention.title, systemImage: attention.symbol)
                .font(.subheadline.weight(.semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(attention.title)
                .accessibilityAddTraits(.isHeader)
            if let detail = attention.detail {
                Text(detail)
                    .font(attention.kind == .trust ? .footnote : .footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            // Side by side while both fit on one line each; stacked at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s) { buttons }
                VStack(alignment: .leading, spacing: Space.xs) { buttons }
            }
            .controlSize(.small)
            .padding(.top, Space.xxs)
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.inlineCard, style: .continuous))
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.error, trigger: failure) { _, new in new != nil }
    }

    @ViewBuilder private var buttons: some View {
        if canTrust {
            Button(action: trust) {
                Label("Trust and Start", systemImage: "checkmark.shield")
                    .opacity(trusting ? 0 : 1)
                    .overlay { if trusting { ProgressView() } }
            }
            .buttonStyle(.glassProminent)
            .disabled(trusting)
        }
        if model.tools.can(.terminal) {
            Button("Open Terminal", systemImage: "terminal") { actions.on(model).openTerminal(attention.name) }
                .buttonStyle(.glass)
        }
    }

    private func trust() {
        trusting = true; failure = nil
        Task {
            defer { trusting = false }
            do { try await model.tools.trust(attention.name) }
            catch ToolError.cancelled {}
            catch { failure = MacTools.message(error) }
        }
    }
}

extension HostedAttention {
    /// The Mac's own sentence ("It may not have been sent."), except for trust, whose text is the dialog's question.
    var title: String {
        if kind == .trust { return "Waiting for you to trust this folder" }
        return lines.first ?? (kind == .unsent ? "It may not have been sent." : "Look at the session.")
    }

    /// The trust dialog's question, or screen lines after the first.
    var detail: String? {
        let rest = kind == .trust ? lines : Array(lines.dropFirst())
        return rest.isEmpty ? nil : rest.joined(separator: "\n")
    }

    private var lines: [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var symbol: String {
        switch kind {
        case .trust: "folder.badge.questionmark"
        case .unsent: "arrow.uturn.backward"
        default: "exclamationmark.bubble"
        }
    }
}
