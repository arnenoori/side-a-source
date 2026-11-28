import SideAProtocol
import SideARemoteShared
import SwiftUI

struct ApprovalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.windowSize) private var windowSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: RemoteRequest
    @State private var current: RequestID?
    @State private var allows = 0
    @State private var denies = 0
    @State private var failures = 0
    @State private var settled = 0
    /// The last request was answered here and the sheet is closing: nothing was answered elsewhere.
    @State private var leaving = false
    @State private var forward = true
    static var felt: Set<RequestID> = []
    @State private var feedback: String?
    @FocusState private var feedbackFocused: Bool
    @State private var fitted: CGFloat = 0
    @State private var detent: PresentationDetent = .medium
    @State private var whole: [RequestID: RemoteRequest] = [:]
    @State private var unreadable: Set<RequestID> = []

    private var open: [RemoteRequest] { model.requests.open.filter { !$0.isQuestion } }
    private var shown: RemoteRequest? { Self.shown(current ?? request.id, in: open) }

    /// The request on screen, while it's open. One settled elsewhere shows as answered for a beat rather than giving
    /// way at once to the next, so a thumb already on Allow never lands on a request it didn't read.
    static func shown(_ id: RequestID, in open: [RemoteRequest]) -> RemoteRequest? { open.first { $0.id == id } }

    static func next(after id: RequestID, in open: [RemoteRequest]) -> RequestID? {
        guard let position = open.firstIndex(where: { $0.id == id }) else { return open.first?.id }
        return open.indices.contains(position + 1) ? open[position + 1].id : position > 0 ? open[position - 1].id : nil
    }

    static func neighbor(of id: RequestID, by offset: Int, in open: [RemoteRequest]) -> RequestID? {
        guard let position = open.firstIndex(where: { $0.id == id }), open.indices.contains(position + offset) else { return nil }
        return open[position + offset].id
    }

    static func pageOffset(for translation: CGSize) -> Int? {
        guard abs(translation.width) > 60, abs(translation.width) > abs(translation.height) * 2 else { return nil }
        return translation.width < 0 ? 1 : -1
    }

    private func swipe(_ drag: DragGesture.Value) {
        guard let offset = Self.pageOffset(for: drag.translation), let shown,
              let id = Self.neighbor(of: shown.id, by: offset, in: open) else { return }
        page(to: id, forward: offset > 0)
    }

    private func page(to id: RequestID, forward: Bool) {
        self.forward = forward
        withAnimation(Motion.snappy(reduceMotion)) { current = id }
    }

    var body: some View {
        Group {
            if let shown {
                content(whole[shown.id] ?? shown)
                    .id(shown.id)
                    .transition(reduceMotion ? .opacity : .push(from: forward ? .trailing : .leading))
            } else if !leaving {
                answeredElsewhere
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { swipe($0) })
        .presentationDetents(detents, selection: $detent)
        .onChange(of: detents) { _, detents in if !detents.contains(detent), let first = detents.first { detent = first } }
        .presentationDragIndicator(.visible)
        .closesOnEscape()
        .task(id: shown?.id) { await fetchWhole() }
        .sensoryFeedback(.success, trigger: allows)
        .sensoryFeedback(.impact(flexibility: .rigid), trigger: denies)
        .sensoryFeedback(.error, trigger: failures)
        .sensoryFeedback(.success, trigger: settled)
        .sensoryFeedback(.selection, trigger: current)
    }

    private var detents: Set<PresentationDetent> {
        guard shown?.plan == nil else { return [.large] }
        return fitted > 0 ? [.height(fitted), .large] : [.medium, .large]
    }

    private func content(_ request: RemoteRequest) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: 6) {
                Image(systemName: request.agent.symbol).font(.footnote)
                Text([request.agent.title, request.project, request.accountName].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .lineLimit(1)
                Spacer()
                if open.count > 1, let position = open.firstIndex(of: request) {
                    pager(position)
                }
            }
            .foregroundStyle(.secondary)

            Text(RequestText.visible(request.cardHeadline))
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilitySortPriority(1)

            if request.risk == .destructive { RiskLabel(reason: request.riskReason) }

            if let plan = request.plan {
                ScrollView {
                    MarkdownView(RequestText.visible(plan), sourceID: "plan-\(request.id)")
                        .padding(.bottom, Space.s)
                }
                .scrollBounceBehavior(.basedOnSize)
                planButtons(request)
            } else {
                payload(request)
                buttons(request)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.s)
        .fixedSize(horizontal: false, vertical: request.plan == nil)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            guard request.plan == nil, abs(height - fitted) > 1 else { return }
            let follow = detent != .large
            fitted = height
            if follow { detent = .height(height) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .zoomDestination("request-\(request.id)")
    }

    private func payload(_ request: RemoteRequest) -> some View {
        ViewThatFits(in: .vertical) {
            payloadText(request)
            ScrollView { payloadText(request) }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicatorsFlash(onAppear: true)
        }
        .frame(maxHeight: Self.payloadLimit(request, window: windowSize.height))
    }

    static func payloadLimit(_ request: RemoteRequest, window: CGFloat) -> CGFloat {
        let change = switch request.action { case .edit, .write, .patch: true; default: false }
        return (window * (change ? 0.45 : 1.0 / 3)).rounded()
    }

    private func payloadText(_ request: RemoteRequest) -> some View {
                VStack(alignment: .leading, spacing: Space.s) {
                    if let reason = request.reason {
                        Text(RequestText.visible(reason)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    RequestPayload(request: request)
                }
    }

    private func pager(_ position: Int) -> some View {
        HStack(spacing: Space.xs) {
            Button("Previous", systemImage: "chevron.left") { page(to: open[max(position - 1, 0)].id, forward: false) }
                .disabled(position == 0)
            Text("\(position + 1) of \(open.count)").font(.footnote.monospacedDigit())
            Button("Next", systemImage: "chevron.right") { page(to: open[min(position + 1, open.count - 1)].id, forward: true) }
                .disabled(position == open.count - 1)
        }
        .labelStyle(IconTarget(horizontal: 12, vertical: 12))
        .buttonStyle(.borderless)
    }

    /// A cut request can be denied, but not allowed until all of it shows.
    private func cut(_ request: RemoteRequest) -> Bool { request.truncated && whole[request.id] == nil }

    private func fetchWhole() async {
        guard let shown, shown.truncated, whole[shown.id] == nil, let engine = model.link?.engine else { return }
        unreadable.remove(shown.id)
        do {
            whole[shown.id] = try await engine.client.request(shown.id)
        } catch {
            RemoteLog.log(.app, "whole request not loaded: \(error)")
            unreadable.insert(shown.id)
        }
    }

    @ViewBuilder private func buttons(_ request: RemoteRequest) -> some View {
        if cut(request) {
            Label(unreadable.contains(request.id) ? "Couldn't load all of it" : "Loading all of it…",
                  systemImage: unreadable.contains(request.id) ? "exclamationmark.triangle" : "arrow.down.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if unreadable.contains(request.id) {
                Button("Try Again") { Task { await fetchWhole() } }.font(.footnote.weight(.semibold))
            }
        }
        GlassEffectContainer(spacing: Space.s) {
            VStack(spacing: Space.s) {
                if request.allowGate == .biometric {
                    button("Deny", prominent: false) { deny(request) }
                    button("Allow…", prominent: false, destructive: true) { Task { await allowDestructive(request) } }
                        .disabled(cut(request))
                } else {
                    button("Allow", prominent: true) { answer(request, .allow(confirmDestructive: false)) }
                        .disabled(cut(request))
                    if let mode = request.switchMode {
                        button(request.switchTitle, prominent: false) { answer(request, .allow(confirmDestructive: false), mode: mode) }
                            .disabled(cut(request))
                            .accessibilityHint("Allows this, and lets it make the rest of its edits without asking")
                    }
                    button("Deny", prominent: false) { deny(request) }
                }
            }
        }
        if request.allowGate != .biometric, !cut(request), request.answers.contains(.always) {
            ForEach(request.suggestions) { suggestion in
                Button {
                    answer(request, .always(suggestionID: suggestion.id))
                } label: {
                    Text(Self.ruleInMono(RequestText.visible(suggestion.title)))
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(minHeight: 32)
            }
        }
    }

    @ViewBuilder private func planButtons(_ request: RemoteRequest) -> some View {
        if let text = feedback {
            HStack(spacing: Space.xs) {
                TextField("What should change?", text: Binding { text } set: { feedback = $0 }, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($feedbackFocused)
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
                Button("Send", systemImage: "arrow.up") {
                    let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    feedback = nil
                    answer(request, .deny(message: reason.isEmpty ? nil : reason))
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.amber)
                .controlSize(.large)
                .needsMac()
            }
            .onAppear { feedbackFocused = true }
        } else {
            GlassEffectContainer(spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Button {
                        feedback = ""
                    } label: {
                        Text("Keep Planning").frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.glass)
                    HStack(spacing: 2) {
                        Button {
                            answer(request, .approvePlan(acceptEdits: false))
                        } label: {
                            Text("Approve").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 34)
                        }
                        Menu {
                            Button("Approve and Accept Edits") {
                                answer(request, .approvePlan(acceptEdits: true))
                            }
                        } label: {
                            Image(systemName: "chevron.down").fontWeight(.semibold).frame(minHeight: 34)
                        }
                        .accessibilityLabel("More ways to approve")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.amber)
                }
                .controlSize(.large)
                .needsMac()
            }
        }
    }

    static func ruleInMono(_ title: String) -> AttributedString {
        var text = AttributedString(title)
        if let match = title.firstMatch(of: /\S+\([^)]*\)/),
           let range = Range(match.range, in: text) {
            text[range].font = .footnote.monospaced()
        }
        return text
    }

    @ViewBuilder
    private func button(_ title: String, prominent: Bool, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        let label = Text(title)
            .fontWeight(prominent ? .semibold : .regular)
            .foregroundStyle(destructive ? AnyShapeStyle(Color.destructive) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, minHeight: 34)
        if prominent {
            Button(action: action) { label }.buttonStyle(.glassProminent).tint(.amber).controlSize(.large).needsMac()
        } else {
            Button(action: action) { label }.buttonStyle(.glass).controlSize(.large).needsMac()
        }
    }

    static let settleHold = Duration.milliseconds(250)

    private var answeredElsewhere: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(Color.done)
            Text("Answered").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { settled += 1 }
        .task {
            try? await Task.sleep(for: Self.settleHold)
            guard let next = open.first else { return dismiss() }
            page(to: next.id, forward: true)
        }
    }

    private func deny(_ request: RemoteRequest) { answer(request, .deny(message: nil)) }

    private func answer(_ request: RemoteRequest, _ answer: RemoteAnswer, mode: PermissionMode? = nil, confirm: String? = nil) {
        if case .deny = answer { denies += 1 } else { allows += 1 }
        Self.felt.insert(request.id)
        current = Self.next(after: request.id, in: open)
        leaving = open.allSatisfy { $0.id == request.id }
        model.requests.answer(request.id, answer, mode: mode, confirm: confirm)
        if open.isEmpty { dismiss() }
    }

    private func allowDestructive(_ request: RemoteRequest) async {
        switch await FaceIDAllow.ask(for: request, on: model) {
        case .granted(let confirm): answer(request, .allow(confirmDestructive: true), confirm: confirm)
        case .cancelled: break
        case .failed: failures += 1
        }
    }
}
