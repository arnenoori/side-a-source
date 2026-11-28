import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

private struct MoveCall: Sendable, CustomTestStringConvertible {
    let name: String
    var status = 200
    let reply: @Sendable () throws -> Data
    let method: String, path: String
    var confirm: String?
    var body: String?
    var keyed = false
    let call: @Sendable (RemoteClient) async throws -> Void
    var testDescription: String { name }
}

private func record(_ state: MoveRecord.State, session: String? = nil) -> MoveRecord {
    MoveRecord(id: "mv-4f2a9c1e7b3d", conversationID: "a06442e2-3f6b-4a35-931a-a4599bfa8acd", agent: .claude, title: "Fix the login redirect",
               project: "app", state: state, computer: "9c1e7b3d4f2a5b6c", computerName: "Mac mini", at: 1_800_000_000, session: session)
}

private let moveBody = #"{"computer":"9c1e7b3d4f2a5b6c"}"#

private let moveCalls: [MoveCall] = [
    MoveCall(name: "computers", reply: { try Fixtures.data("ComputerList.two") }, method: "GET", path: "/v1/computers") {
        let list = try await $0.computers()
        #expect(list.computers.map(\.name) == ["Mac mini", "build-box"])
    },
    MoveCall(name: "preview", reply: { try Fixtures.data("MovePreview.sent") }, method: "POST", path: "/v1/sessions/s1/move/preview",
             body: moveBody, keyed: true) {
        let preview = try await $0.movePreview("s1", MoveRequest(computer: "9c1e7b3d4f2a5b6c"))
        #expect(preview.login == .sent && preview.account == "Work" && preview.computer.name == "Mac mini")
    },
    MoveCall(name: "move", status: 202, reply: { try JSONEncoder().encode(record(.moving)) }, method: "POST", path: "/v1/sessions/s1/move",
             confirm: "v1.1.c.AAAA", body: moveBody, keyed: true) {
        let moved = try await $0.move("s1", MoveRequest(computer: "9c1e7b3d4f2a5b6c"), confirm: "v1.1.c.AAAA")
        #expect(moved.state == .moving && moved.id == "mv-4f2a9c1e7b3d")
    },
    MoveCall(name: "moves", reply: { try Fixtures.data("MoveList.states") }, method: "GET", path: "/v1/moves") {
        let list = try await $0.moves()
        #expect(list.moves.map(\.state) == [.away, .unknown])
    },
    MoveCall(name: "check", reply: { try JSONEncoder().encode(record(.away, session: "sa-app-1a2b")) }, method: "POST",
             path: "/v1/moves/mv-4f2a9c1e7b3d/check", keyed: true) {
        let checked = try await $0.checkMove("mv-4f2a9c1e7b3d")
        #expect(checked.state == .away && checked.session == "sa-app-1a2b")
    },
    MoveCall(name: "after this turn", status: 202, reply: { try JSONEncoder().encode(record(.waiting)) }, method: "POST", path: "/v1/sessions/s1/move",
             confirm: "v1.1.c.AAAA", body: #"{"computer":"9c1e7b3d4f2a5b6c","when":"afterTurn"}"#, keyed: true) {
        let waiting = try await $0.move("s1", MoveRequest(computer: "9c1e7b3d4f2a5b6c", when: .afterTurn), confirm: "v1.1.c.AAAA")
        #expect(waiting.state == .waiting)
    },
    MoveCall(name: "waiting", reply: { try Fixtures.data("MoveList.waiting") }, method: "GET", path: "/v1/moves") {
        let list = try await $0.moves()
        #expect(list.moves.map(\.state) == [.waiting])
    },
    MoveCall(name: "cancel", status: 204, reply: { Data() }, method: "DELETE", path: "/v1/moves/mv-9b2e4c1a7f3d", keyed: true) {
        try await $0.cancelMove("mv-9b2e4c1a7f3d")
    },
]

@Test(arguments: moveCalls)
private func aMoveRouteIsCalledAsTheProtocolSays(_ row: MoveCall) async throws {
    let mac = FakeMac()
    let reply = try row.reply()
    mac.respond { _ in .init(status: row.status, body: reply) }
    try await row.call(RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac, cache: ResponseCache()))
    let sent = try #require(mac.calls.last)
    #expect(sent.httpMethod == row.method && sent.url?.path == row.path)
    #expect(sent.value(forHTTPHeaderField: ConfirmSignature.header) == row.confirm)
    #expect((sent.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty == false) == row.keyed)
    func canonical(_ data: Data?) throws -> String? {
        guard let data else { return nil }
        let object = try JSONSerialization.jsonObject(with: data)
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    #expect(try canonical(sent.httpBody) == canonical(row.body.map { Data($0.utf8) }))
}

@Test func aRefusedPreviewCarriesTheSentenceToShow() async throws {
    let mac = FakeMac()
    let refusal = #"{"error":{"code":"move_refused","message":"Mac mini is signed out of Claude Code.","retryable":false}}"#
    mac.respond { _ in .init(status: 409, body: Data(refusal.utf8)) }
    let client = RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac)
    do {
        _ = try await client.movePreview("s1", MoveRequest(computer: "9c1e7b3d4f2a5b6c"))
        Issue.record("a refusal decoded as a preview")
    } catch let failure as RemoteFailure {
        #expect(failure.status == 409 && failure.error.code == .moveRefused && failure.error.message == "Mac mini is signed out of Claude Code.")
    }
}
