import SideAProtocol
import SideASessionKit
import SideARemoteKit
import SideARemoteShared
import SwiftUI

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(ApprovalPresenter.self) private var approvals
    @Environment(SessionActions.self) private var actions
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: RemoteSession

    private var phase: SessionPhase { SessionPhase(session) }
    private var snooze: SessionSnooze? { model.tools.snooze(of: session) }
    private var snoozable: Bool { model.tools.can(.snooze) && phase != .needsYou && session.snoozable }
    private var extras: SessionExtras? { model.sessions.extras[session.id] }
    private var request: RemoteRequest? { session.openRequests.first.flatMap(model.requests.request) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            StatusGlyph(phase: phase)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.tools.title(for: session))
                        .font(.body.weight(.semibold))
                        .lineLimit(typeSize >= .xxLarge ? 2 : 1)
                    Spacer(minLength: Space.xs)
                    trailing
                }
                metadataLine
                fact.lineLimit(request != nil || session.flag?.kind == .unsent ? 2 : 1)
                if let request, !request.isQuestion { answers(request) }
            }
        }
        .animation(Motion.smooth(reduceMotion), value: factKey)
        .animation(Motion.smooth(reduceMotion), value: phase)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityActions {
            if let request, !request.isQuestion, model.mac.shown == .live { answerButtons(request) }
            if let waiting = model.tools.moves.waiting(for: session) { CancelMoveButton(record: waiting) }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: phase != .needsYou) { leadingActions }
        .swipeActions(edge: .trailing, allowsFullSwipe: phase == .ready || phase == .idle) { trailingActions }
        .contextMenu {
            contextActions
        } preview: {
            SessionPreview(session: session, text: extras?.lastReply)
        }
    }

    @ViewBuilder private var trailing: some View {
        if let request {
            Text(request.isQuestion ? "Question" : "Approval")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.amberText)
        } else if phase == .working, snooze == nil, let statusAt = session.statusAt, model.mac.shown == .live {
            WorkingClock(since: Date(timeIntervalSince1970: statusAt))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.tint)
        } else if let statusAt = session.statusAt {
            ElapsedText(since: Date(timeIntervalSince1970: statusAt), live: phase == .working || phase == .needsYou)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }

    private func answers(_ request: RemoteRequest) -> some View {
        HStack(spacing: Space.xs) { answerButtons(request) }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .needsMac()
            .padding(.top, Space.xxs)
    }

    @ViewBuilder private func answerButtons(_ request: RemoteRequest) -> some View {
        if request.allowsFromRow {
            Button("Allow") { model.requests.answer(request.id, .allow(confirmDestructive: false)) }.tint(.amber).foregroundStyle(Color.amberText)
        } else {
            Button(request.plan == nil ? "Review" : "Review Plan") { approvals.request = request }.tint(.amber).foregroundStyle(Color.amberText)
        }
        if request.plan == nil, request.answers.contains(.deny) {
            Button("Deny") { model.requests.answer(request.id, .deny(message: nil)) }.tint(Color.secondary)
        }
    }

    private var metadata: String {
        let project = Optional(session.project).flatMap { $0 == model.tools.title(for: session) ? nil : $0 }
        return [project, session.accountName, session.model.map(ModelName.brief),
                model.handoffs.link(for: session).map { "Handed off from \($0.agent.title)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var metadataLine: some View {
        ViewThatFits(in: .horizontal) {
            if let pull = session.pullRequest {
                HStack(spacing: Space.xxs) {
                    agentIcons
                    Text(metadata).lineLimit(1).fixedSize()
                    Spacer(minLength: Space.xs)
                    PullRequestBadge(pull: pull)
                    if let ports = portsText { Text(ports).font(.footnote.monospaced()).lineLimit(1).fixedSize() }
                }
                HStack(spacing: Space.xxs) {
                    agentIcons
                    Text(metadata).lineLimit(1)
                    Spacer(minLength: Space.xs)
                    PullRequestBadge(pull: pull)
                }
                HStack(spacing: Space.xxs) {
                    agentIcons
                    Text(metadata).lineLimit(1)
                    Spacer(minLength: Space.xs)
                    PullRequestBadge(pull: pull, compact: true)
                }
            }
            if let ports = portsText {
                HStack(spacing: Space.xxs) {
                    agentIcons
                    Text(metadata).lineLimit(1).fixedSize()
                    Spacer(minLength: Space.xs)
                    Text(ports).font(.footnote.monospaced()).lineLimit(1).fixedSize()
                }
            }
            HStack(spacing: Space.xxs) {
                agentIcons
                Text(metadata).lineLimit(1)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var agentIcons: some View {
        Image(systemName: session.agent.symbol).imageScale(.small)
        if session.hosted != nil { Image(systemName: "terminal").imageScale(.small) }
    }

    @ViewBuilder private var fact: some View {
        if let request {
            Text(request.rowLine)
                .font(request.isQuestion ? .subheadline.weight(.medium) : .footnote.monospaced().weight(.medium))
                .foregroundStyle(Color.amberText)
        } else if let attention = model.tools.attention(for: session) {
            InlineFact(symbol: attention.symbol, text: attention.title)
                .foregroundStyle(.secondary)
        } else if let waiting = model.tools.moves.waiting(for: session) {
            MoveWaitingFact(record: waiting)
        } else if let failure = session.failure {
            InlineFact(symbol: failure.symbol, text: failure.message)
                .foregroundStyle(failure.retryable ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.destructive))
        } else if let flag = session.flag, flag.kind == .unsent {
            InlineFact(symbol: "arrow.uturn.backward", text: flag.text)
                .foregroundStyle(.secondary)
        } else if let flag = session.flag {
            InlineFact(symbol: flag.kind == .failing ? "exclamationmark.triangle.fill" : "exclamationmark.triangle", text: flag.text)
                .foregroundStyle(flag.kind == .failing ? AnyShapeStyle(Color.destructive) : AnyShapeStyle(.secondary))
        } else if let mail = session.mail {
            InlineFact(symbol: mail.kind.symbol, text: mail.kind.line)
                .foregroundStyle(.secondary)
        } else if let snooze {
            InlineFact(symbol: "moon.zzz", text: "Snoozed · \(snooze.untilText)")
                .foregroundStyle(.secondary)
        } else if let step = session.step {
            Text(step)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var factKey: String {
        request.map { "r:\($0.id)" } ?? model.tools.attention(for: session).map { "a:\($0.kind.rawValue)" } ?? model.tools.moves.waiting(for: session).map { "w:\($0.id)" }
            ?? session.failure.map { "x:\($0.kind.rawValue)" }
            ?? session.flag.map { "f:\($0.text)" } ?? session.mail.map { "m:\($0.kind)" } ?? snooze.map { "z:\($0.at)" } ?? "s:\(session.step ?? "")"
    }

    private var portsText: String? {
        let parts = (session.ports ?? []).map { ":\($0.port)" } + [session.memoryBytes.flatMap(MemorySize.gigabytesText)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts = [model.tools.title(for: session), phase.title]
        if let request { parts.append(request.accessoryTitle) } else if let failure = session.failure { parts.append(failure.message) }
        else if let flag = session.flag { parts.append(flag.text) } else if let step = session.step { parts.append(step) }
        if let snooze { parts.append("Snoozed, \(snooze.untilText)") }
        if let waiting = model.tools.moves.waiting(for: session) { parts.append(MoveText.status(waiting)) }
        if let pull = session.pullRequest { parts.append("Pull request \(pull.summary)") }
        parts += [session.project == parts[0] ? nil : session.project, session.accountName, session.agent.title, session.hosted.map { _ in "in a terminal" }].compactMap { $0 }
        if let statusAt = session.statusAt { parts.append(Formatting.elapsed(since: Date(timeIntervalSince1970: statusAt))) }
        return parts.joined(separator: ", ")
    }

    private var steers: [Steer] { Steer.available(for: session) }

    @ViewBuilder private var leadingActions: some View {
        if phase == .needsYou {
            if let request, request.allowsFromRow {
                Button("Allow", systemImage: "checkmark") { model.requests.answer(request.id, .allow(confirmDestructive: false)) }
                    .needsMac()
                    .tint(.amber)
            }
        } else if snoozable {
            if snooze != nil {
                Button("Wake", systemImage: "sun.max") { actions.on(model).snooze(session, nil) }.tint(.indigo).needsMac()
            } else if let choice = SessionSnooze.Choice.offered.first {
                Button("Snooze", systemImage: "moon.zzz") { actions.on(model).snooze(session, choice) }.tint(.indigo).needsMac()
            }
        }
    }

    @ViewBuilder private var trailingActions: some View {
        QuitButton(session: session, title: "Quit", undoable: true, swipe: true)
        if phase == .working {
            if session.mail != nil {
                Button("Take Back", systemImage: "arrow.uturn.backward") { model.takeBack(session.id) }.tint(.gray).needsMac()
            } else if steers.contains(.stopBeforeNextStep) {
                Button("Stop", systemImage: "pause.circle") { model.interrupt(session.id, when: .nextStep) }.tint(.orange).needsMac()
            }
        }
    }

    @ViewBuilder private var contextActions: some View {
        switch phase {
        case .needsYou:
            if let request {
                Button("Answer…", systemImage: "hand.raised") { approvals.request = request }
            }
            TerminalButton(session: session, title: "Open Terminal")
            MoveButton(session: session)
        case .working:
            Section {
                if steers.contains(.note) {
                    Button(Steer.note.title, systemImage: Steer.note.symbol) { approvals.note = NoteTarget(session: session.id) }
                }
                if steers.contains(.stopBeforeNextStep) {
                    Button("Stop Before Next Step", systemImage: "pause.circle") { model.interrupt(session.id, when: .nextStep) }
                }
                if steers.contains(.interruptNow) {
                    Button("Interrupt Now", systemImage: "stop.fill") { model.interrupt(session.id) }
                }
                if session.mail != nil { Button("Take Back", systemImage: "arrow.uturn.backward") { model.takeBack(session.id) } }
            }
            if session.ports?.isEmpty == false {
                Section { PortButtons(session: session) }
            }
            Section {
                ForkButton(session: session)
                MoveButton(session: session)
                RestartButton(session: session)
                QuitButton(session: session)
            }
        case .ready:
            ReplyButton(session: session)
            ForkButton(session: session)
            Section {
                MoveButton(session: session)
                RestartButton(session: session)
                QuitButton(session: session)
            }
        case .idle:
            ContinueButton(session: session)
            MoveButton(session: session)
            ForkButton(session: session)
            RestartButton(session: session)
            RenameButton(session: session)
            QuitButton(session: session)
        }
        if let failure = session.failure {
            Section(failure.message) { FailureFixButton(session: session, failure: failure) }
        }
        if let pull = session.pullRequest {
            Section { PullRequestMenu(pull: pull) }
        }
        Section {
            PinButton(session: session)
            SnoozeMenu(session: session)
            if phase == .idle, session.conversationID != nil, model.tools.can(.history) {
                Button("Archive", systemImage: "archivebox") { actions.on(model).archive(session) }
            }
            if phase != .needsYou { TerminalButton(session: session, title: "Open Terminal") }
            Button("Copy Session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = session.conversationID ?? session.id }
        }
    }
}

private extension RemoteRequest {
    /// The row already says "Approval", so a command gets both lines to itself.
    var rowLine: String {
        if case .command(let command) = action { RequestText.visible(command) } else { accessoryTitle }
    }
}

/// "12s", "14m 12s", "2h 03m": a working row counts up where a resting one says how long ago.
struct WorkingClock: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Formatting.duration(max(context.date.timeIntervalSince(since), 1).rounded(.down)) ?? "1s")
        }
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct ElapsedText: View {
    let since: Date
    var live = true

    var body: some View {
        TimelineView(.periodic(from: since, by: live ? 15 : 60)) { context in
            Text(Formatting.elapsed(since: since, now: max(context.date, since)))
        }
    }
}

private struct InlineFact: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: symbol).imageScale(.small)
            Text(text)
        }
        .font(.footnote)
    }
}

private struct SessionPreview: View {
    let session: RemoteSession
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(session.title).font(.headline)
            Text([session.project, session.accountName, session.model.map(ModelName.brief)].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary)
            Text(text ?? session.step ?? "No replies yet")
                .font(.body)
                .padding(.top, Space.xxs)
        }
        .padding(Space.m)
        .frame(width: 320, alignment: .leading)
    }
}
