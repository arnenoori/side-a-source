import AppKit
import SideACore
import SideAProtocol
import SideASessionKit
import SwiftUI

/// A message sent from this window, shown at the end of the conversation until the conversation shows it itself.
struct Outgoing: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let at: Date
}

extension SessionDesk {
    /// One that hasn't shown up after this long is taken down: it went as something the conversation words differently.
    nonisolated static let outgoingKept: TimeInterval = 90

    func sending(_ text: String, to id: String, at: Date = Date()) -> UUID? {
        guard !text.isEmpty else { return nil }
        let sent = Outgoing(text: text, at: at)
        outgoing[id, default: []].append(sent)
        return sent.id
    }

    /// The send has answered. One that waits for the turn, or went as a note, is said by the line under the field, and
    /// one that failed is back in the draft's Retry; only one typed into the conversation stays until it is echoed.
    func sent(_ sent: UUID?, in id: String, shows: Bool) {
        guard let sent, !shows else { return }
        outgoing[id]?.removeAll { $0.id == sent }
    }

    /// The conversation was read again: what it now shows is no longer on its way.
    func settle(_ id: String, said: [(text: String, at: Double?)], now: Date = Date()) {
        guard let waiting = outgoing[id], !waiting.isEmpty else { return }
        outgoing[id] = Self.unsettled(waiting, said: said, now: now)
    }

    nonisolated static func unsettled(_ waiting: [Outgoing], said: [(text: String, at: Double?)], now: Date) -> [Outgoing] {
        var said = said
        return waiting.filter { sent in
            guard now.timeIntervalSince(sent.at) < outgoingKept else { return false }
            // Each echo settles one message, so the same words sent twice both show until both arrive.
            guard let index = said.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == sent.text && ($0.at ?? .infinity) >= sent.at.timeIntervalSince1970 - 5 }) else { return true }
            said.remove(at: index)
            return false
        }
    }

    /// What the user said to this conversation, newest first, for ↑ in an empty field.
    func prompts(_ id: String) -> [String] {
        let said = (wire[id]?.messages ?? []).filter { $0.role == .user }.compactMap(\.text)
        return PromptRecall.newestFirst(said + (outgoing[id] ?? []).map(\.text))
    }
}

/// ↑ in an empty message field brings back the last thing said, and again the one before.
enum PromptRecall {
    static func newestFirst(_ said: [String]) -> [String] {
        var seen = Set<String>()
        return said.reversed().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The draft and place after ↑ (`delta` 1) or ↓ (-1). Nil when the key is the text's own: there is a draft that
    /// isn't a recalled prompt, or nothing further that way.
    static func step(_ delta: Int, draft: String, at index: Int?, prompts: [String]) -> (draft: String, index: Int?)? {
        let recalled = index.flatMap { prompts.indices.contains($0) ? prompts[$0] : nil }
        guard draft.isEmpty || draft == recalled else { return nil }
        let next = (draft.isEmpty ? -1 : index ?? -1) + delta
        if next < 0 { return draft.isEmpty ? nil : ("", nil) }
        guard prompts.indices.contains(next) else { return nil }
        return (prompts[next], next)
    }
}

extension SessionStore {
    /// The replies waiting for this session's turn to end, in the order they go.
    func queued(_ id: String) -> [QueuedReply] {
        _ = desk.queueTick
        return store.island.waiting(id)
    }

    func removeQueued(_ id: String, _ reply: QueuedReply) {
        store.island.removeQueued(id, id: reply.id)
        if desk.rewording[id] == reply.id { desk.rewording[id] = nil }
        desk.queueTick += 1
    }

    /// Out of the queue and to the session now; it goes back in if that fails.
    func sendQueuedNow(_ id: String, _ reply: QueuedReply) {
        if desk.rewording[id] == reply.id { desk.rewording[id] = nil }
        self.reply(reply.text, to: id, how: .now, promotes: reply.id)
    }

    func reword(_ id: String, _ reply: QueuedReply) {
        drafts[id] = reply.text
        desk.rewording[id] = reply.id
        desk.composerFocus += 1
    }
}

/// Replies waiting for the turn to end, above the message field: reword one by clicking it, send it now, or drop it.
struct QueuedList: View {
    let model: SessionStore
    let id: String
    let replies: [QueuedReply]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(replies) { reply in
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.caption).foregroundStyle(.tertiary)
                    Button { model.reword(id, reply) } label: {
                        Text(reply.text).font(.callout).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(model.desk.rewording[id] == reply.id ? Color.accentColor : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Reword")
                    Button("Send Now") { model.sendQueuedNow(id, reply) }.buttonStyle(.link).font(.caption.weight(.semibold))
                    Button { model.removeQueued(id, reply) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Remove").accessibilityLabel("Remove")
                }
                .padding(.horizontal, 10).frame(height: 26)
                .background(Ink.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Waiting: \(reply.text)")
                .accessibilityAction(named: "Reword") { model.reword(id, reply) }
                .accessibilityAction(named: "Send Now") { model.sendQueuedNow(id, reply) }
                .accessibilityAction(named: "Remove") { model.removeQueued(id, reply) }
            }
        }
    }
}

/// Files under the session's folder that match the `@word` being typed.
struct MentionList: View {
    let paths: [String]
    let highlighted: Int
    let choose: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                let row = SideASessionKit.FileMentions.Row(path: path)
                Button { choose(path) } label: {
                    HStack(spacing: 8) {
                        Text(row.name).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(index == highlighted ? Color.white : .primary).lineLimit(1)
                        Text(row.folder).font(.system(size: 12)).lineLimit(1).truncationMode(.head)
                            .foregroundStyle(index == highlighted ? Color.white.opacity(0.85) : .secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(index == highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(path)
                .accessibilityAddTraits(index == highlighted ? .isSelected : [])
            }
        }
        .padding(5)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files")
    }
}
