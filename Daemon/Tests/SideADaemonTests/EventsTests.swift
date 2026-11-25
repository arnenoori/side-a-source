import Foundation
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

private func hello(epoch: String? = nil, lastSeq: Int? = nil) -> String {
    let data = (try? JSONEncoder().encode(ClientMessage.hello(epoch: epoch, lastSeq: lastSeq, capabilities: [.events]))) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private func connect(_ daemon: SideADaemon, token: String) async throws -> TestConnection {
    let connection = try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash)
    let answer = try await connection.upgrade("/v1/ws/events", token: token)
    #expect(answer.status == 101)
    return connection
}

@Test func theEventsSocketSendsAWelcomeAndASnapshotToANewPhone() async throws {
    try await withDaemon { daemon, _ in
        let paired = try await FakePhone().pair(with: daemon, pin: daemon.identity.spkiHash)
        let socket = try await connect(daemon, token: paired.token)
        try await socket.send(text: hello())
        let welcome = try await socket.event()
        #expect(welcome["type"] as? String == "welcome")
        let data = try #require(welcome["data"] as? [String: Any])
        #expect(data["replay"] as? Bool == false && data["epoch"] as? String == daemon.epoch)
        let snapshot = try await socket.event()
        #expect(snapshot["type"] as? String == "snapshot")
        let body = try #require(snapshot["data"] as? [String: Any])
        #expect(body["epoch"] as? String == daemon.epoch && (body["sessions"] as? [Any])?.isEmpty == true)
        let greeting = try #require(data["hello"] as? [String: Any])
        #expect((greeting["mac"] as? [String: Any])?["os"] as? String == "linux" && (greeting["mac"] as? [String: Any])?["headless"] as? Bool == true)
        await socket.close()
    }
}

@Test func aReconnectInTheSameEpochReplaysWhatItMissedInsteadOfASnapshot() async throws {
    try await withDaemon { daemon, _ in
        let paired = try await FakePhone().pair(with: daemon, pin: daemon.identity.spkiHash)
        let first = try await connect(daemon, token: paired.token)
        try await first.send(text: hello())
        _ = try await first.event(); _ = try await first.event()
        await first.close()
        await daemon.hub.record(.bye(reason: "test one"))
        await daemon.hub.record(.bye(reason: "test two"))
        let second = try await connect(daemon, token: paired.token)
        try await second.send(text: hello(epoch: daemon.epoch, lastSeq: 0))
        let welcome = try await second.event()
        #expect((welcome["data"] as? [String: Any])?["replay"] as? Bool == true)
        let one = try await second.event(), two = try await second.event()
        #expect(one["seq"] as? Int == 1 && two["seq"] as? Int == 2)
        // A new epoch gets a snapshot instead.
        let third = try await connect(daemon, token: paired.token)
        try await third.send(text: hello(epoch: "another", lastSeq: 2))
        #expect((try await third.event()["data"] as? [String: Any])?["replay"] as? Bool == false)
        await second.close(); await third.close()
    }
}

@Test func liveStateEventsReachEverySocketWithConsecutiveSequenceNumbers() async throws {
    try await withDaemon { daemon, _ in
        let paired = try await FakePhone().pair(with: daemon, pin: daemon.identity.spkiHash)
        let socket = try await connect(daemon, token: paired.token)
        try await socket.send(text: hello())
        _ = try await socket.event(); _ = try await socket.event()
        await daemon.hub.record(.finishedResolve(sessionID: "s1", reason: "replied"))
        await daemon.hub.record(.finishedResolve(sessionID: "s2", reason: "replied"))
        let a = try await socket.event(), b = try await socket.event()
        #expect(a["type"] as? String == "finished.resolve" && a["seq"] as? Int == 1 && b["seq"] as? Int == 2)
        await socket.close()
    }
}

@Test func aSocketNeedsAPairedTokenAndSaysHelloInFiveSeconds() async throws {
    try await withDaemon { daemon, _ in
        let stranger = try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash)
        let refused = try await stranger.upgrade("/v1/ws/events", token: DeviceToken.make())
        #expect(refused.status == 401)
        await stranger.close()
        let paired = try await FakePhone().pair(with: daemon, pin: daemon.identity.spkiHash)
        let silent = try await connect(daemon, token: paired.token)
        #expect(await silent.closeCode() == 4400)
        await silent.close()
    }
}

@Test func revokingAPhoneClosesItsSocketWith4401() async throws {
    try await withDaemon { daemon, _ in
        let paired = try await FakePhone().pair(with: daemon, pin: daemon.identity.spkiHash)
        let socket = try await connect(daemon, token: paired.token)
        try await socket.send(text: hello())
        _ = try await socket.event(); _ = try await socket.event()
        await daemon.revoke(paired.deviceID)
        #expect(await socket.closeCode() == 4401)
        await socket.close()
    }
}

@Test func aFifthSocketFromOneDeviceIsRefused() async throws {
    try await withDaemon { daemon, _ in
        let paired = try await FakePhone().pair(with: daemon, pin: daemon.identity.spkiHash)
        var sockets: [TestConnection] = []
        for _ in 0..<EventHub.socketsPerDevice {
            let socket = try await connect(daemon, token: paired.token)
            try await socket.send(text: hello())
            _ = try await socket.event()
            sockets.append(socket)
        }
        let extra = try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash)
        let answer = try await extra.upgrade("/v1/ws/events", token: paired.token)
        #expect(answer.status == 429)
        for socket in sockets + [extra] { await socket.close() }
    }
}

@Test func aWriteWithoutAnIdempotencyKeyIsRefusedAndARepeatReplays() async throws {
    try await withDaemon { daemon, _ in
        let paired = try await FakePhone().pair(with: daemon, pin: daemon.identity.spkiHash)
        let connection = try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash)
        let bearer = ["Authorization": "Bearer \(paired.token)"]
        let none = try await connection.request("POST", "/v1/devices/push", headers: bearer, body: Data("{}".utf8))
        #expect(none.status == 400 && none.errorCode == "missing_idempotency_key")
        let registration = try JSONEncoder().encode(PushRegistration(apnsToken: "ab", apnsEnvironment: .sandbox, prefs: NotificationPrefs()))
        let keyed = bearer.merging(["Idempotency-Key": "push-1"]) { $1 }
        #expect(try await connection.request("POST", "/v1/devices/push", headers: keyed, body: registration).status == 204)
        let again = try await connection.request("POST", "/v1/devices/push", headers: keyed, body: registration)
        #expect(again.status == 204 && again.header("idempotent-replay") == "true")
        let other = try await connection.request("POST", "/v1/devices/push", headers: keyed, body: Data(#"{"apnsToken":"cd"}"#.utf8))
        #expect(other.status == 422 && other.errorCode == "idempotency_mismatch")
        await connection.close()
    }
}
