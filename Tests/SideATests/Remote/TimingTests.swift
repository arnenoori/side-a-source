import Foundation
@testable import SideA
import SideAProtocol
import Testing

@MainActor @Test func theMacsWaitsAreTheOnesThePhoneIsBuiltAround() {
    #expect(CodexTerminals.carryWait == InterruptTiming.macWaits && ReplyReceipts.carry == InterruptTiming.carried)
    #expect(WebSocketPeer.silentFor == SocketTiming.silentFor)
    #expect(HostedSessions.takeBackWait == .seconds(8) && Int(HostedSessions.takeBackWait / HostedSessions.takeBackEvery) == 32)
}
