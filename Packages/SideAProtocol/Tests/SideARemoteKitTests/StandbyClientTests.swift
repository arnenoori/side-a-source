import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

private struct StandbyCall: Sendable, CustomTestStringConvertible {
    let name: String
    var status = 200
    let reply: @Sendable () throws -> Data
    let method: String, path: String
    var confirm: String?
    var keyed = false
    let call: @Sendable (RemoteClient) async throws -> Void
    var testDescription: String { name }
}

private let standbyCalls: [StandbyCall] = [
    StandbyCall(name: "standby", reply: { try Fixtures.data("StandbyList.one") }, method: "GET", path: "/v1/standby") {
        let list = try await $0.standby()
        #expect(list.copies.map(\.computerName) == ["MacBook"] && list.copies.first?.conversationID == "a06442e2-3f6b-4a35-931a-a4599bfa8acd")
    },
    StandbyCall(name: "copy", status: 201, reply: { try Fixtures.data("MoveState.live") }, method: "POST",
                path: "/v1/standby/a06442e2-3f6b-4a35-931a-a4599bfa8acd/copy", confirm: "v1.1.c.AAAA", keyed: true) {
        let state = try await $0.continueCopy("a06442e2-3f6b-4a35-931a-a4599bfa8acd", confirm: "v1.1.c.AAAA")
        #expect(state.status == .live && state.session == "sa-app-1a2b" && state.folder?.hasSuffix("/sa-app-1a2b") == true)
    },
]

@Test(arguments: standbyCalls)
private func aStandbyRouteIsCalledAsTheProtocolSays(_ row: StandbyCall) async throws {
    let mac = FakeMac()
    let reply = try row.reply()
    mac.respond { _ in .init(status: row.status, body: reply) }
    try await row.call(RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac, cache: ResponseCache()))
    let sent = try #require(mac.calls.last)
    #expect(sent.httpMethod == row.method && sent.url?.path == row.path)
    #expect(sent.value(forHTTPHeaderField: ConfirmSignature.header) == row.confirm)
    #expect((sent.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty == false) == row.keyed)
    #expect(sent.httpBody == nil)
}

@Test func aCopyWaitsForTheHostToStartItUnderTheCallersKey() async throws {
    let mac = FakeMac()
    let live = try Fixtures.data("MoveState.live")
    mac.respond { _ in .init(status: 201, body: live) }
    let client = RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac)
    _ = try await client.continueCopy("c1", confirm: "v1.1.c.AAAA", idempotencyKey: "key-1")
    let sent = try #require(mac.calls.last)
    #expect(sent.value(forHTTPHeaderField: "Idempotency-Key") == "key-1")
    #expect(sent.timeoutInterval == RemoteClient.copyWaits && RemoteClient.copyWaits > 30)
}

@Test func aRefusedCopyCarriesTheSentenceToShow() async throws {
    let mac = FakeMac()
    let refusal = #"{"error":{"code":"move_refused","message":"That session is already running on Mac mini.","retryable":false}}"#
    mac.respond { _ in .init(status: 409, body: Data(refusal.utf8)) }
    let client = RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac)
    do {
        _ = try await client.continueCopy("c1", confirm: "v1.1.c.AAAA")
        Issue.record("a refusal decoded as a copy")
    } catch let failure as RemoteFailure {
        #expect(failure.status == 409 && failure.error.code == .moveRefused && failure.error.message == "That session is already running on Mac mini.")
    }
}
