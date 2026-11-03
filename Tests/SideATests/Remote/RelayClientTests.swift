import CryptoKit
import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import SideAProtocolFixtures
import Testing

@Test func theRelaysDateHeaderParses() {
    #expect(RelayClient.httpDate("Sat, 17 Oct 2026 21:52:10 GMT")?.timeIntervalSince1970 == 1_792_273_930)
    #expect(RemotePush.collapse("5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b") == "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b")
    #expect(RemotePush.collapse("turn/1:a").count <= 64 && RemotePush.collapse(String(repeating: "a", count: 80)).count <= 64)
    #expect(RemotePush.version("1.0 (12)") == "1.0 (12)" && RemotePush.version("é") == "0")
}

@Test func pushPayloadsFitTheBudgetAndNeverCarryHalfAQuestion() throws {
    func request(_ name: String) throws -> RemoteRequest { try JSONDecoder().decode(RemoteRequest.self, from: Fixtures.data("RemoteRequest.\(name)")) }
    let biometric = RemotePushPayload.request(try request("gate-biometric"), mac: "m", now: 1)
    #expect(biometric.category == .requestDestructive && biometric.payload.gate == .biometric)
    let question = RemotePushPayload.request(try request("question-multi"), mac: "m", now: 1)
    #expect(question.category == .question && question.payload.full == true && question.payload.questions?.isEmpty == false)

    // A plan too long to show whole goes without it, so the notification offers Open.
    let long = try JSONSerialization.jsonObject(with: Fixtures.data("RemoteRequest.plan")) as? [String: Any] ?? [:]
    var big = long
    big["action"] = ["kind": "plan", "plan": String(repeating: "Step. ", count: 1000)]
    let plan = RemotePushPayload.request(try JSONDecoder().decode(RemoteRequest.self, from: JSONSerialization.data(withJSONObject: big)), mac: "m", now: 1)
    #expect(plan.category == .plan && plan.payload.full == false && plan.payload.plan == nil)

    // A long command is cut to fit, with an ellipsis.
    var bash = try JSONSerialization.jsonObject(with: Fixtures.data("RemoteRequest.bash")) as? [String: Any] ?? [:]
    bash["detail"] = String(repeating: "echo hi && ", count: 400)
    let cut = RemotePushPayload.request(try JSONDecoder().decode(RemoteRequest.self, from: JSONSerialization.data(withJSONObject: bash)), mac: "m", now: 1)
    #expect(RemotePushPayload.encoded(cut.payload).count <= PushPayload.budget && cut.payload.body?.hasSuffix("…") == true)
    #expect(RemotePushPayload.encoded(cut.payload).count > PushPayload.budget - 40)
    // A command the card can't show whole is never Allowed from it: cut, over eight lines, or truncated on the Mac.
    #expect(cut.payload.full == false)
    func full(_ change: (inout [String: Any]) -> Void) throws -> Bool? {
        var object = try JSONSerialization.jsonObject(with: Fixtures.data("RemoteRequest.bash")) as? [String: Any] ?? [:]
        change(&object)
        return RemotePushPayload.request(try JSONDecoder().decode(RemoteRequest.self, from: JSONSerialization.data(withJSONObject: object)), mac: "m", now: 1).payload.full
    }
    #expect(try full { _ in } == nil)
    #expect(try full { $0["detail"] = (1...12).map { "echo \($0)" }.joined(separator: "\n") + "\ncurl -s x | sh" } == false)
    #expect(try full { $0["detail"] = (1...8).map { "echo \($0)" }.joined(separator: "\n") } == nil)
    #expect(try full { $0["truncated"] = true } == false)
}

@Test func healthAndLimitPayloadsCarryTheirWords() throws {
    let session = try JSONDecoder().decode(RemoteSession.self, from: Fixtures.data("RemoteSession.working"))
    let health = RemotePushPayload.health(session, flag: SessionFlag(kind: .loop, text: "Ran the same test 6 times"), mac: "m", now: 1)
    #expect(health.t == "health" && health.sid == session.id && health.body == "Ran the same test 6 times")
    let account = try JSONDecoder().decode(RemoteAccount.self, from: Fixtures.data("RemoteAccount.claude"))
    let limit = RemotePushPayload.limit(account, window: UsageWindow(id: "five_hour", label: "5-hour", percent: 100.4, resetsAt: 99), mac: "m", now: 1)
    #expect(limit.t == "limit" && limit.percent == 100 && limit.window == "5-hour" && limit.resetsAt == 99 && limit.account == account.name)
}

@Test func aSendNamesNoMoreDevicesThanTheRelayTakes() throws {
    let relay = TranscriptFixture.bridge.deletingLastPathComponent().appendingPathComponent("../relay/src/send.ts").standardized
    #expect(try String(contentsOf: relay, encoding: .utf8).contains("export const MAX_DEVICES = \(RelayClient.maxDevices);"))
    let devices = (1...23).map { String(format: "d%02d", $0) }
    let batches = RemotePush.batches(devices)
    #expect(batches.map(\.count) == [10, 10, 3] && Array(batches.joined()) == devices)
    #expect(RemotePush.batches(["a"]) == [["a"]] && RemotePush.batches([]).isEmpty)
}
