import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

private func snapshotEvent(epoch: String, seq: Int) throws -> ServerEvent {
    var event = try #require(JSONSerialization.jsonObject(with: Fixtures.data("ServerEvent.snapshot")) as? [String: Any])
    var data = try #require(event["data"] as? [String: Any])
    data["epoch"] = epoch
    data["seq"] = seq
    event["data"] = data
    return try JSONDecoder().decode(ServerEvent.self, from: JSONSerialization.data(withJSONObject: event))
}

@Test func aSliceAnsweredAfterANewEpochsSnapshotIsLeftOut() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let first = try await mac.socket(0)
    try first.push(fixture: "ServerEvent.welcome")
    try first.push(fixture: "ServerEvent.snapshot")
    try await until("snapshot") { await sync.state.seq == 41 }

    let paths = ["/v1/requests", "/v1/accounts"]
    let gates = paths.map { mac.hold($0) }
    let old: [String: Data] = ["/v1/requests": json(RequestList(requests: [], seq: 60)),
                               "/v1/accounts": json(AccountList(accounts: [], seq: 60))]
    mac.respond { request in old[request.url?.path ?? ""].map { .init(body: $0) } ?? .init(status: 404) }
    let refreshes = [Task { try await sync.refreshRequests() }, Task { try await sync.refreshAccounts() }]
    try await until("all asked") { gates.allSatisfy { $0.arrived == 1 } }

    first.serverClose(1001)
    let second = try await mac.socket(1)
    second.push(nil, welcome("f00d", seq: 2, replay: false))
    second.push(nil, try snapshotEvent(epoch: "f00d", seq: 2))
    try await until("new epoch") { await sync.state.epoch == "f00d" }
    let before = await sync.state
    #expect(before.accounts.count == 1 && before.requests.count == 1)

    for gate in gates { gate.open() }
    for refresh in refreshes { try await refresh.value }
    let after = await sync.state
    #expect(after.requests == before.requests && after.accounts == before.accounts)
    #expect(after.sliceSeq.isEmpty && after.seq == 2)
    await sync.stop()
}

@Test func aSliceAnsweredInTheSameEpochStillRefreshes() async throws {
    let mac = FakeMac()
    let sync = try engine(mac)
    await sync.start()
    let socket = try await mac.socket(0)
    try socket.push(fixture: "ServerEvent.welcome")
    try socket.push(fixture: "ServerEvent.snapshot")
    try await until("snapshot") { await sync.state.seq == 41 }
    let gate = mac.hold("/v1/requests")
    let list = json(RequestList(requests: [], seq: 60))
    mac.respond { _ in .init(body: list) }
    let refresh = Task { try await sync.refreshRequests() }
    try await until("asked") { gate.arrived == 1 }
    gate.open()
    try await refresh.value
    let state = await sync.state
    #expect(state.requests.isEmpty && state.sliceSeq[.requests] == 60 && state.seq == 41)
    await sync.stop()
}
