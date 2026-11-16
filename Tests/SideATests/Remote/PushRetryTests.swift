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
    try await Task.sleep(for: .milliseconds(150))
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
    try await Task.sleep(for: .milliseconds(150))
    #expect(second.count == 1 && off.push.unacknowledged.isEmpty)
}

@MainActor private func until(_ what: @autoclosure () -> Bool) async throws {
    for _ in 0..<250 where !what() { try await Task.sleep(for: .milliseconds(20)) }
    #expect(what())
}
