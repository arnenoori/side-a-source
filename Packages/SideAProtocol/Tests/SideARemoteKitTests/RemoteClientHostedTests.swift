import Foundation
@testable import SideARemoteKit
import SideAProtocol
import SideAProtocolFixtures
import Testing

private struct SignedCall: Sendable, CustomTestStringConvertible {
    let name: String
    let reply: String?
    let method: String, path: String
    let confirm: String?
    let body: String?
    let call: @Sendable (RemoteClient) async throws -> Void
    var testDescription: String { name }
}

private let signedCalls: [SignedCall] = [
    SignedCall(name: "use account", reply: "AccountList.basic", method: "POST", path: "/v1/accounts/a1/use", confirm: "v1.1.c.AAAA", body: "{}") {
        _ = try await $0.useAccount("a1", confirm: "v1.1.c.AAAA")
    },
    SignedCall(name: "autopilot", reply: "AutopilotState.off", method: "POST", path: "/v1/autopilot", confirm: "v1.1.c.AAAA",
               body: #"{"enabled":false}"#) { _ = try await $0.setAutopilot(AutopilotChange(enabled: false), confirm: "v1.1.c.AAAA") },
    SignedCall(name: "settings", reply: "SettingsResult.next-turn", method: "POST", path: "/v1/sessions/s1/settings", confirm: "v1.1.c.AAAA",
               body: #"{"mode":"bypassPermissions"}"#) { _ = try await $0.settings("s1", SettingsChange(mode: .bypassPermissions), confirm: "v1.1.c.AAAA") },
    SignedCall(name: "continue on phone", reply: "HostedSession.alive", method: "POST", path: "/v1/sessions/s1/continue", confirm: nil, body: nil) {
        _ = try await $0.continueOnPhone("s1")
    },
    SignedCall(name: "trust", reply: "HostedSession.alive", method: "POST", path: "/v1/hosted/sa-app-3f9c/trust", confirm: "v1.1.c.AAAA", body: nil) {
        _ = try await $0.trust(JSONDecoder().decode(HostedSession.self, from: Fixtures.data("HostedSession.alive")), confirm: "v1.1.c.AAAA")
    },
    SignedCall(name: "end hosted", reply: nil, method: "DELETE", path: "/v1/hosted/sa-side-a-3f2c", confirm: nil, body: nil) {
        try await $0.endHosted("sa-side-a-3f2c")
    },
]

@Test(arguments: signedCalls)
fileprivate func aChangeIsKeyedAndSignedAsItsRouteAsks(_ row: SignedCall) async throws {
    let mac = FakeMac()
    let reply = try row.reply.map { try Fixtures.data($0) }
    mac.respond { _ in reply.map { .init(body: $0) } ?? .init(status: 204) }
    try await row.call(RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac, cache: ResponseCache()))
    let request = try #require(mac.calls.last)
    #expect(request.httpMethod == row.method && request.url?.path == row.path)
    #expect(request.value(forHTTPHeaderField: ConfirmSignature.header) == row.confirm)
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty == false)
    func canonical(_ data: Data?) throws -> String? {
        guard let data else { return nil }
        let object = try JSONSerialization.jsonObject(with: data)
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    #expect(try canonical(request.httpBody) == canonical(row.body.map { Data($0.utf8) }))
}

@Test func continueOnPhoneThrowsTheMacsRefusal() async throws {
    let mac = FakeMac()
    let refusal = #"{"error":{"code":"cannot_deliver","message":"It's working. Wait for it to finish.","retryable":false}}"#
    mac.respond { _ in .init(status: 409, body: Data(refusal.utf8)) }
    let client = RemoteClient(endpoint: endpoint, credentials: Keys(token: "sa1_token"), transport: mac)
    await #expect(throws: RemoteFailure.self) { try await client.continueOnPhone("s1") }
    do { _ = try await client.continueOnPhone("s1") } catch let failure as RemoteFailure {
        #expect(failure.status == 409 && failure.error.message == "It's working. Wait for it to finish.")
    }
}
