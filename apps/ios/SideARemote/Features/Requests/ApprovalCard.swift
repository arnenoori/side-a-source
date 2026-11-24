import SideAProtocol
import SideARemoteShared
import SwiftUI

struct ApprovalCard: View {
    let request: RemoteRequest
    @Environment(AppModel.self) private var model
    @Environment(ApprovalPresenter.self) private var approvals
    @State private var whole = true
    @ScaledMetric(relativeTo: .callout) private var limit: CGFloat = 96
    @State private var failures = 0
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                approvals.request = request
            } label: {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: Space.xs) {
                        Text(request.plan == nil ? "Approval needed" : "Plan ready")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.amberText)
                        if request.risk == .destructive { RiskLabel(reason: request.riskReason) }
                    }
                    if request.plan == nil { payload }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the request")
            buttons
                .controlSize(.large)
                .needsMac()
        }
        .padding(Space.s)
        .background(Color.amber.opacity(0.12), in: .rect(cornerRadius: 20, style: .continuous))
        .zoomSource("request-\(request.id)")
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.error, trigger: failures)
    }

    @ViewBuilder private var payload: some View {
        if case .command(let command) = request.action {
            Text(RequestText.visible(command))
                .font(.callout.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: Bool.self) { $0.size.height <= limit } action: { whole = $0 }
                .frame(maxHeight: whole ? nil : limit, alignment: .top)
                .clipped()
                .privacySensitive()
        } else {
            RequestPayload(request: request)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: Bool.self) { $0.size.height <= limit } action: { whole = $0 }
                .frame(maxHeight: whole ? nil : limit, alignment: .top)
                .clipped()
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var buttons: some View {
        if request.plan != nil {
            wide("Review Plan", prominent: true) { approvals.request = request }
        } else {
            VStack(spacing: Space.xs) {
                if !request.allowsOnCard(whole: whole) {
                    wide("Review", prominent: true) { approvals.request = request }
                        .accessibilityHint("Shows all of it, with Allow")
                } else if request.allowGate == .biometric {
                    wide("Allow…", prominent: false, destructive: true) { allowWithFaceID() }
                        .disabled(asking)
                        .accessibilityHint("Asks for \(Biometry.current.phrase)")
                } else {
                    wide("Allow Once", prominent: true) { model.requests.answer(request.id, .allow(confirmDestructive: false)) }
                }
                HStack(spacing: Space.xs) {
                    if request.allowsOnCard(whole: whole), let mode = request.switchMode {
                        wide(request.switchTitle, prominent: false) {
                            model.requests.answer(request.id, .allow(confirmDestructive: false), mode: mode)
                        }
                    } else if request.allowsOnCard(whole: whole), let rule = request.sessionRule {
                        wide("Allow for Session", prominent: false) { model.requests.answer(request.id, .always(suggestionID: rule.id)) }
                            .accessibilityHint(RequestText.visible(rule.title))
                    } else if request.allowsOnCard(whole: whole), request.allowGate != .biometric, request.answers.contains(.always),
                              !request.suggestions.isEmpty {
                        wide("Always…", prominent: false) { approvals.request = request }
                            .accessibilityHint("Shows the rule it would always allow")
                    }
                    wide("Deny", prominent: false) { model.requests.answer(request.id, .deny(message: nil)) }
                }
            }
        }
    }

    private func wide(_ title: String, prominent: Bool, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(prominent ? .semibold : .regular)
                .foregroundStyle(destructive ? AnyShapeStyle(Color.destructive) : AnyShapeStyle(prominent ? Color(.systemBackground) : Color(.label)))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(prominent ? Color(.label) : Color(.secondarySystemGroupedBackground), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func allowWithFaceID() {
        asking = true
        Task {
            defer { asking = false }
            switch await FaceIDAllow.ask(for: request, on: model) {
            case .granted(let confirm): model.requests.answer(request.id, .allow(confirmDestructive: true), confirm: confirm)
            case .cancelled: break
            case .failed: failures += 1
            }
        }
    }
}
