import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import SwiftUI

struct OutgoingBubble: View {
    let sessionID: SessionKey
    let turn: TranscriptStore.Outgoing
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let photos = model.tools.attachments.sent[turn.id] {
                HStack(spacing: Space.xs) {
                    ForEach(photos.indices, id: \.self) { index in
                        Image(uiImage: photos[index])
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("^[\(photos.count) photo](inflect: true)")
            }
            MaxWidthFraction(fraction: 0.8) {
                SelectableText(text: AttributedString(turn.text), style: SelectableText.Style(lineSpacing: 0), menu: menu)
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s)
                    .background(Color(.secondarySystemFill), in: .rect(cornerRadius: Radius.userBubble, style: .continuous))
                    .opacity(turn.state == .sending || turn.state == .takingBack ? 0.6 : 1)
            }
            DeliveryStatus(sessionID: sessionID, turn: turn)
                .padding(.trailing, Space.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(Motion.smooth(reduceMotion), value: turn.state)
        .accessibilityElement(children: .contain)
    }

    private var menu: [SelectableText.Action] {
        let copy = SelectableText.Action(title: "Copy", image: "doc.on.doc") { UIPasteboard.general.string = turn.text }
        if model.mac.isOffline { return [copy] }
        guard turn.state == .note else { return [copy] }
        return [
            .init(title: "Edit", image: "pencil") { takeBack(keepText: true) },
            copy,
            .init(title: "Delete", image: "trash", destructive: true) { takeBack(keepText: false) },
        ]
    }

    private func takeBack(keepText: Bool) {
        withAnimation(Motion.smooth(reduceMotion)) { model.takeBack(sessionID, keepText: keepText) }
    }
}

private struct DeliveryStatus: View {
    let sessionID: SessionKey
    let turn: TranscriptStore.Outgoing
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(verbatim: " ").hidden()
            TimelineView(.periodic(from: .now, by: 5)) { context in line(at: context.date) }
        }
        .font(.footnote)
    }

    @ViewBuilder private func line(at now: Date) -> some View {
        let session = model.sessions.session(sessionID)
        let working = session.map { SessionPhase($0) == .working } == true
        let since = turn.since ?? turn.at
        let unchecked = turn.unchecked
        let late = !unchecked && (ReplyProgress.patience(turn.state).map { now.timeIntervalSince(since) > $0 } ?? false)
        let followed = session?.receipts?.contains { $0.answers(turn.item) } == true
        let frees = late && working && followed && session.map(model.stopGivesBack) == true && !model.mac.shown.isOffline
            && ReplyProgress(turn.state, overdue: true).actions(interrupts: true).contains(.interruptAndSend)
        if let words = unchecked ? (text: "Can't check: Side A restarted on \(model.mac.name)", symbol: "questionmark.circle")
            : words(session, working: working, followed: followed, late: late, since: since, now: now) {
            let label = Label(words.text, systemImage: words.symbol)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(late ? AnyShapeStyle(.amberText) : AnyShapeStyle(.secondary))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s) {
                    label
                    if frees { interruptButton }
                }
                VStack(alignment: .trailing, spacing: Space.xxs) {
                    label
                    if frees { interruptButton }
                }
            }
            .animation(Motion.smooth(reduceMotion), value: frees)
            .onChange(of: frees) { _, frees in
                guard frees else { return }
                var announcement = AttributedString("\(words.text). \(Delivery.interrupt.title) is available.")
                announcement.accessibilitySpeechAnnouncementPriority = .low
                AccessibilityNotification.Announcement(announcement).post()
            }
        }
    }

    private var interruptButton: some View {
        Button(Delivery.interrupt.title) { model.interruptAndResend(sessionID) }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
            .hitArea(vertical: 12)
            .accessibilityHint("Stops the current step, then sends the message as the next prompt.")
    }

    private func words(_ session: RemoteSession?, working: Bool, followed: Bool, late: Bool, since: Date, now: Date) -> (text: String, symbol: String)? {
        let agent = session?.agent.title ?? AgentProvider.claude.title
        let elapsed = Formatting.elapsed(since: since, now: now)
        let waited = late && elapsed != "now" ? " · \(elapsed)" : ""
        let step = session?.step.map { "\u{201C}\($0)\u{201D}" } ?? "this step"
        if turn.state == .sending, model.mac.isAway { return (SendsWhenConnected.line, SendsWhenConnected.symbol) }
        if case .offline(let reason) = model.mac.shown, ![.sent, .held, .read].contains(turn.state) {
            return ("Can't check until connected", reason.symbol)
        }
        switch turn.state {
        case .sending: return (late ? "Waiting for \(model.mac.name)…" : "Sending…", "arrow.up")
        case .sent where followed: return (late ? "\(agent) hasn't taken it\(waited)" : "Sent", "paperplane")
        case .sent: return working ? ("\(agent) reads it after this step", "clock") : ("Sent", "paperplane")
        case .held: return (working ? "\(agent) reads it after \(step)\(waited)" : "\(agent) reads it next", late ? "hourglass" : "clock")
        case .note: return ("\(agent) reads it after this step\(waited)", late ? "hourglass" : "clock")
        case .queued: return ("\(agent) reads it after this turn", "text.append")
        case .read: return ("Read by \(agent)", "checkmark")
        case .takingBack: return ("Taking back…", "arrow.uturn.backward")
        case .unsent, .withdrawn: return nil
        }
    }
}

struct MailLine: View {
    let sessionID: SessionKey
    let mail: MailState
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taking = false

    private var offline: Bool { model.mac.isOffline }

    private var withdraw: String { mail.kind == .stop ? "Cancel Stop" : "Delete Message" }

    var body: some View {
        Label(taking ? (mail.kind == .stop ? "Cancelling…" : "Deleting…") : mail.kind.line, systemImage: mail.kind.symbol)
            .foregroundStyle(.secondary)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Radius.inlineCard, style: .continuous))
            .overlay {
                if !taking, !offline {
                    EditMenuArea(menu: [.init(title: withdraw, image: mail.kind == .stop ? "play.circle" : "trash",
                                              destructive: mail.kind == .note) { takeBack() }])
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: withdraw) { takeBack() }
            .onChange(of: model.transcripts.notices[sessionID]) { _, notice in if notice != nil { taking = false } }
    }

    private func takeBack() {
        taking = true
        withAnimation(Motion.smooth(reduceMotion)) { model.takeBack(sessionID, keepText: false) }
    }
}
