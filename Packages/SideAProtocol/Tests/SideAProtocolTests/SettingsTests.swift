import Foundation
import SideAProtocol
import SideAProtocolFixtures
import Testing

@Test func modeRaisesAreTheWideningOnesAndAnythingUnknown() {
    let safe = [PermissionMode.default, .plan, .acceptEdits].filter(\.raises)
    #expect(PermissionMode.auto.raises && PermissionMode.dontAsk.raises)
    let raised = [PermissionMode.bypassPermissions, .never, .dangerFullAccess, PermissionMode(rawValue: "yolo")].filter { !$0.raises }
    #expect(safe.isEmpty && raised.isEmpty)
    #expect(SettingsChange(mode: .bypassPermissions).raises && !SettingsChange(model: "claude-sonnet-5-5", effort: .low).raises)
}

@Test func aSessionSaysWhyAnAbilityIsOff() throws {
    let session = try JSONDecoder().decode(RemoteSession.self, from: Fixtures.data("RemoteSession.settings"))
    #expect(session.reason(.type) == "Claude is working. Try when it's idle." && session.reason(.note) == nil)
}
