import SideAProtocol
import SwiftUI

struct QueueSheet: View {
    let sessionID: SessionKey
    let edit: (QueuedReply) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var removed = 0

    private var queued: [QueuedReply] { model.sessions.session(sessionID)?.queued ?? [] }
    private var sooner: [Delivery] { model.deliveries(sessionID).filter { $0 != .afterTurn } }

    var body: some View {
        NavigationStack {
            List {
                ForEach(queued) { reply in
                    row(reply)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Remove", systemImage: "trash", role: .destructive) { remove(reply) }
                        }
                        .contextMenu {
                            ForEach(sooner, id: \.self) { delivery in
                                Button(delivery.title, systemImage: delivery.symbol) { send(reply, as: delivery) }
                            }
                            Button("Remove", systemImage: "trash", role: .destructive) { remove(reply) }
                        }
                }
            }
            .navigationTitle("Queued")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .alert("Couldn't Change the Queue", isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.impact(weight: .light), trigger: removed)
        .onChange(of: queued.isEmpty) { _, empty in if empty { dismiss() } }
    }

    private func row(_ reply: QueuedReply) -> some View {
        HStack(spacing: Space.xs) {
            Button {
                edit(reply)
                dismiss()
            } label: {
                Text(reply.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edits this message in the composer")
            if let first = sooner.first {
                Button("Send Now") { send(reply, as: first) }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityHint(first.hint)
            }
            Button("Remove", systemImage: "xmark") { remove(reply) }
                .labelStyle(IconTarget(size: CGSize(width: 44, height: 32), vertical: 6))
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
        }
    }

    private func remove(_ reply: QueuedReply) {
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
        removed += 1
        if model.sendNow(reply, in: sessionID, as: delivery) { return }
        Task {
            do {
                guard try await model.removeQueued(reply, in: sessionID, optimistic: false) else {
                    tell("It had already gone or changed on \(model.mac.kind.the(model.mac.name)), so nothing was sent. The queue shows what's there now.")
                    return
                }
                model.send(reply.text, to: sessionID, as: delivery)
            } catch { tell(MacTools.message(error)) }
        }
    }

    private func tell(_ message: String) {
        failure = message
        model.transcripts.notice(message, in: sessionID)
    }
}

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
