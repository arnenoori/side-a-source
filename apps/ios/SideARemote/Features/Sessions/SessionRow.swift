import SideAProtocol
import SideARemoteShared
import SwiftUI

/// A Sessions row: title and age; the agent, project, account and model with any
/// ports trailing; and one fact on line 3. Mono only for what's typed or counted.
struct SessionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(ApprovalPresenter.self) private var approvals
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: RemoteSession

    private var phase: SessionPhase { SessionPhase(session) }
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
                        // At the largest type one line holds two or three words.
                        .lineLimit(typeSize >= .xxLarge ? 2 : 1)
                    Spacer(minLength: Space.xs)
                    if let statusAt = session.statusAt {
                        Text(Formatting.elapsed(since: Date(timeIntervalSince1970: statusAt)))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                metadataLine
                // What it asks, or what didn't arrive, is the line that matters: it takes a second line before it's cut.
                fact.lineLimit(request != nil || session.flag?.kind == .unsent ? 2 : 1)
            }
        }
        // A new step, a request answered, a phase change: the line and glyph crossfade rather than snap.
        .animation(Motion.smooth(reduceMotion), value: factKey)
        .animation(Motion.smooth(reduceMotion), value: phase)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .swipeActions(edge: .leading, allowsFullSwipe: false) { leadingActions }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { trailingActions }
        .contextMenu {
            contextActions
        } preview: {
            SessionPreview(session: session, text: extras?.lastReply)
        }
    }

    private var metadata: String {
        [session.project, session.accountName, session.model].compactMap { $0 }.joined(separator: " · ")
    }

    /// Line 2: which agent, where it runs, and what it holds open. Ports and memory are the secondary facts,
    /// so where both don't fit they go, rather than cutting the project, account and model.
    private var metadataLine: some View {
        ViewThatFits(in: .horizontal) {
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

    /// Line 3: the request in amber, a health flag, waiting mail, or the current step.

    @ViewBuilder private var fact: some View {
        if let request {
            // A question is prose; a command is typed.
            Text(request.accessoryTitle)
                .font(request.isQuestion ? .subheadline.weight(.medium) : .footnote.monospaced().weight(.medium))
                .foregroundStyle(Color.amberText)
        } else if let attention = model.tools.attention(for: session) {
            InlineFact(symbol: attention.symbol, text: attention.title)
                .foregroundStyle(.secondary)
        } else if let flag = session.flag, flag.kind == .unsent {
            // Quiet: nothing is wrong with the session, one message just didn't arrive. Retry is in the transcript.
            InlineFact(symbol: "arrow.uturn.backward", text: flag.text)
                .foregroundStyle(.secondary)
        } else if let flag = session.flag {
            InlineFact(symbol: flag.kind == .failing ? "exclamationmark.triangle.fill" : "exclamationmark.triangle", text: flag.text)
                .foregroundStyle(flag.kind == .failing ? AnyShapeStyle(Color.destructive) : AnyShapeStyle(.secondary))
        } else if let mail = session.mail {
            InlineFact(symbol: mail.kind == .note ? "clock" : "pause.circle",
                       text: mail.kind == .note ? "Message waiting" : "Stops after this step")
                .foregroundStyle(.secondary)
        } else if let step = session.step {
            Text(step)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    /// What line 3 shows, to animate on.
    private var factKey: String {
        request.map { "r:\($0.id)" } ?? model.tools.attention(for: session).map { "a:\($0.kind.rawValue)" } ?? session.flag.map { "f:\($0.text)" } ?? session.mail.map { "m:\($0.kind)" } ?? "s:\(session.step ?? "")"
    }

    private var portsText: String? {
        let parts = (session.ports ?? []).map { ":\($0.port)" } + [session.memoryBytes.flatMap(Formatting.memory)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts = [session.title, phase.title]
        if let request { parts.append(request.accessoryTitle) } else if let flag = session.flag { parts.append(flag.text) } else if let step = session.step { parts.append(step) }
        parts += [session.project, session.accountName, session.agent.title, session.hosted.map { _ in "in a terminal" }].compactMap { $0 }
        if let statusAt = session.statusAt { parts.append(Formatting.elapsed(since: Date(timeIntervalSince1970: statusAt))) }
        return parts.joined(separator: ", ")
    }

    // MARK: Actions

    private var steers: [Steer] { Steer.available(for: session) }

    @ViewBuilder private var leadingActions: some View {
        switch phase {
        case .needsYou:
            // Only what the row shows whole: a longer command or an edit is allowed from its sheet.
            if let request, !request.isQuestion, request.allowGate != .biometric, request.fitsRow {
                Button("Allow", systemImage: "checkmark") { model.requests.answer(request.id, .allow(confirmDestructive: false)) }
                    .needsMac()
                    .tint(.amber)
            }
        case .working:
            if session.abilities.contains(.note) {
                Button("Message", systemImage: Steer.note.symbol) { approvals.note = NoteTarget(session: session.id) }.tint(.indigo)
            }
        case .ready: ReplyButton(session: session).tint(.blue)
        case .idle:
            ContinueButton(session: session).tint(.blue)
        }
    }

    @ViewBuilder private var trailingActions: some View {
        switch phase {
        case .needsYou:
            TerminalButton(session: session).tint(.gray)
        case .working:
            if session.mail != nil {
                Button("Take Back", systemImage: "arrow.uturn.backward") { model.takeBack(session.id) }.tint(.gray).needsMac()
            } else if steers.contains(.stopBeforeNextStep) {
                Button("Stop", systemImage: "pause.circle") { model.interrupt(session.id, when: .nextStep) }.tint(.orange).needsMac()
            }
        case .ready, .idle:
            QuitButton(session: session, title: "Quit")
        }
    }

    @ViewBuilder private var contextActions: some View {
        switch phase {
        case .needsYou:
            if let request {
                Button("Answer…", systemImage: "hand.raised") { approvals.request = request }
            }
            TerminalButton(session: session, title: "Open Terminal")
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
                RestartButton(session: session)
                QuitButton(session: session)
            }
        case .ready:
            ReplyButton(session: session)
            ForkButton(session: session)
            Section {
                RestartButton(session: session)
                QuitButton(session: session)
            }
        case .idle:
            ContinueButton(session: session)
            ForkButton(session: session)
            RestartButton(session: session)
            RenameButton(session: session)
            QuitButton(session: session)
        }
        Section {
            PinButton(session: session)
            if phase != .needsYou { TerminalButton(session: session, title: "Open Terminal") }
            Button("Copy Session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = session.conversationID ?? session.id }
        }
    }
}

/// A glyph and a fact on line 3, sized to the text (a `Label` in a List row takes the icon column).
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

/// The context menu's preview: the last thing the assistant said.
private struct SessionPreview: View {
    let session: RemoteSession
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(session.title).font(.headline)
            Text([session.project, session.accountName, session.model].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote.monospaced()).foregroundStyle(.secondary)
            Text(text ?? session.step ?? "No replies yet")
                .font(.body)
                .padding(.top, Space.xxs)
        }
        .padding(Space.m)
        .frame(width: 320, alignment: .leading)
    }
}
