import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

@Test func modelsAskForOneAgentAndOptionallyASession() async throws {
    let mac = FakeMac()
    let list = try Fixtures.data("ModelList.codex")
    mac.respond { _ in .init(body: list) }
    let client = RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac, cache: ResponseCache())
    _ = try await client.models(.claude)
    _ = try await client.models(.codex, session: "c1")
    #expect(mac.calls.map { $0.url?.query } == ["kind=claude", "kind=codex&session=c1"])
}

@Test func anAllowWithAModeQueuesItsOwnItemCarryingTheMode() async throws {
    let mac = FakeMac()
    let engine = try engine(mac)
    let item = await engine.answer("r1", .allow(confirmDestructive: false), mode: .acceptEdits, confirm: "v1.1.u.AAAA")
    #expect(item.id == "r1:allowMode" && item.confirm == "v1.1.u.AAAA")
    let body = try JSONDecoder().decode(AnswerBody.self, from: item.body)
    #expect(body.answer == .allow(confirmDestructive: false) && body.mode == .acceptEdits)
    let plain = await engine.answer("r2", .allow(confirmDestructive: false))
    #expect(plain.id == "r2:allow")
}
