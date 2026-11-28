import SideAProtocol
import SideARemoteKit
import SwiftUI

struct SessionComposer: View {
    let sessionID: SessionKey
    @Binding var focused: Bool
    var showsFollow = false
    var follow: FollowBadge = .none
    var onFollow: () -> Void = {}
    var lastTitle: String?
    var lastSession: RemoteSession?
    @Binding var replaced: HostedSession?
    var onNote: (() -> Void)?
    var choosingModel: Binding<Bool>?
    var onSent: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bringingBack = false
    @State private var confirmingHandoff = false
    @State private var handoffKey = SendKey<HandoffAttempt>()
    @AppStorage(PrefKey.openOnMac) private var openOnMac = true

    private var session: RemoteSession? { model.sessions.session(sessionID) }
    private var openRequests: [RemoteRequest] { session?.openRequests.compactMap(model.requests.request) ?? [] }
    private var approval: RemoteRequest? { openRequests.first { !$0.isQuestion && $0.answers.contains(.deny) } }
    /// Typed text can stand in for one question's answer, never for several at once.
    private var question: (request: RemoteRequest, asked: IslandQuestion)? {
        guard let request = openRequests.first(where: \.isQuestion), case .question(let questions) = request.action, questions.count == 1 else { return nil }
        return (request, questions[0])
    }
    private var answering: Bool { question != nil || approval != nil }
    private var draft: String { model.transcripts.drafts[sessionID] ?? "" }
    private var handingOff: Bool { model.handoffs.sending(sessionID) }
    private var draftBinding: Binding<String> {
        Binding { model.transcripts.drafts[sessionID] ?? "" } set: { model.transcripts.drafts[sessionID] = $0 }
    }

    var body: some View {
        let offered = model.deliveries(sessionID)
        let handsOff = model.handoffs[sessionID] != nil && session != nil || answering
        Composer(text: draftBinding, placeholder: placeholder, canInterrupt: canInterrupt, showsFollow: showsFollow, follow: follow,
                 focused: $focused, onSend: { send(as: model.delivery(sessionID)) }, onInterrupt: { model.interrupt(sessionID) },
                 onFollow: onFollow, session: session, steers: Steer.available(for: session).filter { onNote != nil || $0 != .note },
                 onSteer: { model.steer($0, sessionID) { onNote?() } }, disabledReason: disabledReason,
                 unsent: model.transcripts.unsent[sessionID], onRetry: retry,
                 notice: model.transcripts.notices[sessionID] ?? standingNotice,
                 deliveries: handsOff ? [] : offered, delivery: handsOff ? nil : model.delivery(sessionID),
                 onDeliver: { send(as: $0) },
                 dropped: dropped == nil ? nil : session?.flag?.text, onRetryDropped: retryDropped, choosingModel: choosingModel)
            .onChange(of: offered.isEmpty) { _, none in if none { model.deliveryChoices.clear(sessionID) } }
            .onChange(of: session == nil) { _, ended in if ended { model.handoffs.move(sessionID, .sessionGone) } }
            .confirmationDialog("\(session?.agent.title ?? "It") is still working. Stop it and hand off?", isPresented: $confirmingHandoff,
                                titleVisibility: .visible) {
                Button("Stop and Hand Off", role: .destructive) { send(confirmed: true) }
                Button("Cancel", role: .cancel) {}
            }
            .pillClearance()
    }

    private var placeholder: String {
        if let draft = model.handoffs[sessionID], session != nil { return "Message for \(draft.agent.title)…" }
        guard let session else { return resumable ? "Reply to resume it…" : "Reply…" }
        if question != nil { return "Or type your own answer…" }
        if approval != nil { return "Reply to deny and redirect…" }
        // Through the inbox or a Stop hook, Claude reads it as a note, never as the user's own consent.
        if model.arrivesAsNote(sessionID) { return "Reply · arrives as a note" }
        if model.needsContinue(sessionID) { return "Reply · picks it up in Side A" }
        switch SessionPhase(session) {
        case .working: return model.sendsAs(sessionID)?.placeholder ?? "Message…"
        case .needsYou: return "Message…"
        default: return "Reply…"
        }
    }

    private var standingNotice: String? {
        if handingOff, let draft = model.handoffs[sessionID] { return "Handing off to \(draft.agent.title) on \(model.mac.name)…" }
        if bringingBack { return session == nil ? "Resuming it on \(model.mac.name)…" : "Moving it into Side A on \(model.mac.name)…" }
        if model.needsContinue(sessionID) { return "It's idle in a terminal Side A can't type into. Sending moves it into Side A first." }
        return model.outsideSharedServer(sessionID) ? "Started outside Codex's shared server: replies arrive only after it finishes." : nil
    }

    private var resumable: Bool {
        session == nil && model.tools.can(.hosted) && lastSession?.conversationID != nil && lastSession?.cwd != nil
    }

    private var dropped: String? { model.droppedReply(sessionID)?.text }

    private func retryDropped() {
        withAnimation(Motion.smooth(reduceMotion)) { model.retryDropped(sessionID) }
    }

    private var canInterrupt: Bool {
        guard let session else { return false }
        return SessionPhase(session) == .working && session.abilities.contains(.interrupt)
    }

    private var disabledReason: String? {
        if bringingBack { return nil }
        if session == nil, lastTitle != nil, !resumable { return "This session has ended." }
        return session?.status == .unknown ? "\(model.mac.name) can't tell what this session is doing." : nil
    }

    private func send(as delivery: Delivery? = nil, confirmed: Bool = false) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !bringingBack, !handingOff else { return }
        if let handoff = model.handoffs[sessionID], let session { return handOff(session, handoff, text: text, confirmed: confirmed) }
        model.transcripts.drafts[sessionID] = ""
        if let question {
            withAnimation(Motion.smooth(reduceMotion)) {
                model.requests.answer(question.request.id, .answers([QuestionAnswer(question: question.asked.question, picked: [], other: text)]))
            }
            return onSent()
        }
        if let approval {
            withAnimation(Motion.smooth(reduceMotion)) { model.requests.answer(approval.id, .deny(message: text)) }
            return onSent()
        }
        if model.needsContinue(sessionID) { return continueThenSend(text) }
        if session == nil, resumable, let last = lastSession { return resume(last, with: text) }
        withAnimation(Motion.smooth(reduceMotion)) {
            if let delivery { model.send(text, to: sessionID, as: delivery) } else { model.reply(text, to: sessionID) }
            if delivery != .interrupt { _ = model.tools.attachments.take(sessionID, for: model.transcripts.outgoing[sessionID]?.last?.id) }
        }
        onSent()
    }

    /// Retry goes the way Send would now: a session that has since ended or gone idle out of reach is resumed or moved
    /// into Side A, where sending the same reply again could only fail again.
    private func retry() {
        guard let unsent = model.transcripts.unsent[sessionID] else { return }
        let moves = model.needsContinue(sessionID)
        guard !bringingBack, moves || session == nil && resumable, let last = moves ? session : lastSession else { return model.retryUnsent(sessionID) }
        model.transcripts.clearUnsent(sessionID)
        if model.transcripts.drafts[sessionID] == unsent.text { model.transcripts.drafts[sessionID] = "" }
        if moves { continueThenSend(unsent.text) } else { resume(last, with: unsent.text) }
    }

    private func continueThenSend(_ text: String) {
        let turn = model.transcripts.send(text, to: sessionID)
        bringingBack = true
        Task {
            defer { bringingBack = false }
            do {
                let hosted = try await model.tools.continueOnPhone(sessionID)
                model.transcripts.discard(turn.id, in: sessionID)
                model.transcripts.wait(text, for: hosted.name, at: turn.at)
                if openOnMac, model.tools.can(.hostedShow) { try? await model.tools.showOnMac(hosted.name) }
                replaced = hosted
            } catch {
                model.transcripts.fail(turn.id, in: sessionID, reason: MacTools.message(error), item: nil)
            }
        }
    }

    private func handOff(_ session: RemoteSession, _ draft: HandoffDraft, text: String, confirmed: Bool) {
        if !session.openRequests.isEmpty {
            return model.transcripts.notice("Answer or deny \(session.agent.title)'s open request first.", in: sessionID)
        }
        let tray = model.tools.attachments
        var photos: [String] = []
        if !tray.items(sessionID).isEmpty {
            guard model.tools.can(.restartAgentImages) else {
                return model.transcripts.notice("Photos can't go with a handoff. Remove them to hand off, or send them to \(session.agent.title) first.",
                                                in: sessionID)
            }
            switch tray.gate(sessionID) {
            case .uploading: return model.transcripts.notice("A photo is still uploading. Hand off once it's done.", in: sessionID)
            case .failed: return model.transcripts.notice("A photo didn't upload. Retry it or remove it.", in: sessionID)
            case .ready(let ids): photos = ids
            }
        }
        if session.status == .waiting {
            return model.transcripts.notice("\(session.agent.title) is waiting on you in its terminal. Answer it there first.", in: sessionID)
        }
        guard model.mac.shown == .live, model.tools.isLive else {
            return model.transcripts.notice("\(model.mac.name) isn't connected, so nothing was handed off. Send again once it's back.", in: sessionID)
        }
        if SessionPhase(session) == .working, !confirmed { confirmingHandoff = true; return }
        model.transcripts.notice(nil, in: sessionID)
        model.handoffs.move(sessionID, .send(message: text))
        let key = handoffKey.sending(HandoffAttempt(draft: draft, message: text, photos: photos))
        Task {
            do {
                let hosted = try await model.tools.handOff(session, draft: draft, message: text, photos: photos, key: key)
                handoffKey.answered()
                // Gone with the send; a failure above never reaches this, so the tray keeps them.
                _ = tray.take(sessionID)
                if let link = hosted.handoffFrom { model.handoffs.started(hosted.name, from: link) }
                if model.transcripts.drafts[sessionID]?.trimmingCharacters(in: .whitespacesAndNewlines) == text { model.transcripts.drafts[sessionID] = "" }
                model.handoffs.move(sessionID, .started(name: hosted.name))
                onSent()
                replaced = hosted
            } catch let failure as RemoteFailure {
                handoffKey.answered()
                model.handoffs.move(sessionID, .notStarted)
                if failure.error.details?["reason"] == "unknown_upload" {
                    tray.reupload(sessionID)
                    return model.transcripts.notice("A photo went up again. Hand off once it's done.", in: sessionID)
                }
                model.transcripts.notice(failure.error.code == .outcomeUnknown
                    ? "This may or may not have reached \(model.mac.name). Check Sessions before sending again." : MacTools.message(failure),
                    in: sessionID)
            } catch {
                model.handoffs.move(sessionID, .notStarted)
                model.transcripts.notice(MacTools.message(error), in: sessionID)
            }
        }
    }

    private func resume(_ last: RemoteSession, with text: String) {
        guard let conversation = last.conversationID, let cwd = last.cwd else { return }
        let turn = model.transcripts.send(text, to: sessionID)
        bringingBack = true
        let start = StartHosted(cwd: cwd, agent: last.agent, prompt: text, resume: conversation,
                                openOnMac: openOnMac && model.tools.can(.hostedShow) ? true : nil)
        Task {
            defer { bringingBack = false }
            do {
                let hosted = try await model.tools.start(start, key: UUID().uuidString.lowercased())
                model.transcripts.discard(turn.id, in: sessionID)
                model.transcripts.started(hosted.name, prompt: text, at: turn.at)
                replaced = hosted
            } catch {
                model.transcripts.fail(turn.id, in: sessionID, reason: MacTools.message(error), item: nil)
            }
        }
    }
}

struct ComposerSheet: View {
    let sessionID: SessionKey
    var delivery: Delivery?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focused = false
    @State private var started: HostedSession?
    @State private var following: HostedSession?
    @State private var reviewingHandoff = false
    @State private var attachHeld = false
    @State private var detent = PresentationDetent.medium
    @State private var choosingModel = false

    private var session: RemoteSession? { model.sessions.session(sessionID) }

    var body: some View {
        NavigationStack {
            Group {
                if let following {
                    StartingSessionView(started: following, giveBackTo: sessionID)
                } else {
                    reply
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .onChange(of: started) { _, started in
                guard let started else { return }
                if model.handoffs.handedOff(sessionID) == started.name {
                    following = started
                    detent = .large
                } else {
                    dismiss()
                }
            }
            .onChange(of: model.handoffs[sessionID] != nil) { _, back in if back, following != nil { following = nil } }
            .sheet(isPresented: $reviewingHandoff) {
                if let session, let draft = model.handoffs[session.id] {
                    RestartSheet(session: session, review: draft, message: model.transcripts.drafts[sessionID] ?? "") { _ in }
                }
            }
            .liveModelSheet(isPresented: $choosingModel, session: session)
            .sessionActions()
            .task {
                if let delivery, model.deliveries(sessionID).contains(delivery) { model.chooseDelivery(delivery, for: sessionID) }
                focused = true
            }
        }
        .environment(\.attachHeld, $attachHeld)
        .interactiveDismissDisabled(attachHeld)
        .presentationDetents(attachHeld ? [detent] : [.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    private var reply: some View {
        ScrollView {
            if let reply = model.sessions.extras[sessionID]?.lastReply {
                Text(reply)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
            }
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: Space.xs) {
                SessionComposer(sessionID: sessionID, focused: $focused, replaced: $started, choosingModel: $choosingModel,
                                onSent: { if model.handoffs.handedOff(sessionID) == nil { dismiss() } })
                if let session, let draft = model.handoffs[session.id] {
                    HandoffPendingLine(session: session, draft: draft) { reviewingHandoff = true }
                        .transition(.opacity)
                }
            }
            .animation(Motion.smooth(reduceMotion), value: model.handoffs[sessionID])
        }
        .navigationTitle(session.map { model.tools.title(for: $0) } ?? "Reply")
        .navigationBarTitleDisplayMode(.inline)
    }
}
