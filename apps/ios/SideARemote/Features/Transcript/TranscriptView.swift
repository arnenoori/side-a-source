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
    /// One of a session's subagents: read-only, refreshed while open, with the way back to its parent.
    var subagent: SubagentRef?
    /// A message to scroll to and flash once loaded: a search's match.
    var match: String?
    @State private var flashed: String?
    /// The title while the session was live: an ended session keeps its page readable under its name.
    @State private var lastTitle: String?
    /// The row while it was live: an ended session's reply resumes its conversation in its folder.
    @State private var lastSession: RemoteSession?
    /// Continued or resumed from the composer: the hosted session takes this page's place, so it follows the session
    /// whatever key it comes back under.
    @State private var replaced: HostedSession?

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    @State private var showsInfo = false
    @State private var choosingModel = false
    @State private var reviewingHandoff = false
    @State private var seenCount = 0
    @State private var landed = false
    /// Try Again on a page that wouldn't load: a new value restarts the feed.
    @State private var loadAttempt = 0
    /// The reader has dragged the transcript since opening it.
    @State private var scrolled = false
    /// A reply that starts after this is written out from its first word; one already there just shows.
    @State private var openedAt = Date.now
    @State private var composerFocused = false

    private var session: RemoteSession? { model.sessions.session(sessionID) }
    private var openRequests: [RemoteRequest] { session?.openRequests.compactMap(model.requests.request) ?? [] }
    private var answered: [TranscriptStore.AnsweredRequest] { model.transcripts.answered[sessionID] ?? [] }
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
        Group {
            if let replaced {
                StartingSessionView(started: replaced, giveBackTo: sessionID)
            } else {
                transcript
            }
        }
        // The agent handed off to ended before it started: this page, its words and its draft are back.
        .onChange(of: model.handoffs[sessionID] != nil) { _, back in if back, replaced != nil { replaced = nil } }
    }

    @ViewBuilder private var transcript: some View {
        let items = layout()
        let ended = items.endedTurns
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // A hand-back carries on the earlier conversation, so its line sits at the handoff turn instead.
                if let session, let link = model.handoffs.link(for: session), link.resumed != true, (model.transcripts.earlier[sessionID] ?? 0) == 0,
                   model.transcripts.messages[sessionID] != nil {
                    HandoffHeader(session: session, link: link)
                        .padding(.bottom, Space.s)
                }
                ForEach(TranscriptLayout.rows(items)) { lazyRow in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lazyRow.items) { item in
                            row(item, ended: ended)
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
                    }
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
            .readableWidth()
            .animation(.easeOut(duration: 0.2), value: items.last?.id)
        }
        .overlay {
            if model.link != nil, subagent == nil, items.isEmpty, model.transcripts.messages[sessionID] == nil {
                if model.transcripts.loadFailures.contains(sessionID) {
                    ContentUnavailableView {
                        Label("Can't Load Messages", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("Try Again") { loadAttempt += 1 }.buttonStyle(.glass)
                    }
                } else {
                    DelayedProgress()
                }
            }
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        // The bar under the title has its own material; the edge fade would dim the row below it as well.
        .scrollEdgeEffectHidden(usage != nil || working != nil, for: .top)
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
            // One line, not one per fact: a turn starting or ending swaps its words and leaves the transcript where it is.
            // The stack stays when the line goes, so its fade has an animation to run in.
            VStack(spacing: 0) {
                if working != nil || usage != nil {
                    Group {
                        if let working {
                            WorkingLine(since: working.since, step: working.step, asOf: model.mac.shown == .live ? nil : model.mac.lastSeen)
                        } else if let usage {
                            Text(usage)
                                .contentTransition(.numericText())
                                .animation(Motion.smooth(reduceMotion), value: usage)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Space.m)
                    .padding(.bottom, Space.xs)
                    // One bar from the top of the window down past this line, so code and tables scrolled under
                    // the title don't read through it or run into it.
                    .background(Rectangle().fill(.bar).ignoresSafeArea(edges: .top))
                    .transition(.opacity)
                }
            }
            .animation(Motion.smooth(reduceMotion), value: working == nil)
            .animation(Motion.smooth(reduceMotion), value: working == nil && usage == nil)
        }
        .safeAreaBar(edge: .bottom) { bottomBar(count: items.count).readableWidth() }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            if subagent != nil {
                EmptyView()
            } else if let past {
                Button("Copy Conversation ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = past.id }
            } else {
                RenameButton(session: session)
                PinButton(session: session)
                Button("Session Info", systemImage: "info.circle") { showsInfo = true }
            }
        }
        .toolbar { if past == nil, subagent == nil { toolbarContent } }
        .hidesTabBar()
        .fileLinks(sessionID)
        .sheet(isPresented: $showsInfo) {
            if let session { SessionInfoSheet(session: session) }
        }
        .sensoryFeedback(.error, trigger: model.transcripts.notices[sessionID]) { _, new in new != nil }
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
        .task(id: "\(sessionID)#\(loadAttempt)") {
            // Live: the newest page, then the Mac's appends, while this transcript is on screen.
            if let subagent { return await model.tools.follow(subagent, into: model.transcripts) }
            await model.link?.follow(sessionID)
        }
        .task(id: session?.abilities) {
            // The menu's model list: the session's own from the Mac, the options' meanwhile.
            guard let session else { return }
            await model.tools.loadOptions()
            await model.tools.loadModels(for: session)
        }
        .task(id: match) { await reveal() }
        .onChange(of: session?.title, initial: true) { _, title in if let title { lastTitle = title } }
        .onChange(of: session, initial: true) { _, session in if let session { lastSession = session } }
        .sheet(isPresented: $choosingModel) {
            if let session {
                LiveModelSheet(session: session, models: model.tools.models(for: session), settings: model.tools.settings(of: session),
                               draft: model.handoffs[session.id])
            }
        }
        .sheet(isPresented: $reviewingHandoff) {
            if let session, let draft = model.handoffs[session.id] {
                RestartSheet(session: session, review: draft, message: model.transcripts.drafts[sessionID] ?? "") { _ in }
            }
        }
        .sessionActions()
    }

    private var title: String {
        if let subagent { return subagent.title }
        if let session { return model.tools.title(for: session) }
        return past?.title ?? lastTitle ?? "Session"
    }

    @ViewBuilder private func bottomBar(count: Int) -> some View {
        if let subagent {
            SubagentBar(ref: subagent)
        } else if let past {
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
                composer(count: count)
                if let session, let draft = model.handoffs[session.id] {
                    HandoffPendingLine(session: session, draft: draft) { reviewingHandoff = true }
                        .transition(.opacity)
                }
            }
            .animation(Motion.smooth(reduceMotion), value: model.handoffs[sessionID])
            .animation(Motion.smooth(reduceMotion), value: session.flatMap(model.tools.attention(for:)))
            .animation(Motion.smooth(reduceMotion), value: session?.plan == nil)
        }
    }

    private func composer(count: Int) -> some View {
        SessionComposer(sessionID: sessionID, focused: $composerFocused, showsFollow: !atBottom, follow: followBadge(count: count),
                        onFollow: { scrollToBottom(count: count) }, lastTitle: lastTitle, lastSession: lastSession, replaced: $replaced,
                        onNote: { presenter.note = NoteTarget(session: sessionID) }, choosingModel: $choosingModel) {
            // After the new turn is laid out, or the scroll stops short of it.
            Task { @MainActor in
                await Task.yield()
                scrollToBottom(count: layout().count)
            }
        }
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

    private var latestReply: TranscriptMessage? {
        model.transcripts.messages[sessionID]?.last(where: { $0.role == .assistant })
    }

    @ViewBuilder private func row(_ item: TranscriptItem, ended: Set<Int>) -> some View {
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
            if let session, let link = model.handoffs.link(for: session), HandoffMessage.isHandoff(message.text) {
                VStack(alignment: .leading, spacing: Space.m) {
                    if link.resumed == true,
                       model.transcripts.messages[sessionID]?.last(where: { $0.role == .user && HandoffMessage.isHandoff($0.text) })?.seq == message.seq {
                        HandoffHeader(session: session, link: link)
                    }
                    if let personal = HandoffMessage.personal(message.text) { HandoffFirstTurn(message: personal) }
                }
            } else {
                UserBubble(sessionID: sessionID, message: message)
            }
        case .assistant(let message):
            // Long-press selects text; the whole message's actions sit under the latest reply, once it's written.
            if message.seq == streamingSeq {
                StreamingMarkdown(message.text ?? "", sourceID: "m\(message.seq)",
                                  startEmpty: (message.at ?? 0) > openedAt.timeIntervalSince1970)
            } else {
                VStack(alignment: .leading, spacing: Space.xs) {
                    MarkdownView(model.transcripts.text(message, in: sessionID) ?? "", sourceID: "m\(message.seq)")
                    CutMessageFooter(sessionID: sessionID, message: message)
                    // Once its turn has ended, the turn-end row under it carries these.
                    if latestReply?.seq == message.seq, !ended.contains(message.seq) {
                        MessageActions(sessionID: sessionID, message: message)
                    }
                }
            }
        case .tool(let tool):
            ToolRow(sessionID: sessionID, tool: tool)
        case .subagent(let tool):
            SubagentCard(sessionID: sessionID, tool: tool)
        case .thinking(let tool):
            ThinkingRow(tool: tool)
        case .group(let group):
            StepGroupRow(sessionID: sessionID, group: group)
        case .diff(let tool, let diff):
            DiffCard(tool: tool, diff: diff, sessionID: sessionID)
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
            TurnEndRow(end: end, text: model.transcripts.text(end, in: sessionID)) {
                if let reply = latestReply, reply.seq == end.seq {
                    ForkFromHereButton(sessionID: sessionID, message: reply)
                }
            }
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

    private func steer(_ steer: Steer) {
        model.steer(steer, sessionID) { presenter.note = NoteTarget(session: sessionID) }
    }

    private func followBadge(count: Int) -> FollowBadge {
        if !openRequests.isEmpty { return .waiting }
        let fresh = count - seenCount
        return fresh > 0 ? .newMessages(fresh) : .none
    }

    private var subtitle: String {
        if let subagent { return "Subagent · " + (model.sessions.session(subagent.parent).map { model.tools.title(for: $0) } ?? "Session") }
        if let past { return [past.project, past.branch].compactMap { $0 }.joined(separator: " · ") }
        guard let session else { return "" }
        if let parent = session.hosted.flatMap({ model.tools.forkedFrom[$0] }) { return "Forked from \(parent)" }
        // The model by its name and the mode once it's not Default, as the Mac's chip has them; the account is in Session Info.
        let settings = model.tools.settings(of: session)
        let name = settings.model.map { id in model.tools.models(for: session).first { $0.id == id }?.title ?? id }
        let mode = settings.mode.flatMap { $0 == .default ? nil : $0.title }
        return [session.project, name, mode].compactMap { $0 }.joined(separator: " · ")
    }

    /// Since when a working session has been at it and its current step, for the line under the title. The list has
    /// both on its row; here they say a turn is under way while a reply waits to be read.
    private var working: (since: Date?, step: String?)? {
        guard past == nil, let session, SessionPhase(session) == .working else { return nil }
        return (session.statusAt.map { Date(timeIntervalSince1970: $0) }, session.step)
    }

    /// "42% context · 2 running", under the title; nil when the Mac reads neither.
    private var usage: String? {
        guard past == nil, let session else { return nil }
        let parts = [session.contextPercent.map { "\(Int($0.rounded()))% context" },
                     session.backgroundTasks.flatMap { $0 > 0 ? "\($0) running" : nil }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        if model.tools.can(.screen) {
            ToolbarItem(placement: .topBarTrailing) { ScreenButton(hosted: session?.hosted) }
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
                SettingsMenu(session: session) { choosingModel = true }
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
                    ShowOnMacButton(name: session?.hosted)
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
                if let failure = session.failure { FailureSection(session: session, failure: failure) }
                if let flag = session.flag {
                    Section { Label(flag.text, systemImage: "exclamationmark.triangle") }
                }
                if let pull = session.pullRequest {
                    Section("Pull Request") {
                        PullRequestChip(pull: pull)
                        if let title = pull.title { Text(title).font(.subheadline).foregroundStyle(.secondary) }
                    }
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
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() }.keyboardShortcut(.cancelAction) }
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
                Image(systemName: "square.and.arrow.up").frame(width: 32, height: 32).hitArea(horizontal: 2, vertical: 6)
            }
            .accessibilityLabel("Share")
            ForkFromHereButton(sessionID: sessionID, message: message)
                .labelStyle(IconTarget(size: CGSize(width: 32, height: 32), horizontal: 2, vertical: 6))
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
    }
}

/// A spinner for a page with nothing to show yet, only once the wait is long enough to notice: a quick load shows no flash.
struct DelayedProgress: View {
    @State private var shown = false

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .opacity(shown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(400))
                shown = true
            }
    }
}

/// "Working · 1m 12s · Running tests", counted by the second. Away from the Mac nothing says it still is, so the clock
/// stops at the last word from it: "Working · 3h 12m · as of 2:14 PM".
private struct WorkingLine: View {
    let since: Date?
    let step: String?
    let asOf: Date?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if let asOf {
            line(at: asOf, asOf: " · as of " + asOf.formatted(date: .omitted, time: .shortened))
        } else {
            TimelineView(.periodic(from: since ?? .now, by: 1)) { context in line(at: context.date) }
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func line(at date: Date, asOf: String = "") -> some View {
        let time = since.flatMap { Formatting.duration(max(date.timeIntervalSince($0), 0).rounded(.down)) }
        return Text((["Working"] + [time, step].compactMap { $0 }).joined(separator: " · ") + asOf)
            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            .truncationMode(.tail)
            .multilineTextAlignment(.center)
    }
}
