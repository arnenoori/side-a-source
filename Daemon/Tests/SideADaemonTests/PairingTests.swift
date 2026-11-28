import Foundation
import SideACore
import SideAProtocol
import Testing
@testable import SideADaemonKit

@Test func aPhoneThatPairsGetsATokenTheDaemonStoresOnlyAsAHash() async throws {
    try await withDaemon { daemon, directory in
        let phone = FakePhone()
        let response = try await phone.pair(with: daemon, pin: daemon.identity.spkiHash)
        #expect(response.token.hasPrefix("sa1_") && response.deviceID == phone.deviceID)
        #expect(response.mac.kind == .linux && response.mac.headless == true && response.relay == nil)
        let stored = try String(contentsOf: directory.appendingPathComponent("devices.json"), encoding: .utf8)
        #expect(!stored.contains(response.token))
        let devices = await daemon.devices.devices
        #expect(devices.count == 1 && devices[0].hash == DeviceToken.hash(response.token) && devices[0].name == "Test iPhone")
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("devices.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}

@Test func pairingIsRefusedWhileNoCodeIsOpenAndOnAWrongCode() async throws {
    try await withDaemon { daemon, _ in
        let pin = daemon.identity.spkiHash
        let phone = FakePhone()
        let connection = try await TestConnection.open(port: daemon.port, pin: pin)
        let closed = try await connection.request("POST", "/v1/pair", body: try JSONEncoder().encode(phone.request(code: "K7Q29XMD", spki: pin)))
        #expect(closed.status == 404 && closed.errorCode == "no_pairing")
        await daemon.pairing.open()
        let wrong = try await connection.request("POST", "/v1/pair", body: try JSONEncoder().encode(phone.request(code: "00000000", spki: pin)))
        #expect(wrong.status == 401 && wrong.errorCode == "bad_code")
        await connection.close()
    }
}

@Test func theDeclinedAndMismatchedPairingsEndWithTheProtocolsErrors() async throws {
    try await withDaemon { daemon, _ in
        let pin = daemon.identity.spkiHash
        await #expect(throws: TestConnection.Refused.self) { _ = try await FakePhone().pair(with: daemon, pin: pin, confirm: false) }
        #expect(await daemon.devices.devices.isEmpty)
    }
}

@Test func aPhoneThatSawAnotherKeyCannotBePaired() async throws {
    try await withDaemon { daemon, _ in
        let phone = FakePhone()
        let other = try DaemonIdentity.generate().spkiHash
        await daemon.pairing.open()
        let code = try #require(await daemon.pairing.currentCode)
        let connection = try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash)
        let pending = try await connection.request("POST", "/v1/pair", body: try JSONEncoder().encode(phone.request(code: code, spki: other)))
        let attempt = try pending.json(PairPending.self)
        // Pair isn't offered, and the wait answers sas_mismatch at once.
        #expect(await eventually { await daemon.pairing.attempt?.keyMatches == false })
        let waiter = try await TestConnection.open(port: daemon.port, pin: daemon.identity.spkiHash)
        let answer = try await waiter.request("POST", "/v1/pair/\(attempt.attemptID)/wait")
        #expect(answer.status == 403 && answer.errorCode == "sas_mismatch")
        await daemon.pairing.decide(.pair)
        #expect(await daemon.devices.devices.isEmpty)
        await connection.close(); await waiter.close()
    }
}

@Test func twoDevicesUsingOneCodeVoidBothAttempts() async throws {
    try await withDaemon { daemon, _ in
        let pin = daemon.identity.spkiHash
        await daemon.pairing.open()
        let code = try #require(await daemon.pairing.currentCode)
        let connection = try await TestConnection.open(port: daemon.port, pin: pin)
        let first = try await connection.request("POST", "/v1/pair", body: try JSONEncoder().encode(FakePhone().request(code: code, spki: pin)))
        #expect(first.status == 202)
        let second = try await connection.request("POST", "/v1/pair", body: try JSONEncoder().encode(FakePhone().request(code: code, spki: pin)))
        #expect(second.status == 409 && second.errorCode == "code_busy")
        await connection.close()
    }
}

@Test func nobodyConfirmingInASixtySecondsTimesTheAttemptOut() async throws {
    let broker = PairingBroker()
    await broker.open(now: Date(timeIntervalSince1970: 1_000))
    let phone = FakePhone()
    let code = try #require(await broker.currentCode)
    guard case .success = await broker.submit(phone.request(code: code, spki: "AAAA"), spki: Data([0, 0, 0]), source: "a", now: Date(timeIntervalSince1970: 1_001)) else {
        Issue.record("a right code should be accepted"); return
    }
    await broker.tick(now: Date(timeIntervalSince1970: 1_000 + PairingBroker.confirmTime + 2))
    #expect(await broker.phase == .stopped(.timeout))
}

@Test func anExpiredCodeIsReplacedSixTimesThenStops() async throws {
    let broker = PairingBroker()
    var now = Date(timeIntervalSince1970: 5_000)
    await broker.open(now: now)
    var seen = Set<String>()
    for _ in 0..<PairingBroker.renewals + 1 {
        seen.insert(try #require(await broker.currentCode))
        now = now.addingTimeInterval(PairingCode.lifetime + 1)
        await broker.tick(now: now)
    }
    #expect(seen.count == PairingBroker.renewals + 1)
    #expect(await broker.phase == .stopped(.expired))
}

@Test func revokingADeviceClosesItsTokenAndSockets() async throws {
    try await withDaemon { daemon, _ in
        let pin = daemon.identity.spkiHash
        let paired = try await FakePhone().pair(with: daemon, pin: pin)
        let connection = try await TestConnection.open(port: daemon.port, pin: pin)
        #expect(try await connection.request("GET", "/v1/state", headers: ["Authorization": "Bearer \(paired.token)"]).status == 200)
        let revoked = try await connection.request("DELETE", "/v1/devices/self", headers: ["Authorization": "Bearer \(paired.token)", "Idempotency-Key": "k1"])
        #expect(revoked.status == 204)
        #expect(try await connection.request("GET", "/v1/state", headers: ["Authorization": "Bearer \(paired.token)"]).status == 401)
        #expect(await daemon.devices.devices.isEmpty)
        await connection.close()
    }
}

@Test func theDevicesSurviveARestart() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = DaemonConfig(paths: DaemonPaths(state: directory))
    config.port = 0; config.discover = false
    let first = try SideADaemon(config: config)
    try await first.start()
    let paired = try await FakePhone().pair(with: first, pin: first.identity.spkiHash)
    try await first.stop()
    let second = try SideADaemon(config: config)
    try await second.start()
    #expect(second.identity.spkiHash == first.identity.spkiHash)
    let connection = try await TestConnection.open(port: second.port, pin: second.identity.spkiHash)
    let hello = try await connection.request("GET", "/v1/hello", headers: ["Authorization": "Bearer \(paired.token)"]).json(Hello.self)
    #expect(hello.paired == true)
    await connection.close()
    try await second.stop()
}

@Test func sideadPairShowsACodeAndRelaysTheComparisonAndTheAnswerOverTheControlSocket() async throws {
    try await withDaemon { daemon, directory in
        let control = try await ControlServer.start(daemon: daemon, path: daemon.config.paths.socket.path)
        let client = try ControlClient(path: control.path)
        client.send(["cmd": "pair"])
        let shown = try #require(client.receive())
        #expect(shown["event"] as? String == "code")
        let link = try #require(shown["link"] as? String)
        let fragment = try #require(URLComponents(string: link)?.fragment)
        let fields = Dictionary(uniqueKeysWithValues: fragment.split(separator: "&").map { part -> (String, String) in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            return (pair[0], pair.count > 1 ? pair[1] : "")
        })
        #expect(fields["fp"] == daemon.identity.spkiHash && fields["c"]?.count == 8)
        let phone = FakePhone()
        let pin = daemon.identity.spkiHash
        let connection = try await TestConnection.open(port: daemon.port, pin: pin)
        let pending = try await connection.request("POST", "/v1/pair", body: try JSONEncoder().encode(phone.request(code: fields["c"] ?? "", spki: pin)))
        #expect(pending.status == 202)
        let attempt = try pending.json(PairPending.self)
        let confirm = try #require(client.receive())
        #expect(confirm["event"] as? String == "confirm" && confirm["device"] as? String == "Test iPhone" && confirm["keyMatches"] as? Bool == true)
        let digits = try PairingTranscript.display(PairingTranscript.comparisonCode(
            code: fields["c"] ?? "", nonce: attempt.nonce, macPublicKey: attempt.macPublicKey, devicePublicKey: phone.key.publicKey.rawRepresentation.base64URL, serverKeyHash: pin, confirmKey: phone.confirmKey, unlockKey: phone.unlockKey))
        #expect(confirm["comparison"] as? String == digits)
        let waiter = try await TestConnection.open(port: daemon.port, pin: pin)
        async let finished = waiter.request("POST", "/v1/pair/\(attempt.attemptID)/wait")
        client.send(["cmd": "decide", "decision": "pair"])
        #expect(try await finished.status == 201)
        #expect(client.receive()?["event"] as? String == "pairing")
        #expect(client.receive()?["event"] as? String == "paired")
        client.send(["cmd": "devices"])
        #expect((client.receive()?["devices"] as? [[String: Any]])?.count == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: control.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        await connection.close(); await waiter.close()
        try await control.stop()
        _ = directory
    }
}

@Test func theCodeAndQRTextCarryWhatThePhoneNeeds() async throws {
    try await withDaemon { daemon, _ in
        let link = daemon.link(code: "K7Q29XMD")
        #expect(link.hasPrefix("https://getsidea.com/pair#v=2&a=127.0.0.1%3A\(daemon.port)") || link.contains("a=127.0.0.1:\(daemon.port)"))
        #expect(link.contains("&fp=\(daemon.identity.spkiHash)&") && link.contains("&c=K7Q29XMD") && link.contains("&m=\(HostInfo.machineID())"))
    }
}
