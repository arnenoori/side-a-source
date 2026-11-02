import LocalAuthentication
import SideAProtocol
import SideARemoteShared
import SwiftUI

/// The approval sheet (section 4.5): context, headline, risk, payload, then Allow / Deny right under it, the sheet
/// as tall as that and no taller. Pages between requests when several wait. A plan gets the review of section 4.7
/// instead: the Markdown, then Keep Planning and Approve.
struct ApprovalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: RemoteRequest
    @State private var current: RequestID?
    @State private var allows = 0
    @State private var denies = 0
    @State private var failures = 0
    /// Answers this sheet already gave a haptic for, so the transcript behind it doesn't give a second.
    static var felt: Set<RequestID> = []
    @State private var feedback: String?
    @FocusState private var feedbackFocused: Bool
    /// The request's own height, for a sheet that fits it; 0 until measured.
    @State private var fitted: CGFloat = 0
    @State private var detent: PresentationDetent = .medium
    /// Requests the Mac cut to fit the stream (`truncated`), fetched whole; Allow waits for them.
    @State private var whole: [RequestID: RemoteRequest] = [:]
    @State private var unreadable: Set<RequestID> = []

    private var open: [RemoteRequest] { model.requests.open.filter { !$0.isQuestion } }
    private var shown: RemoteRequest? { Self.shown(current ?? request.id, in: open) }

    /// The request on screen, while it's open. One settled elsewhere shows as answered for a beat rather than giving
    /// way at once to the next, so a thumb already on Allow never lands on a request it didn't read.
    static func shown(_ id: RequestID, in open: [RemoteRequest]) -> RemoteRequest? { open.first { $0.id == id } }

    /// Where the sheet goes after answering `id` here: the request after it, else the one before.
    static func next(after id: RequestID, in open: [RemoteRequest]) -> RequestID? {
        guard let position = open.firstIndex(where: { $0.id == id }) else { return open.first?.id }
        return open.indices.contains(position + 1) ? open[position + 1].id : position > 0 ? open[position - 1].id : nil
    }

    var body: some View {
        Group {
            if let shown {
                content(whole[shown.id] ?? shown)
            } else {
                answeredElsewhere
            }
        }
        // As tall as the request, so Allow sits right under the command; large for a plan, or when it doesn't fit.
        .presentationDetents(detents, selection: $detent)
        .onChange(of: detents) { _, detents in if !detents.contains(detent), let first = detents.first { detent = first } }
        .presentationDragIndicator(.visible)
        .task(id: shown?.id) { await fetchWhole() }
        .sensoryFeedback(.success, trigger: allows)
        .sensoryFeedback(.impact(flexibility: .rigid), trigger: denies)
        .sensoryFeedback(.error, trigger: failures)
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
        // Its own height whatever the detent, so the sheet can fit it; a plan scrolls in the large detent instead.
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

    /// The command or change at its own height, scrolling past a third of the screen (nearly half for a change, which
    /// needs the room), so Allow and Deny never leave it.
    private func payload(_ request: RemoteRequest) -> some View {
        ViewThatFits(in: .vertical) {
            payloadText(request)
            ScrollView { payloadText(request) }
                .scrollBounceBehavior(.basedOnSize)
                // There's more below: the indicator says so as the sheet opens.
                .scrollIndicatorsFlash(onAppear: true)
        }
        .frame(maxHeight: Self.payloadLimit(request))
    }

    private static func payloadLimit(_ request: RemoteRequest) -> CGFloat {
        let change = switch request.action { case .edit, .write, .patch: true; default: false }
        return (UIScreen.main.bounds.height * (change ? 0.45 : 1.0 / 3)).rounded()
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
            Button("Previous", systemImage: "chevron.left") { current = open[max(position - 1, 0)].id }
                .disabled(position == 0)
            Text("\(position + 1) of \(open.count)").font(.footnote.monospacedDigit())
            Button("Next", systemImage: "chevron.right") { current = open[min(position + 1, open.count - 1)].id }
                .disabled(position == open.count - 1)
        }
        .labelStyle(.iconOnly)
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
        if request.allowGate != .biometric, !cut(request), let suggestion = request.suggestions.first, request.answers.contains(.always) {
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

    /// Keep Planning opens a field whose text goes back as the deny reason; Approve has a menu for
    /// approving with edits accepted.
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
                    denies += 1
                    Self.felt.insert(request.id)
                    current = Self.next(after: request.id, in: open)
                    model.requests.answer(request.id, .deny(message: reason.isEmpty ? nil : reason))
                    feedback = nil
                    if open.isEmpty { dismiss() }
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
                            Button {
                                answer(request, .approvePlan(acceptEdits: true))
                            } label: {
                                Text("Approve and Accept Edits")
                                Text("Edits won't ask again in this session.")
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

    /// The Mac's sentence ("Always allow Bash(npm test:*) in this project") with only the rule in mono.
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

    private var answeredElsewhere: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(Color.done)
            Text("Answered").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .seconds(1))
            if let next = open.first { current = next.id } else { dismiss() }
        }
    }

    private func answer(_ request: RemoteRequest, _ answer: RemoteAnswer, mode: PermissionMode? = nil) {
        allows += 1
        Self.felt.insert(request.id)
        current = Self.next(after: request.id, in: open)
        model.requests.answer(request.id, answer, mode: mode)
        if open.isEmpty { dismiss() }
    }

    private func deny(_ request: RemoteRequest) {
        denies += 1
        Self.felt.insert(request.id)
        current = Self.next(after: request.id, in: open)
        model.requests.answer(request.id, .deny(message: nil))
        if open.isEmpty { dismiss() }
    }

    /// Destructive Allow needs the device owner: Face ID signs the answer with the confirm key, which the Mac checks.
    /// Within a minute of unlocking the app with Face ID that unlock signs it (`DeviceKeys.adopt`). A pairing from
    /// before the keys falls back to asking here.
    private func allowDestructive(_ request: RemoteRequest) async {
        let allow = RemoteAnswer.allow(confirmDestructive: true)
        // Face ID can't sign anything this Mac accepts; the answer's line says to pair again.
        if model.tools.needsKeys { return answer(request, allow) }
        if let mac = model.link?.mac, DeviceKeys.has(.confirm, for: mac.endpoint.macID),
           let subject = try? ConfirmMessage.subject(requestID: request.id, answer: allow) {
            guard let confirm = await DeviceKeys.header(.confirm, macID: mac.endpoint.macID, deviceID: mac.deviceID, purpose: .allow,
                                                        subject: subject, reason: "Allow \(RequestText.visible(request.detail))") else {
                failures += 1
                return
            }
            allows += 1
            Self.felt.insert(request.id)
            current = Self.next(after: request.id, in: open)
            model.requests.answer(request.id, allow, confirm: confirm)
            if open.isEmpty { dismiss() }
            return
        }
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Allow \(RequestText.visible(request.detail))") else { return }
            answer(request, allow)
        } catch {
            failures += 1
        }
    }
}
