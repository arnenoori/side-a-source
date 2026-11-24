import Foundation
import SideACore
import SideAProtocol

/// A Stop on a Codex turn through its app server, and Interrupt and Send's carry of what it dropped.
extension CodexTerminals {
    /// A plain Stop drops the steers Codex hasn't read, and they go back to the phone; with `send` they wait for the
    /// reply that follows and start the next turn with it.
    /// `resend`: no reply follows; what it drops goes again by itself once the turn has ended.
    func interrupt(_ live: LiveSession, send: Bool = false, resend: Bool = false) async throws(Failure) {
        #if DEBUG
        if staged != nil {
            guard let id = live.sessionID, var row = staged?[id], row.reach == .attached else { throw .notAttached }
            guard row.status == .working else { throw .rpc("No turn is running.") }
            row.status = .idle
            staged?[id] = row
            store?.remote.events?.liveChanged()
            return
        }
        #endif
        guard let (link, client, thread) = link(of: live) else { throw .notAttached }
        var turn = link.threads[thread]?.turn
        if turn == nil {
            // Attached mid-turn: the newest turn is the running one.
            let page = try? await client.call("thread/turns/list", .object(["threadId": .string(thread), "limit": .number(1)]))
            turn = page?["data"]?.array?.first.flatMap { $0["status"]?.string == "inProgress" ? $0["id"]?.string : nil }
        }
        guard let turn else { throw .rpc("No turn is running.") }
        let pending = link.threads[thread].map { Set($0.sent.keys) } ?? []
        link.threads[thread]?.interrupting = Interrupt(ids: pending, follows: .init(send: send, resend: resend))
        do {
            _ = try await client.call("turn/interrupt", .object(["threadId": .string(thread), "turnId": .string(turn)]))
        } catch {
            link.threads[thread]?.interrupting = nil
            throw Self.failure(error)
        }
    }

    /// Interrupt and Send: what the interrupt dropped waits for the reply, which `send` puts after it in one turn.
    /// A reply that doesn't come gives them back, as a plain Stop does.
    func hold(_ thread: String, _ link: Link, _ stop: Interrupt) {
        guard var state = link.threads[thread] else { return }
        let entries = state.sent.filter { stop.ids.contains($0.key) }.sorted { $0.value.at < $1.value.at }.map { (id: $0.key, text: $0.value.text) }
        guard !entries.isEmpty else { return }
        for entry in entries { state.sent[entry.id] = nil }
        let at = Date()
        state.carry = (entries, at)
        state.carryTimer?.cancel()
        link.threads[thread] = state
        if stop.follows == .resend, let live = store?.sessions.live.first(where: { $0.sessionID == thread }) {
            // A failed send gives them back itself.
            Task { [weak self] in _ = try? await self?.send(live, text: "", queue: false) }
        }
        link.threads[thread]?.carryTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ReplyReceipts.carry))
            guard let self, let carry = link.threads[thread]?.carry, carry.at == at else { return }
            link.threads[thread]?.carry = nil
            link.threads[thread]?.unsent = carry.entries.last.map { ($0.text, Date()) }
            for entry in carry.entries { self.store?.remote.receipts.codex(client: entry.id, .unsent, reason: ReplyReceipt.stopped(agent: .codex)) }
            self.store?.remote.events?.liveChanged()
        }
    }
}
