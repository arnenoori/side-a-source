import SideAProtocol
import SideARemoteKit
import SwiftUI

/// The composer for one session, wherever it sits: the transcript's bottom bar, or the sheet a row's Reply and Message
/// open. The field's text is the session's own draft, so what is typed in one place is in the other; photos, commands,
/// deliveries and the steers are the same too.
struct SessionComposer: View {
    let sessionID: SessionKey
    @Binding var focused: Bool
    var showsFollow = false
    var follow: FollowBadge = .none
    var onFollow: () -> Void = {}
    /// The title and row the session had while it was live: an ended session's reply resumes its conversation in its folder.
    var lastTitle: String?
    var lastSession: RemoteSession?
    /// Continued or resumed from here: the hosted session that takes the page's place.
    @Binding var replaced: HostedSession?
    /// Opens the field for a message, for the stop button's Send a Message…; nil leaves that steer out.
    var onNote: (() -> Void)?
    var choosingModel: Binding<Bool>?
    /// A reply has gone.
    var onSent: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Continue or Resume in flight from the composer.
    @State private var bringingBack = false
    @State private var confirmingHandoff = false
    @State private var handoffKey = SendKey<HandoffAttempt>()
    @AppStorage("newSession.openOnMac") private var openOnMac = true

    private var session: RemoteSession? { model.sessions.session(sessionID) }
    private var openRequests: [RemoteRequest] { session?.openRequests.compactMap(model.requests.request) ?? [] }
    private var draft: String { model.transcripts.drafts[sessionID] ?? "" }
    private var handingOff: Bool { model.handoffs.sending(sessionID) }
    private var draftBinding: Binding<String> {
        Binding { model.transcripts.drafts[sessionID] ?? "" } set: { model.transcripts.drafts[sessionID] = $0 }
    }

    var body: some View {
        let offered = model.deliveries(sessionID)
        // Send hands off whichever way is picked, so with a handoff waiting there is no way to pick and the chip stays.
        let handsOff = model.handoffs[sessionID] != nil && session != nil
        Composer(text: draftBinding, placeholder: placeholder, canInterrupt: canInterrupt, showsFollow: showsFollow, follow: follow,
                 focused: $focused, onSend: { send(as: model.pickedDelivery(sessionID)) }, onInterrupt: { model.interrupt(sessionID) },
                 onFollow: onFollow, session: session, steers: Steer.available(for: session).filter { onNote != nil || $0 != .note },
                 onSteer: { model.steer($0, sessionID) { onNote?() } }, disabledReason: disabledReason,
                 unsent: model.transcripts.unsent[sessionID], onRetry: { model.retryUnsent(sessionID) },
                 notice: model.transcripts.notices[sessionID] ?? standingNotice,
                 deliveries: handsOff ? [] : offered, delivery: handsOff ? nil : model.delivery(sessionID),
                 onChooseDelivery: { model.chooseDelivery($0, for: sessionID) }, onDeliver: { send(as: $0) },
                 dropped: dropped == nil ? nil : session?.flag?.text, onRetryDropped: retryDropped, choosingModel: choosingModel)
            // The pick is for the turn that is running.
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
        if openRequests.contains(where: \.isQuestion) { return "Or type your own answer…" }
        // Through the inbox or a Stop hook, Claude reads it as a note, never as the user's own consent.
        if model.arrivesAsNote(sessionID) { return "Reply · arrives as a note" }
        if model.needsContinue(sessionID) { return "Reply · picks it up in Side A" }
        switch SessionPhase(session) {
        // Mid-turn the field says, before anything is typed, what Send will do with it.
        case .working: return model.sendsAs(sessionID)?.placeholder ?? "Message…"
        case .needsYou: return "Message…"
        default: return "Reply…"
        }
    }

    /// Under the field while nothing else is: where this session's replies go when that isn't the usual.
    private var standingNotice: String? {
        if handingOff, let draft = model.handoffs[sessionID] { return "Handing off to \(draft.agent.title) on \(model.mac.name)…" }
        if bringingBack { return session == nil ? "Resuming it on \(model.mac.name)…" : "Moving it into Side A on \(model.mac.name)…" }
        if model.needsContinue(sessionID) { return "It's idle in a terminal Side A can't type into. Sending moves it into Side A first." }
        return model.outsideSharedServer(sessionID) ? "Started outside Codex's shared server: replies arrive only after it finishes." : nil
    }

    /// Ended, with what Resume needs kept from its row.
    private var resumable: Bool {
        session == nil && model.tools.can(.hosted) && lastSession?.conversationID != nil && lastSession?.cwd != nil
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
        if bringingBack { return nil }
        if session == nil, lastTitle != nil, !resumable { return "This session has ended." }
        return session?.status == .unknown ? "\(model.mac.name) can't tell what this session is doing." : nil
    }

    /// `delivery`: the way picked for this turn; nil is the plain send, which the Mac's delivery table decides.
    private func send(as delivery: Delivery? = nil, confirmed: Bool = false) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !bringingBack, !handingOff else { return }
        if let handoff = model.handoffs[sessionID], let session { return handOff(session, handoff, text: text, confirmed: confirmed) }
        model.transcripts.drafts[sessionID] = ""
        // A waiting question takes the text as its "write your own" answer; a reply would get 409.
        if let question = openRequests.first(where: \.isQuestion), case .question(let questions) = question.action, questions.count == 1 {
            withAnimation(Motion.smooth(reduceMotion)) {
                model.requests.answer(question.id, .answers([QuestionAnswer(question: questions[0].question, picked: [], other: text)]))
            }
            return
        }
        if model.needsContinue(sessionID) { return continueThenSend(text) }
        if session == nil, resumable, let last = lastSession { return resume(last, with: text) }
        withAnimation(Motion.smooth(reduceMotion)) {
            if let delivery { model.send(text, to: sessionID, as: delivery) } else { model.reply(text, to: sessionID) }
            // The live link took the photos with the reply; the demo has nowhere to send them. Interrupt and Send
            // takes them once its reply goes, after the interrupt.
            if delivery != .interrupt { _ = model.tools.attachments.take(sessionID, for: model.transcripts.outgoing[sessionID]?.last?.id) }
        }
        onSent()
    }

    /// Continue on iPhone, then the reply, typed once the session is back in Side A's tmux. With the Mac tab setting on
    /// (New Session's), it gets a tab on the Mac again too.
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

    /// The session restarts as the other agent with the text as its message. The text stays in the field until the Mac
    /// has started it, so a refusal or a failure loses nothing.
    private func handOff(_ session: RemoteSession, _ draft: HandoffDraft, text: String, confirmed: Bool) {
        if !session.openRequests.isEmpty {
            return model.transcripts.notice("Answer or deny \(session.agent.title)'s open request first.", in: sessionID)
        }
        // Photos go to the new agent's first prompt when the Mac can take them; a Mac that can't leaves them in the tray
        // rather than leaving them behind unseen.
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
        // A question or prompt Side A doesn't hold as a request still waits on the person, in the terminal.
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
                    // The Mac cleared a photo it held (a week): the phone still has it, and the message stays in the field.
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

    /// Resume the ended conversation hosted, with the reply as its prompt.
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

/// The composer in a sheet, for Reply and Message from a list row or a card: the same field, photos, commands and draft as
/// the transcript's, over the session's last words.
struct ComposerSheet: View {
    let sessionID: SessionKey
    /// A way to deliver to start from, when the session offers it: a message for the next step, say.
    var delivery: Delivery?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focused = false
    @State private var started: HostedSession?
    /// Handed off from here: the sheet follows the new session, and gives its words back should it end before it starts.
    @State private var following: HostedSession?
    @State private var reviewingHandoff = false
    @State private var attachHeld = false
    @State private var detent = PresentationDetent.medium

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
            .sessionActions()
            .task {
                if let delivery, model.deliveries(sessionID).contains(delivery) { model.chooseDelivery(delivery, for: sessionID) }
                focused = true
            }
        }
        .environment(\.attachHeld, $attachHeld)
        // While the + holds the finger the sheet neither closes nor changes height, so a slide to the photos stays the +'s.
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
                SessionComposer(sessionID: sessionID, focused: $focused, replaced: $started,
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
