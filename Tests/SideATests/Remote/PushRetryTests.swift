import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

private final class Relay: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int
    private var failure: Error
    private(set) var puts = 0
    init(failing: Int, with failure: Error = RelayClient.Failure.unreachable) { self.failures = failing; self.failure = failure }
    func put() throws -> Bool {
        try lock.withLock {
            puts += 1
            if failures > 0 { failures -= 1; throw failure }
            return true
        }
    }
    var count: Int { lock.withLock { puts } }
}

@MainActor private func pairedRemote(relay: Relay) throws -> RemoteController {
    let remote = RemoteController(store: AccountStore(demo: true), keychain: .inMemory(), addresses: ["127.0.0.1"], port: 1_025)
    try remote.devices.add(RemoteDevice(id: "d1", name: "iPhone", model: "", system: "", app: "1", build: 1, hash: Data(), secretHash: "", created: 0), replacing: nil)
    remote.push.retryAfter = .milliseconds(20)
    remote.push.putDevice = { _, _ in try relay.put() }
    return remote
}

private let registration = PushRegistration(apnsToken: "aa", bundleID: "b", apnsEnvironment: .sandbox)

@MainActor @Test func aRegistrationTheRelayMissedIsTriedAgainUntilItTakes() async throws {
    let relay = Relay(failing: 2)
    let remote = try pairedRemote(relay: relay)
    #expect(await remote.push.register("d1", registration) == false)
    #expect(remote.push.unacknowledged == ["d1"] && remote.push.relayState == "unreachable")
    try await until(remote.push.unacknowledged.isEmpty)
    #expect(relay.count == 3 && remote.push.relayState == "ok")
}

@MainActor @Test func aRelayThatRefusesAPhoneIsNotAskedAgain() async throws {
    let relay = Relay(failing: 5, with: RelayClient.Failure(status: 409, code: "conflict", message: ""))
    let remote = try pairedRemote(relay: relay)
    #expect(await remote.push.register("d1", registration) == false)
    // swiftlint:disable:next sleep_as_sync_in_tests -- proving no retry comes: three retry intervals (20 ms each) pass with none
    try await Task.sleep(for: .milliseconds(60))
    #expect(relay.count == 1 && remote.push.unacknowledged.isEmpty)
}

@MainActor @Test func theRelayComingBackRetriesAtOnceAndTurningRemoteOffStopsTheRetries() async throws {
    let relay = Relay(failing: 1)
    let remote = try pairedRemote(relay: relay)
    remote.push.retryAfter = .seconds(3_600)
    _ = await remote.push.register("d1", registration)
    #expect(remote.push.unacknowledged == ["d1"])
    remote.push.relayMayBeBack()
    try await until(remote.push.unacknowledged.isEmpty)
    #expect(relay.count == 2)

    let second = Relay(failing: 9)
    let off = try pairedRemote(relay: second)
    _ = await off.push.register("d1", registration)
    off.push.stopScheduling()
    // swiftlint:disable:next sleep_as_sync_in_tests -- proving no retry comes after scheduling stops: three retry intervals pass with none
    try await Task.sleep(for: .milliseconds(60))
    #expect(second.count == 1 && off.push.unacknowledged.isEmpty)
}

@MainActor @Test func theBackoffStartsOverOnceEveryRegistrationHasTaken() async throws {
    let relay = Relay(failing: 3)
    let remote = try pairedRemote(relay: relay)
    _ = await remote.push.register("d1", registration)
    try await until(remote.push.unacknowledged.isEmpty)
    #expect(relay.count == 4 && remote.push.attempts == 0)
}

@MainActor private func until(_ what: @autoclosure () -> Bool) async throws {
    for _ in 0..<250 where !what() { try await Task.sleep(for: .milliseconds(20)) }
    #expect(what())
}

/// What the phone asked about its Mac going quiet reaches the relay with its registration, and a phone that can't say
/// leaves the relay as it was.
@MainActor @Test func aPhonesWishToHearWhenItsMacGoesQuietReachesTheRelay() async throws {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var devices: [RelayClient.Device] = []
        func add(_ device: RelayClient.Device) { lock.withLock { devices.append(device) } }
        var all: [RelayClient.Device] { lock.withLock { devices } }
    }
    let sent = Sent()
    let remote = try pairedRemote(relay: Relay(failing: 0))
    remote.push.putDevice = { _, device in sent.add(device); return true }
    _ = await remote.push.register("d1", PushRegistration(apnsToken: "aa", bundleID: "b", apnsEnvironment: .sandbox, prefs: NotificationPrefs(macQuiet: true)))
    _ = await remote.push.register("d1", PushRegistration(apnsToken: "aa", bundleID: "b", apnsEnvironment: .sandbox, prefs: NotificationPrefs(macQuiet: false)))
    _ = await remote.push.register("d1", registration)
    #expect(sent.all.map(\.notifyQuiet) == [true, false, nil])
    let body = try JSONEncoder().encode(sent.all[2])
    #expect(try JSONSerialization.jsonObject(with: body) is [String: Any] && String(decoding: body, as: UTF8.self).contains("notifyQuiet") == false)
}
