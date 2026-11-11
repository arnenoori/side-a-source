import SideAProtocol
import SideARemoteShared
import SwiftUI

/// A session's transcript: plain prose, quiet tool rows, object cards, and the floating
/// composer, with follow mode keeping the latest message in view.
struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ApprovalPresenter.self) private var presenter
    let sessionID: SessionKey
    /// A past conversation from History: read-only, with Resume and Fork in place of the composer.
    var past: PastSession?
    /// A message to scroll to and flash once loaded: a search's match.
    var match: String?
    @State private var flashed: String?
    /// The title while the session was live: an ended session keeps its page readable under its name.
    @State private var lastTitle: String?

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    @State private var showsInfo = false
    @State private var seenCount = 0
    @State private var landed = false
    /// The reader has dragged the transcript since opening it.
    @State private var scrolled = false
    /// A reply that starts after this is written out from its first word; one already there just shows.
    @State private var openedAt = Date.now
    @FocusState private var composerFocused: Bool

    private var session: RemoteSession? { model.sessions.session(sessionID) }
    private var openRequests: [RemoteRequest] { session?.openRequests.compactMap(model.requests.request) ?? [] }
    private var answered: [TranscriptStore.AnsweredRequest] { model.transcripts.answered[sessionID] ?? [] }
    private var draft: String { model.transcripts.drafts[sessionID] ?? "" }
    private var draftBinding: Binding<String> {
        Binding { model.transcripts.drafts[sessionID] ?? "" } set: { model.transcripts.drafts[sessionID] = $0 }
    }

    /// The rows, laid out once per body; the follow badge and the scroll handlers take its count from there.
    private func layout() -> [TranscriptItem] {
        TranscriptLayout.items(messages: model.transcripts.messages[sessionID] ?? [], earlier: model.transcripts.earlier[sessionID] ?? 0,
                               answered: answered, open: openRequests,
                               working: session.map { SessionPhase($0) == .working || SessionPhase($0) == .needsYou } ?? false,
                               outgoing: model.transcripts.outgoing[sessionID] ?? [], mail: session?.mail)
    }

    var body: some View {
        let items = layout()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    row(item)
                        .background {
                            if flashed == item.id {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.tertiarySystemFill))
                                    .padding(-Space.xs)
                            }
                        }
                        .padding(.top, spacing(before: item))
                        .id(item.id)
                        .transition(.opacity)
                }
                if let flag = session?.flag, flag.kind != .bloated, flag.kind != .unsent {
                    HealthCard(flag: flag, session: session, canNote: session?.abilities.contains(.note) == true) {
                        presenter.note = NoteTarget(session: sessionID)
                    }
                    .padding(.top, Space.m)
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xl)
            .animation(.easeOut(duration: 0.2), value: items.last?.id)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .scrollDismissesKeyboard(.interactively)
        // A tap anywhere drops a text selection; a tap inside one still moves it, after this clears the rest.
        .simultaneousGesture(TapGesture().onEnded { SelectableText.clearSelection() })
        .onScrollPhaseChange { _, phase in if phase == .interacting { scrolled = true } }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // The visible part ends one container below the top inset, measured from the offset.
            return geometry.contentOffset.y + geometry.contentInsets.top + geometry.containerSize.height >= geometry.contentSize.height - 40
        } action: { _, isAtBottom in
            atBottom = isAtBottom
            if isAtBottom { seenCount = items.count }
        }
        .safeAreaBar(edge: .top) {
            if let usage {
                Text(usage)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Space.xxs)
                    .contentTransition(.numericText())
                    .animation(Motion.smooth(reduceMotion), value: usage)
            }
        }
        .safeAreaBar(edge: .bottom) {
            if let past {
                ResumeBar(past: past)
            } else {
                VStack(spacing: Space.xs) {
                    if let plan = session?.plan, !plan.steps.isEmpty {
                        PlanCard(plan: plan)
                            .padding(.horizontal, Space.m)
                            .transition(.opacity)
                    }
                    if let attention = session.flatMap(model.tools.attention(for:)) {
                        AttentionCard(attention: attention)
                            .padding(.horizontal, Space.m)
                            .transition(.opacity)
                    }
                    composer(count: items.count)
                }
                .animation(Motion.smooth(reduceMotion), value: session.flatMap(model.tools.attention(for:)))
                .animation(Motion.smooth(reduceMotion), value: session?.plan == nil)
            }
        }
        .navigationTitle(session.map { model.tools.title(for: $0) } ?? past?.title ?? lastTitle ?? "Session")
        .onChange(of: session?.title, initial: true) { _, title in if let title { lastTitle = title } }
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            if let past {
                Button("Copy Conversation ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = past.id }
            } else {
                RenameButton(session: session)
                PinButton(session: session)
                Button("Session Info", systemImage: "info.circle") { showsInfo = true }
            }
        }
        .toolbar { if past == nil { toolbarContent } }
        .toolbarVisibility(.hidden, for: .tabBar)
        .sheet(isPresented: $showsInfo) {
            if let session { SessionInfoSheet(session: session) }
        }
        .sensoryFeedback(trigger: answered.count) { old, new in
            guard new > old, let last = answered.last, ApprovalSheet.felt.remove(last.id) == nil else { return nil }
            switch last.outcome {
            case .denied: return .impact(flexibility: .rigid)
            // Nothing the user did here.
            case .elsewhere: return nil
            default: return .success
            }
        }
        .task {
            // Lazy rows estimate their heights; land on the real end once they're measured. Only on
            // the first appearance: coming back from a pushed page keeps the reader's place.
            guard !landed else { return }
            landed = true
            seenCount = items.count
            await Task.yield()
            position.scrollTo(edge: .bottom)
        }
        .task(id: sessionID) {
            // Live: the newest page, then the Mac's appends, while this transcript is on screen.
            await model.link?.follow(sessionID)
        }
        .task(id: session?.abilities) {
            // The menu's model list: the session's own from the Mac, the options' meanwhile.
            guard let session else { return }
            await model.tools.loadOptions()
            await model.tools.loadModels(for: session)
        }
        .task(id: match) { await reveal() }
        .sessionActions()
    }

    private func composer(count: Int) -> some View {
        Composer(text: draftBinding, placeholder: placeholder, canInterrupt: canInterrupt, showsFollow: !atBottom, follow: followBadge(count: count),
                 focused: $composerFocused, onSend: { send() }, onInterrupt: { model.interrupt(sessionID) },
                 onFollow: { scrollToBottom(count: count) },
                 session: session, steers: Steer.available(for: session), onSteer: steer, disabledReason: disabledReason,
                 unsent: model.transcripts.unsent[sessionID], onRetry: { model.retryUnsent(sessionID) },
                 notice: model.transcripts.notices[sessionID] ?? standingNotice,
                 deliveries: model.deliveries(sessionID), onDeliver: { send(as: $0) },
                 dropped: dropped == nil ? nil : session?.flag?.text, onRetryDropped: retryDropped)
    }

    /// The loaded conversation as Markdown: each turn under who said it, tools left out.
    static func markdown(_ messages: [TranscriptMessage], agent: AgentProvider?) -> String {
        messages.compactMap { message -> String? in
            guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            switch message.role {
            case .user: return "**You:** \(text)"
            case .assistant: return "**\(agent?.title ?? "Claude"):** \(text)"
            default: return nil
            }
        }
        .joined(separator: "\n\n")
    }

    /// Finds the matched message, loading earlier pages until it shows, then scrolls to it and flashes it.
    private func reveal() async {
        guard let match else { return }
        var earlierAsked = 0
        for _ in 0..<60 {
            if let message = model.transcripts.messages[sessionID]?.first(where: { $0.uuid == match }) {
                let id = "m-\(message.seq)"
                // After the first landing at the bottom.
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(Motion.smooth(reduceMotion)) { position.scrollTo(id: id, anchor: .center) }
                withAnimation(.easeOut(duration: 0.15)) { flashed = id }
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.6)) { flashed = nil }
                return
            }
            let earlier = model.transcripts.earlier[sessionID] ?? 0
            if earlier > 0, model.transcripts.messages[sessionID] != nil, earlierAsked < 10 {
                earlierAsked += 1
                model.transcripts.loadEarlier(sessionID)
            }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
    }

    // MARK: Items

    @ViewBuilder private func row(_ item: TranscriptItem) -> some View {
        switch item {
        case .earlier(let count):
            Button {
                model.transcripts.loadEarlier(sessionID)
            } label: {
                Text("\(count) earlier messages")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: .capsule)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            // Scrolled up to it: the earlier page loads without the tap. Never while the transcript is still landing at
            // its end, where a page arriving mid-layout leaves the lazy rows unplaced.
            .onAppear { if scrolled && !atBottom { model.transcripts.loadEarlier(sessionID) } }
        case .separator(let date):
            Text(Formatting.separator(date))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        case .user(let message):
            UserBubble(sessionID: sessionID, message: message)
        case .assistant(let message):
            // Long-press selects text; the whole message's actions sit under the latest reply, once it's written.
            if message.seq == streamingSeq {
                StreamingMarkdown(message.text ?? "", sourceID: "m\(message.seq)",
                                  startEmpty: (message.at ?? 0) > openedAt.timeIntervalSince1970)
            } else {
                VStack(alignment: .leading, spacing: Space.xs) {
                    MarkdownView(model.transcripts.text(message, in: sessionID) ?? "", sourceID: "m\(message.seq)")
                    CutMessageFooter(sessionID: sessionID, message: message)
                    if model.transcripts.messages[sessionID]?.last(where: { $0.role == .assistant })?.seq == message.seq {
                        MessageActions(sessionID: sessionID, message: message)
                    }
                }
            }
        case .tool(let tool):
            ToolRow(sessionID: sessionID, tool: tool)
        case .thinking(let tool):
            ThinkingRow(tool: tool)
        case .group(let group):
            StepGroupRow(sessionID: sessionID, group: group)
        case .diff(let tool, let diff):
            DiffCard(tool: tool, diff: diff)
        case .file(let tool, let path, let bytes):
            FileChip(sessionID: sessionID, tool: tool, path: path, bytes: bytes)
        case .images(let tool):
            ImageTiles(sessionID: sessionID, images: tool.images)
        case .notice(let message):
            Text(message.text ?? "")
                .font(.footnote)
                .foregroundStyle(message.role == .error ? AnyShapeStyle(Color.destructive) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
        case .turnEnd(let end):
            TurnEndRow(end: end)
        case .answered(let answered):
            AnsweredLine(answered: answered)
        case .request(let request):
            RequestCard(request: request)
        case .question(let request):
            QuestionCard(request: request, typed: draftBinding) { composerFocused = true }
        case .outgoing(let turn):
            OutgoingBubble(sessionID: sessionID, turn: turn)
        case .mail(let mail):
            MailLine(sessionID: sessionID, mail: mail)
                .frame(maxWidth: .infinity)
        }
    }

    /// The newest assistant message while the session works: the one still being written.
    private var streamingSeq: Int? {
        guard let session, SessionPhase(session) == .working else { return nil }
        return model.transcripts.messages[sessionID]?.last(where: { $0.role == .assistant })?.seq
    }

    /// Blocks 12 apart, turns 24 apart, tool rows touching (their 44 pt carries the rhythm).
    private func spacing(before item: TranscriptItem) -> CGFloat {
        switch item {
        case .earlier: 0
        case .separator: Space.xl
        case .user, .outgoing: Space.xl
        case .tool, .thinking, .group, .answered: 0
        case .turnEnd: Space.xxs
        default: Space.s
        }
    }

    // MARK: Composer

    private var placeholder: String {
        guard let session else { return "Reply…" }
        if openRequests.contains(where: \.isQuestion) { return "Or type your own answer…" }
        // Through the inbox or a Stop hook, Claude reads it as a note, never as the user's own consent.
        if model.arrivesAsNote(sessionID) { return "Reply · arrives as a note" }
        switch SessionPhase(session) {
        case .working, .needsYou: return "Message…"
        default: return "Reply…"
        }
    }

    /// Under the field while nothing else is: where this session's replies go when that isn't the usual.
    private var standingNotice: String? {
        model.outsideSharedServer(sessionID) ? "Started outside Codex's shared server: replies arrive only after it finishes." : nil
    }

    /// What Codex or Claude dropped, to send again.
    private var dropped: String? { model.droppedReply(sessionID)?.text }

    private func retryDropped() {
        withAnimation(Motion.smooth(reduceMotion)) { model.retryDropped(sessionID) }
    }

    private var canInterrupt: Bool {
        guard let session else { return false }
        return SessionPhase(session) == .working && session.abilities.contains(.interrupt)
    }

    /// Status `unknown` authorizes nothing, so the field says why it's off.
    private var disabledReason: String? {
        if session == nil, lastTitle != nil { return "This session has ended." }
        return session?.status == .unknown ? "\(model.mac.name) can't tell what this session is doing." : nil
    }

    private func steer(_ steer: Steer) {
        switch steer {
        case .interruptNow: model.interrupt(sessionID)
        case .stopBeforeNextStep: model.interrupt(sessionID, when: .nextStep)
        case .note: presenter.note = NoteTarget(session: sessionID)
        }
    }

    private func followBadge(count: Int) -> FollowBadge {
        if !openRequests.isEmpty { return .waiting }
        let fresh = count - seenCount
        return fresh > 0 ? .newMessages(fresh) : .none
    }

    private var subtitle: String {
        if let past { return [past.project, past.branch].compactMap { $0 }.joined(separator: " · ") }
        guard let session else { return "" }
        if let parent = session.hosted.flatMap({ model.tools.forkedFrom[$0] }) { return "Forked from \(parent)" }
        // The model by its name and the mode once it's not Default, as the Mac's chip has them; the account is in Session Info.
        let settings = model.tools.settings(of: session)
        let name = settings.model.map { id in model.tools.models(for: session).first { $0.id == id }?.title ?? id }
        let mode = settings.mode.flatMap { $0 == .default ? nil : $0.title }
        return [session.project, name, mode].compactMap { $0 }.joined(separator: " · ")
    }

    /// "42% context · 2 running", under the title; nil when the Mac reads neither.
    private var usage: String? {
        guard past == nil, let session else { return nil }
        let parts = [session.contextPercent.map { "\(Int($0.rounded()))% context" },
                     session.backgroundTasks.flatMap { $0 > 0 ? "\($0) running" : nil }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `delivery`: picked from Send's long-press; nil is the plain tap, which the Mac's delivery table decides.
    private func send(as delivery: Delivery? = nil) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.transcripts.drafts[sessionID] = ""
        // A waiting question takes the text as its "write your own" answer; a reply would get 409.
        if let question = openRequests.first(where: \.isQuestion), case .question(let questions) = question.action, questions.count == 1 {
            withAnimation(Motion.smooth(reduceMotion)) {
                model.requests.answer(question.id, .answers([QuestionAnswer(question: questions[0].question, picked: [], other: text)]))
            }
            return
        }
        withAnimation(Motion.smooth(reduceMotion)) {
            if let delivery { model.send(text, to: sessionID, as: delivery) } else { model.reply(text, to: sessionID) }
            // The live link took the photos with the reply; the demo has nowhere to send them. Interrupt and Send
            // takes them once its reply goes, after the interrupt.
            if delivery != .interrupt { _ = model.tools.attachments.take(sessionID, for: model.transcripts.outgoing[sessionID]?.last?.id) }
        }
        // After the new turn is laid out, or the scroll stops short of it.
        Task { @MainActor in
            await Task.yield()
            scrollToBottom(count: layout().count)
        }
    }

    private func scrollToBottom(count: Int) {
        withAnimation(Motion.smooth(reduceMotion)) { position.scrollTo(edge: .bottom) }
        seenCount = count
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if session?.hosted != nil, model.tools.can(.terminal) {
            ToolbarItem(placement: .topBarTrailing) {
                TerminalButton(session: session)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis") {
                let steers = Steer.available(for: session)
                if !steers.isEmpty || session?.mail != nil {
                    Section("Steer") {
                        ForEach([Steer.note, .stopBeforeNextStep, .interruptNow].filter(steers.contains), id: \.self) { steer in
                            Button(steer.title, systemImage: steer.symbol) { self.steer(steer) }
                        }
                        if session?.mail != nil {
                            Button("Take Back", systemImage: "arrow.uturn.backward") { model.takeBack(sessionID) }
                        }
                    }
                }
                SettingsMenu(session: session)
                Section {
                    if let session, let turn = session.turnID, session.abilities.contains(.turnDiff) {
                        NavigationLink(value: Route.turnDiff(session.id, turn: turn)) {
                            Label("Changes", systemImage: "plus.forwardslash.minus")
                        }
                    }
                    ReviewButton(session: session)
                    CompactButton(session: session)
                }
                Section("Session") {
                    ForkButton(session: session)
                    RestartButton(session: session)
                    ContinueButton(session: session)
                    QuitButton(session: session)
                }
                if session?.ports?.isEmpty == false, model.tools.can(.ports) {
                    Section("Ports") { PortButtons(session: session) }
                }
                Section {
                    Button("Copy Transcript as Markdown", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = Self.markdown(model.transcripts.wholeMessages(sessionID), agent: session?.agent)
                    }
                    .disabled(model.transcripts.messages[sessionID]?.isEmpty != false)
                }
            }
        }
    }
}

/// A flagged session's note as the last item: the flag's own words and two ways out.
struct HealthCard: View {
    let flag: SessionFlag
    var session: RemoteSession?
    var canNote = true
    var onNote: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label(flag.text, systemImage: flag.kind == .failing ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(flag.kind == .failing ? AnyShapeStyle(Color.destructive) : AnyShapeStyle(.primary))
            HStack(spacing: Space.xs) {
                if canNote { Button(Steer.note.title, action: onNote).buttonStyle(.glass) }
                RestartButton(session: session, title: "Restart Fresh…", symbol: nil).buttonStyle(.glass)
            }
            .controlSize(.regular)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Radius.inlineCard, style: .continuous))
    }
}

/// Everything the Mac knows about a session.
struct SessionInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: RemoteSession

    var body: some View {
        NavigationStack {
            Form {
                if let flag = session.flag {
                    Section { Label(flag.text, systemImage: "exclamationmark.triangle") }
                }
                Section {
                    LabeledContent("Status", value: SessionPhase(session).title)
                    LabeledContent("Agent", value: session.agent.title)
                    if let account = session.accountName { LabeledContent("Account", value: account) }
                    if let model = session.model { LabeledContent("Model", value: [model, session.effort].compactMap { $0 }.joined(separator: " · ")) }
                    if let context = session.context { LabeledContent("Context", value: "\(Formatting.tokens(context)) tokens") }
                }
                Section {
                    LabeledContent("Project", value: session.project)
                    if let branch = session.branch { LabeledContent("Branch") { Text(branch).font(.body.monospaced()) } }
                    if session.worktree { LabeledContent("Worktree", value: "Yes") }
                    if let hosted = session.hosted { LabeledContent("tmux") { Text(hosted).font(.body.monospaced()) } }
                }
                Section("Conversation ID") {
                    Text(session.conversationID ?? session.id)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Session Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Under the latest reply: Copy, Share and, when the Mac can, Fork. Quiet, so the prose leads.
private struct MessageActions: View {
    let sessionID: SessionKey
    let message: TranscriptMessage
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.xxs) {
            let text = model.transcripts.text(message, in: sessionID) ?? ""
            CopyButton(text: text)
            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Share")
            ForkFromHereButton(sessionID: sessionID, message: message)
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 32)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
    }
}
