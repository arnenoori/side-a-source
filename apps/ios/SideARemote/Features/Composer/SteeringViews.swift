import SideAProtocol
import SwiftUI

/// Send a Message…: a focused field and Send in the toolbar; the session reads it at its next step.
struct MessageSheet: View {
    let sessionID: SessionKey
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var session: RemoteSession? { model.sessions.session(sessionID) }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should it know?", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                }
            }
            .navigationTitle("Message")
            .navigationSubtitle(session?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", systemImage: "arrow.up") {
                        model.note(trimmed, to: sessionID)
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(trimmed.isEmpty)
                    .needsMac()
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(240), .medium])
        // Writing wants a quiet page: glass over a busy transcript reads as smudge behind the field.
        .presentationBackground(Color(.systemGroupedBackground))
    }
}

/// A turn this phone sent that the Mac's transcript doesn't show yet, with where it is under it:
/// "Sending…", "Next step" while it waits for the session's next step, or nothing once taken. A tap on a waiting
/// message offers Edit (back into the field, to send again), Copy and Delete; a long-press selects part of it.
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
            status
                .labelStyle(.titleAndIcon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.trailing, Space.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(Motion.smooth(reduceMotion), value: turn.state)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var status: some View {
        if case .offline(let reason) = model.mac.state, turn.state != .sent, turn.state != .read {
            // Out of reach, nothing here is known to have gone or still to be waiting.
            Label("Not confirmed", systemImage: reason.symbol)
        } else {
            switch turn.state {
            case .sending:
                Text("Sending…")
            case .sent, .read:
                EmptyView()
            case .queued:
                Label("After this turn", systemImage: "text.append")
            case .note:
                Label("Next step", systemImage: "clock")
            case .takingBack:
                Label("Taking back…", systemImage: "arrow.uturn.backward")
            }
        }
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

/// A message waiting for the next step that this phone didn't send (or a stop): a quiet line; a tap or long-press
/// offers to withdraw it.
struct MailLine: View {
    let sessionID: SessionKey
    let mail: MailState
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taking = false

    private var offline: Bool { model.mac.isOffline }

    private var withdraw: String { mail.kind == .stop ? "Cancel Stop" : "Delete Message" }

    var body: some View {
        Label(taking ? (mail.kind == .stop ? "Cancelling…" : "Deleting…")
                     : mail.kind == .stop ? "Stops after this step" : "Message waiting",
              systemImage: mail.kind == .stop ? "pause.circle" : "clock")
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
            // A refused withdraw says so under the field; the line can be tried again.
            .onChange(of: model.transcripts.notices[sessionID]) { _, notice in if notice != nil { taking = false } }
    }

    private func takeBack() {
        taking = true
        withAnimation(Motion.smooth(reduceMotion)) { model.takeBack(sessionID, keepText: false) }
    }
}
