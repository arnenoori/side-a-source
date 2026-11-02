import SideAProtocol
import SideARemoteShared
import SwiftUI

/// An open request as the transcript's last item: an amber-tinted card with the headline, the
/// command, and Allow / Deny inline. Tapping elsewhere on it opens the approval sheet (section 4.3).
struct RequestCard: View {
    @Environment(AppModel.self) private var model
    @Environment(ApprovalPresenter.self) private var approvals
    let request: RemoteRequest
    /// All of what Allow approves fits on the card; past `limit` it's cut, and Allow waits for the sheet.
    @State private var whole = true
    @ScaledMetric(relativeTo: .callout) private var limit: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
                Button {
                    approvals.request = request
                } label: {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(RequestText.visible(request.cardHeadline)).font(.headline)
                        if request.risk == .destructive { RiskLabel(reason: request.riskReason) }
                        if let plan = request.plan {
                            // The plan's opening, faded out; the sheet has the rest.
                            MarkdownView(RequestText.visible(plan), sourceID: "card-\(request.id)")
                                .frame(maxHeight: 140, alignment: .top)
                                .clipped()
                                .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                                                     startPoint: .top, endPoint: .bottom))
                                .allowsHitTesting(false)
                        } else {
                            RequestPayload(request: request)
                                .fixedSize(horizontal: false, vertical: true)
                                .onGeometryChange(for: Bool.self) { $0.size.height <= limit } action: { whole = $0 }
                                .frame(maxHeight: whole ? nil : limit, alignment: .top)
                                .clipped()
                                .mask(LinearGradient(stops: [.init(color: .black, location: whole ? 1 : 0.7), .init(color: whole ? .black : .clear, location: 1)],
                                                     startPoint: .top, endPoint: .bottom))
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the request")

                GlassEffectContainer(spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        Spacer()
                        if request.plan != nil {
                            Button {
                                approvals.request = request
                            } label: {
                                Text("Review Plan").fontWeight(.semibold).frame(minWidth: 72)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(.amber)
                        } else {
                            Button {
                                model.requests.answer(request.id, .deny(message: nil))
                            } label: {
                                Text("Deny").frame(minWidth: 72)
                            }
                            .buttonStyle(.glass)
                            // Cut here or by the Mac: Allow waits for the sheet, which shows all of it.
                            if !whole || request.truncated {
                                Button {
                                    approvals.request = request
                                } label: {
                                    Text("Review").fontWeight(.semibold).frame(minWidth: 72)
                                }
                                .buttonStyle(.glassProminent)
                                .tint(.amber)
                                .accessibilityHint("Shows all of it, with Allow")
                            } else if request.allowGate == .biometric {
                                Button {
                                    approvals.request = request
                                } label: {
                                    Text("Allow…").foregroundStyle(Color.destructive).frame(minWidth: 72)
                                }
                                .buttonStyle(.glass)
                            } else if let mode = request.switchMode {
                                // Hold for Allow + Accept Edits, as the Mac's card offers it beside Allow.
                                Menu {
                                    Button(request.switchTitle, systemImage: "checkmark.circle") {
                                        model.requests.answer(request.id, .allow(confirmDestructive: false), mode: mode)
                                    }
                                } label: {
                                    Text("Allow").fontWeight(.semibold).frame(minWidth: 72)
                                } primaryAction: {
                                    model.requests.answer(request.id, .allow(confirmDestructive: false))
                                }
                                .buttonStyle(.glassProminent)
                                .tint(.amber)
                                .accessibilityHint("Touch and hold for \(request.switchTitle)")
                            } else {
                                Button {
                                    model.requests.answer(request.id, .allow(confirmDestructive: false))
                                } label: {
                                    Text("Allow").fontWeight(.semibold).frame(minWidth: 72)
                                }
                                .buttonStyle(.glassProminent)
                                .tint(.amber)
                            }
                        }
                    }
                    .controlSize(.large)
                    .needsMac()
                }
        }
        .padding(Space.m)
        .background(Color.amber.opacity(0.09), in: .rect(cornerRadius: Radius.inlineCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.inlineCard, style: .continuous)
                .strokeBorder(Color.amber.opacity(0.35), lineWidth: 0.5)
        }
        .zoomSource("request-\(request.id)")
        .accessibilityElement(children: .contain)
    }
}

extension RemoteRequest {
    /// Allow and switch mode, as the Mac offers it: the request's best mode, when Allow itself needs no Face ID and
    /// the mode doesn't raise.
    var switchMode: PermissionMode? {
        guard answers.contains(.allowMode), allowGate != .biometric, let mode = modes?.first, !mode.raises else { return nil }
        return mode
    }

    /// "Allow + Accept Edits", the Mac's words.
    var switchTitle: String { switchMode.map { $0 == .acceptEdits ? "Allow + Accept Edits" : "Allow + \($0.title)" } ?? "Allow" }

    /// The plan's Markdown, for ExitPlanMode.
    var plan: String? { if case .plan(let markdown) = action { markdown } else { nil } }

    /// "Allow Bash?", "Allow edit to Island.swift?".
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

/// An answered request or question folded to one line; tap unfolds it read-only.
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
                    // Once, when the Mac has it.
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

    /// The second line while the answer isn't settled.
    private var status: String? {
        switch answered.delivery {
        case .sending: "Sending…"
        case .delivered: nil
        case .answeredElsewhere: "Answered on the Mac first"
        case .unknown: "May not have reached the Mac"
        case .gone: "No longer open on the Mac"
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
        // Keep Planning sends the feedback as a deny.
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
