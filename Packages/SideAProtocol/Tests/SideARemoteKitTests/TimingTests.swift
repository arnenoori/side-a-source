import Foundation
import SideAProtocol
import SideARemoteKit
import Testing

@Test func waitsOnBothSidesStayInStep() {
    #expect(InterruptTiming.macWaits <= InterruptTiming.phoneWaits && InterruptTiming.phoneWaits < InterruptTiming.carried)
    #expect(SyncTiming().macForgets == SocketTiming.silentFor)
    #expect(TranscribeRoute.timeout > TranscribeRoute.macProvider + TranscribeRoute.macListing)
    #expect(Outbox.Item.replyLifetime < ReplyFlight.waitingLifetime)
}
