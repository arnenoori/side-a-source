import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

@Test func useAccountAppliesTheListTheMacReturns() async throws {
    let mac = FakeMac()
    let body = try Fixtures.data("AccountList.basic")
    mac.respond { _ in .init(body: body) }
    let engine = try engine(mac)
    try await engine.useAccount("0b9c2e4a-5f1d-4c1e-9a77-2f3e1d0c9b8a", confirm: "v1.1.c.AAAA")
    let accounts = await engine.state.accounts
    #expect(accounts["0b9c2e4a-5f1d-4c1e-9a77-2f3e1d0c9b8a"]?.active == true && accounts.count == 2)
}
