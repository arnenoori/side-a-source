import SideAProtocol
import SideARemoteShared
import SwiftUI

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ApprovalPresenter.self) private var presenter
    let sessionID: SessionKey
    var past: PastSession?
    var subagent: SubagentRef?
    var match: String?
    @State private var flashed: String?
    @State private var lastTitle: String?
    @State private var lastSession: RemoteSession?
    @State private var replaced: HostedSession?

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    @State private var showsInfo = false
    @State private var choosingModel = false
    @State private var reviewingHandoff = false
    @State private var seenCount = 0
    @State private var landed = false
    @State private var loadAttempt = 0
    @State private var scrolled = false
    @State private var openedAt = Date.now
    @State private var composerFocused = false
    @State private var unfolded: Set<String> = []

    private var session: RemoteSession? { model.sessions.session(sessionID) }
    private var openRequests: [RemoteRequest] { session?.openRequests.compactMap(model.requests.request) ?? [] }
    private var answered: [TranscriptStore.AnsweredRequest] { model.transcripts.answered[sessionID] ?? [] }
    private var draftBinding: Binding<String> {
        Binding { model.transcripts.drafts[sessionID] ?? "" } set: { model.transcripts.drafts[sessionID] = $0 }
    }

    private var approval: RemoteRequest? { openRequests.first { !$0.isQuestion } }

    /// Questions stay in the transcript, where their options are; an approval sits over the composer instead.
    private func layout() -> [TranscriptItem] {
        let working = session.map { SessionPhase($0) == .working || SessionPhase($0) == .needsYou } ?? false
        let items = TranscriptLayout.items(messages: model.transcripts.messages[sessionID] ?? [], earlier: model.transcripts.earlier[sessionID] ?? 0,
                                           answered: answered, open: openRequests.filter(\.isQuestion), working: working,
                                           outgoing: model.transcripts.outgoing[sessionID] ?? [], mail: session?.mail)
        return TranscriptLayout.folded(items, working: working, since: session?.statusAt.map { Date(timeIntervalSince1970: $0) })
    }

    var body: some View {
        Group {
            if let replaced {
                StartingSessionView(started: replaced, giveBackTo: sessionID)
            } else {
                transcript
            }
        }
        .onChange(of: model.handoffs[sessionID] != nil) { _, back in if back, replaced != nil { replaced = nil } }
    }

    @ViewBuilder private var transcript: some View {
        let items = layout()
        let ended = items.endedTurns
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
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
        .scrollEdgeEffectHidden(usage != nil, for: .top)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded { SelectableText.clearSelection() })
        .onScrollPhaseChange { _, phase in if phase == .interacting { scrolled = true } }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            return geometry.contentOffset.y + geometry.contentInsets.top + geometry.containerSize.height >= geometry.contentSize.height - 40
        } action: { _, isAtBottom in
            atBottom = isAtBottom
            if isAtBottom { seenCount = items.count }
        }
        .safeAreaBar(edge: .top) {
            VStack(spacing: 0) {
                if let usage {
                    Text(usage)
                        .contentTransition(.numericText())
                        .animation(Motion.smooth(reduceMotion), value: usage)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Space.m)
                    .padding(.bottom, Space.xs)
                    .background(Rectangle().fill(.bar).ignoresSafeArea(edges: .top))
                    .transition(.opacity)
                }
            }
            .animation(Motion.smooth(reduceMotion), value: usage == nil)
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
            if let subagent { return await model.tools.follow(subagent, into: model.transcripts) }
            await model.link?.follow(sessionID)
        }
        .task(id: session?.abilities) {
            guard let session else { return }
            await model.tools.loadOptions()
            await model.tools.loadModels(for: session)
        }
        .task(id: match) { await reveal() }
        .onChange(of: session?.title, initial: true) { _, title in if let title { lastTitle = title } }
        .onChange(of: session, initial: true) { _, session in if let session { lastSession = session } }
        .liveModelSheet(isPresented: $choosingModel, session: session)
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
                if let approval {
                    ApprovalCard(request: approval)
                        .padding(.horizontal, Space.m)
                        .id(approval.id)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
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
            .animation(Motion.smooth(reduceMotion), value: approval?.id)
        }
    }

    private func composer(count: Int) -> some View {
        SessionComposer(sessionID: sessionID, focused: $composerFocused, showsFollow: !atBottom, follow: followBadge(count: count),
                        onFollow: { scrollToBottom(count: count) }, lastTitle: lastTitle, lastSession: lastSession, replaced: $replaced,
                        onNote: { presenter.note = NoteTarget(session: sessionID) }, choosingModel: $choosingModel) {
            Task { @MainActor in
                await Task.yield()
                scrollToBottom(count: layout().count)
            }
        }
    }

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

    private func reveal() async {
        guard let match else { return }
        var earlierAsked = 0
        for _ in 0..<60 {
            if let message = model.transcripts.messages[sessionID]?.first(where: { $0.uuid == match }) {
                let id = "m-\(message.seq)"
                for case .turn(let fold) in layout() where fold.holds(message: message.seq) { unfolded.insert(fold.id) }
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

    private var latestReply: TranscriptMessage? {
        model.transcripts.messages[sessionID]?.last(where: { $0.role == .assistant })
    }

    @ViewBuilder private func row(_ item: TranscriptItem, ended: Set<Int>) -> some View {
        if case .turn(let fold) = item {
            TurnFoldRow(fold: fold, expanded: unfolded.contains(fold.id)) {
                unfolded.formSymmetricDifference([fold.id])
            } step: { step in
                self.step(step, ended: ended)
            }
        } else {
            step(item, ended: ended)
        }
    }

    @ViewBuilder private func step(_ item: TranscriptItem, ended: Set<Int>) -> some View {
        switch item {
        case .turn:
            EmptyView()
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
            if message.seq == streamingSeq {
                StreamingMarkdown(message.text ?? "", sourceID: "m\(message.seq)",
                                  startEmpty: (message.at ?? 0) > openedAt.timeIntervalSince1970)
            } else {
                VStack(alignment: .leading, spacing: Space.xs) {
                    MarkdownView(model.transcripts.text(message, in: sessionID) ?? "", sourceID: "m\(message.seq)")
                    CutMessageFooter(sessionID: sessionID, message: message)
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
            ApprovalCard(request: request).id(request.id)
        case .question(let request):
            QuestionCard(request: request, typed: draftBinding) { composerFocused = true }
        case .outgoing(let turn):
            OutgoingBubble(sessionID: sessionID, turn: turn)
        case .mail(let mail):
            MailLine(sessionID: sessionID, mail: mail)
                .frame(maxWidth: .infinity)
        }
    }

    private var streamingSeq: Int? {
        guard let session, SessionPhase(session) == .working else { return nil }
        return model.transcripts.messages[sessionID]?.last(where: { $0.role == .assistant })?.seq
    }

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
        if openRequests.contains(where: \.isQuestion) { return .waiting }
        let fresh = count - seenCount
        return fresh > 0 ? .newMessages(fresh) : .none
    }

    private var subtitle: String {
        if let subagent { return "Subagent · " + (model.sessions.session(subagent.parent).map { model.tools.title(for: $0) } ?? "Session") }
        if let past { return [past.project, past.branch].compactMap { $0 }.joined(separator: " · ") }
        guard let session else { return "" }
        if let parent = session.hosted.flatMap({ model.tools.forkedFrom[$0] }) { return "Forked from \(parent)" }
        let mode = model.tools.settings(of: session).mode.flatMap { $0 == .default ? nil : $0.title }
        let project = Optional(session.project).flatMap { $0 == model.tools.title(for: session) ? nil : $0 }
        return [project, mode].compactMap { $0 }.joined(separator: " · ")
    }

    private var usage: String? {
        guard past == nil, let session else { return nil }
        return session.backgroundTasks.flatMap { $0 > 0 ? "\($0) running" : nil }
    }

    private func scrollToBottom(count: Int) {
        withAnimation(Motion.smooth(reduceMotion)) { position.scrollTo(edge: .bottom) }
        seenCount = count
    }

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
