import Foundation
import SideAProtocol
import SideAProtocolFixtures
import Testing

@Suite struct HandoffTests {
    @Test(arguments: [
        (PermissionMode.default, AgentProvider.codex, PermissionMode.default, true),
        (.plan, .codex, .default, false),
        (.acceptEdits, .codex, .default, false),
        (.auto, .codex, .default, false),
        (.dontAsk, .codex, .never, true),
        (.bypassPermissions, .codex, .dangerFullAccess, true),
        (.default, .claude, .default, true),
        (.never, .claude, .dontAsk, true),
        (.dangerFullAccess, .claude, .bypassPermissions, true),
        (.plan, .claude, .plan, true),
        (PermissionMode(rawValue: "someday"), .claude, .default, false),
    ])
    func handoffPermissionModeMapping(_ from: PermissionMode, _ agent: AgentProvider, _ expected: PermissionMode, _ exact: Bool) {
        let mapped = PermissionMode.handedOff(from, to: agent)
        #expect(mapped.mode == expected && mapped.exact == exact)
    }

    @Test func handoffPermissionModeKeepsWhetherItRaises() {
        for mode in [PermissionMode.default, .plan, .acceptEdits, .auto, .dontAsk, .bypassPermissions] {
            let mapped = PermissionMode.handedOff(mode, to: .codex)
            if mapped.exact { #expect(mapped.mode.raises == mode.raises) }
        }
    }

    @Test func handoffRestartAsksForFaceIDForARaisingModeOrAShellMessage() {
        let handoff = Handoff(goal: "g", failed: "", next: "", lastMessages: "", cwd: "/a", project: "a")
        #expect(ConfirmPolicy.restart(RestartRequest(handoff: handoff, agent: .codex), sessionMode: .default) == .unlock)
        #expect(ConfirmPolicy.restart(RestartRequest(handoff: handoff, agent: .codex, permissionMode: .dangerFullAccess), sessionMode: .default) == .biometric)
        #expect(ConfirmPolicy.restart(RestartRequest(handoff: handoff, agent: .codex, message: "!rm -rf build"), sessionMode: .default) == .biometric)
        #expect(ConfirmPolicy.restart(RestartRequest(handoff: handoff), sessionMode: .bypassPermissions) == .biometric)
    }

    @Test func handoffFixturesDecode() throws {
        let request = try JSONDecoder().decode(RestartRequest.self, from: try Fixtures.data("RestartRequest.agent"))
        #expect(request.agent == .codex && request.message?.hasPrefix("Take it") == true)
        let row = try JSONDecoder().decode(RemoteSession.self, from: try Fixtures.data("RemoteSession.handoff"))
        #expect(row.handoffFrom?.agent == .claude && row.handoffFrom?.prompt == true)
        let old = try JSONDecoder().decode(RestartRequest.self, from: try Fixtures.data("RestartRequest.edited"))
        #expect(old.agent == nil && old.message == nil && old.handoff.plan == nil && old.attachments == nil)
    }

    @Test func handoffPhotosAreAnAdditiveOptionalField() throws {
        let photos = try JSONDecoder().decode(RestartRequest.self, from: try Fixtures.data("RestartRequest.agent-photos"))
        #expect(photos.agent == .claude && photos.attachments == ["0123456789ab", "ba9876543210"])
        let plain = RestartRequest(handoff: photos.handoff, agent: .codex, message: "m", attachments: [])
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(plain.attachments == nil && !json.contains("attachments"))
        #expect(Capability.restartAgentImages.rawValue == "restart.agent.images")
    }
}
