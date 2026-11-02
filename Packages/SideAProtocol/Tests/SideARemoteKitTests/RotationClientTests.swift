import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

/// The phone says it can show rotation pushes, in every `hello`.
@Test func theClientAdvertisesRotation() {
    #expect(ClientInfo.current.capabilities.contains(.rotation))
}

@Test func anAutopilotUpdateMovesTheStateAndAnOlderSnapshotLeavesItAlone() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    try socket.push(fixture: "ServerEvent.welcome")
    try socket.push(fixture: "ServerEvent.snapshot")
    try await until("snapshot") { await sync.state.seq == 41 }
    #expect(await sync.state.autopilot == nil)
    let state = AutopilotState(enabled: true, next: [NextMove(id: "a", from: "Work", to: "Personal", atPercent: 95, minutes: 40)], swapAt: 95)
    socket.push(42, .autopilotUpdate(state))
    try await until("update") { await sync.state.seq == 42 }
    #expect(await sync.state.autopilot == state)
    // An event this build doesn't know moves the seq, and nothing else.
    socket.push(43, .unknown(type: "rotation.tomorrow"))
    try await until("unknown") { await sync.state.seq == 43 }
    #expect(await sync.state.autopilot == state && mac.sockets.count == 1)
    await sync.stop()
}

/// Each signed change goes to its route, with its signature and an idempotency key.
@Test func signedChangesCarryTheirSignature() async throws {
    let mac = FakeMac()
    let accounts = try Fixtures.data("AccountList.basic")
    let autopilot = Data(#"{"enabled":true,"decisions":[],"swapAt":90,"followFable":false}"#.utf8)
    mac.respond { request in
        .init(body: request.url?.path.contains("/rotation/") == true ? autopilot : accounts)
    }
    let client = try await engine(mac).client
    _ = try await client.setPriority("a1", .last, confirm: "v1.1.c.AAAA")
    _ = try await client.setAuto("a1", false, confirm: "v1.2.c.AAAA")
    #expect(try await client.setSwapAt(90, confirm: "v1.3.c.AAAA").swapAt == 90)
    #expect(try await client.setFollowFable(false, confirm: "v1.4.c.AAAA").followFable == false)
    let sent = mac.requests.filter { $0.httpMethod == "POST" }
    #expect(sent.map { $0.url?.path } == ["/v1/accounts/a1/priority", "/v1/accounts/a1/auto", "/v1/rotation/swap-at", "/v1/rotation/follow-fable"])
    #expect(sent.map { $0.value(forHTTPHeaderField: ConfirmSignature.header) } == ["v1.1.c.AAAA", "v1.2.c.AAAA", "v1.3.c.AAAA", "v1.4.c.AAAA"])
    #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty == false })
}
