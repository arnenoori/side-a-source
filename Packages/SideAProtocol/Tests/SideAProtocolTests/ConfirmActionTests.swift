import Foundation
import SideAProtocol
import Testing

@Test func anActionsSubjectCoversItsTargetAndBody() throws {
    let quit = ConfirmMessage.subject(action: .quit, target: "s1")
    #expect(quit != ConfirmMessage.subject(action: .quit, target: "s2"))
    #expect(quit != ConfirmMessage.subject(action: .restart, target: "s1"))
    let one = try ConfirmMessage.subject(action: .reply, target: "s1", body: RemoteReply(text: "yes"))
    #expect(one != (try ConfirmMessage.subject(action: .reply, target: "s1", body: RemoteReply(text: "no"))))
    #expect(try ConfirmMessage.text(macID: "m", deviceID: "d", purpose: .action, subject: quit, at: 1).contains("action"))
}

@Test func aModeTheMacCantReadCountsAsPermissive() {
    #expect(ConfirmPolicy.session(mode: nil) == .biometric)
    #expect(ConfirmPolicy.session(mode: .bypassPermissions) == .biometric && ConfirmPolicy.session(mode: .auto) == .biometric && ConfirmPolicy.session(mode: .dontAsk) == .biometric)
    #expect(ConfirmPolicy.session(mode: .default) == .unlock && ConfirmPolicy.session(mode: .plan) == .unlock && ConfirmPolicy.session(mode: .acceptEdits) == .unlock)
    #expect(ConfirmPolicy.runsShell("\n\t !ls") && !ConfirmPolicy.runsShell("say !ls"))
}
