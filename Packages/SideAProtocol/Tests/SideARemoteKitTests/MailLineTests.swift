import SideAProtocol
import SideARemoteKit
import Testing

@Test func onlyAStopTheMacNamesReadsAsAStop() {
    #expect(MailState.Kind.stop.line == "Stops after this step" && MailState.Kind.stop.symbol == "pause.circle")
    for kind in [MailState.Kind.note, MailState.Kind(rawValue: "later")] {
        #expect(kind.line == "Message waiting" && kind.symbol == "clock", "\(kind.rawValue)")
    }
}
