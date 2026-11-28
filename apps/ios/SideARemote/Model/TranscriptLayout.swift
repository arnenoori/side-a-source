import Foundation
import SideAProtocol
import SideASessionKit

// The transcript's layout is SideASessionKit's, shared with the Mac. These name it for the phone's own records of an
// answered request and a sent message.
typealias TranscriptItem = SideASessionKit.TranscriptItem<TranscriptStore.AnsweredRequest, TranscriptStore.Outgoing>
typealias TranscriptRow = SideASessionKit.TranscriptRow<TranscriptStore.AnsweredRequest, TranscriptStore.Outgoing>
typealias TranscriptLayout = SideASessionKit.TranscriptLayout<TranscriptStore.AnsweredRequest, TranscriptStore.Outgoing>
typealias TurnFold = SideASessionKit.TurnFold<TranscriptStore.AnsweredRequest, TranscriptStore.Outgoing>

extension TranscriptStore.Outgoing: OutgoingTurn {}
