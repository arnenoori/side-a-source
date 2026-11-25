import Foundation
import SideAProtocol
import SideARemoteKit

extension TranscriptStore {
    /// A bubble whose reply the Mac's transcript names (`TranscriptMessage.replyID`, capability `replies.echo`) is settled by that
    /// id, in whatever stage it is: a reply that went offline, one a Stop hook delivered mid-turn and one the window was
    /// refetched around all reach the same row, which then takes the bubble's place. Words and times only settle what the
    /// Mac didn't name.
    func settleByEcho(_ session: SessionKey) {
        guard let turns = outgoing[session], !turns.isEmpty else { return }
        let named = (messages[session] ?? []).filter { $0.role == .user && $0.replyID != nil }
        guard !named.isEmpty else { return }
        for turn in turns {
            guard let item = turn.item, let row = named.first(where: { $0.replyID == ReplyReceipt.family(item) }) else { continue }
            settledBy[session, default: []].insert(row.uuid)
            move(turn.id, in: session, ReplyBubble.showable.contains(turn.state) ? .shown(bound: true) : .withdrawn)
        }
    }
}
