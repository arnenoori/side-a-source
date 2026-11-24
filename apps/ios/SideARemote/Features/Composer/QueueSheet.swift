import SideAProtocol
import SwiftUI

/// The messages waiting for the session's turn to end, in the order they go. Tap one to change its words; swipe to
/// take it out, or the other way to send it into the running turn instead of after it.
struct QueueSheet: View {
    let sessionID: SessionKey
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: QueuedReply?
    @State private var draft = ""
    @State private var failure: String?
    @State private var removed = 0
    @FocusState private var focused: Bool

    private var queued: [QueuedReply] { model.sessions.session(sessionID)?.queued ?? [] }
    /// The ways a waiting message can go before the turn ends; none once it has.
    private var sooner: [Delivery] { model.deliveries(sessionID).filter { $0 != .afterTurn } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(queued) { reply in
                        row(reply)
                            // No undo for either, so a long swipe alone never removes one or stops the turn.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Remove", systemImage: "trash", role: .destructive) { remove(reply) }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: sooner.first != .interrupt) {
                                if let first = sooner.first {
                                    Button(first.title, systemImage: first.symbol) { send(reply, as: first) }.tint(.accentColor)
                                }
                            }
                            .contextMenu {
                                ForEach(sooner, id: \.self) { delivery in
                                    Button(delivery.title, systemImage: delivery.symbol) { send(reply, as: delivery) }
                                }
                                Button("Remove", systemImage: "trash", role: .destructive) { remove(reply) }
                            }
                    }
                }
            }
            .navigationTitle("Queued")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if editing != nil {
                        Button("Save", action: save)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Done", systemImage: "checkmark") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }
                if editing != nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil }.keyboardShortcut(.cancelAction) }
                }
            }
            .alert("Couldn't Change the Queue", isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.impact(weight: .light), trigger: removed)
        // The last one went, here or because its turn came: nothing left to show.
        .onChange(of: queued.isEmpty) { _, empty in if empty { dismiss() } }
        .onChange(of: queued) { _, now in
            if let editing, !now.contains(where: { $0.id == editing.id }) { self.editing = nil }
        }
    }

    @ViewBuilder private func row(_ reply: QueuedReply) -> some View {
        if editing?.id == reply.id {
            TextField("Message", text: $draft, axis: .vertical)
                .focused($focused)
                .onAppear { focused = true }
        } else {
            Button {
                draft = reply.text
                editing = reply
            } label: {
                Text(reply.text).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edits this message")
        }
    }

    /// Undo only for the one message that was waiting: queued again, it is back exactly where it was. With others
    /// around it, it would land at the back, and the sheet would hide the notice anyway.
    private func remove(_ reply: QueuedReply) {
        if editing?.id == reply.id { editing = nil }
        removed += 1
        let alone = queued.count == 1, model = model, session = sessionID
        Task {
            do {
                guard try await model.removeQueued(reply, in: session), alone else { return }
                Pill.undoable("Removed from queue") {
                    if model.deliveries(session).contains(.afterTurn) { model.send(reply.text, to: session, as: .afterTurn) } else { model.reply(reply.text, to: session) }
                }
            } catch { failure = MacTools.message(error) }
        }
    }

    /// Out of the queue and into the turn. The reply goes only once the Mac has taken that very one out, so it can't
    /// arrive twice; one already gone or changed there isn't sent at all. A reply that then fails is back in the field
    /// with Retry, as any is.
    private func send(_ reply: QueuedReply, as delivery: Delivery) {
        if editing?.id == reply.id { editing = nil }
        removed += 1
        if model.sendNow(reply, in: sessionID, as: delivery) { return }
        Task {
            do {
                // The row stays until the Mac answers: the sheet closes once the queue is empty, and with it what it would say.
                guard try await model.removeQueued(reply, in: sessionID, optimistic: false) else {
                    tell("It had already gone or changed on \(model.mac.kind.the(model.mac.name)), so nothing was sent. The queue shows what's there now.")
                    return
                }
                model.send(reply.text, to: sessionID, as: delivery)
            } catch { tell(MacTools.message(error)) }
        }
    }

    /// Here while the sheet is up, and under the field for when it has closed.
    private func tell(_ message: String) {
        failure = message
        model.transcripts.notice(message, in: sessionID)
    }

    private func save() {
        guard let reply = editing else { return }
        let text = draft
        editing = nil
        Task {
            do { try await model.reword(reply, to: text, in: sessionID) } catch ToolError.cancelled {} catch { failure = MacTools.message(error) }
        }
    }
}

/// Over the field while messages wait: how many, and the way to them.
struct QueueChip: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("\(count) queued", systemImage: "text.append")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, Space.s)
                .frame(height: 36)
                .contentShape(.capsule)
                .hitArea(vertical: 4)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(count == 1 ? "1 queued message" : "\(count) queued messages")
    }
}
