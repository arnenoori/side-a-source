import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

@MainActor private func pairedRemote(_ keychain: RemoteKeychain) throws -> RemoteController {
    let remote = RemoteController(store: AccountStore(demo: true), keychain: keychain, addresses: ["127.0.0.1"], port: 1_025)
    try remote.devices.add(RemoteDevice(id: "dz1", name: "iPhone", model: "", system: "", app: "1", build: 1, hash: Data(), secretHash: "", created: 0), replacing: nil)
    remote.push.putDevice = { _, _ in true }
    return remote
}

private func logged(_ fragment: String) -> Bool { RemoteLog.shared.recent.contains { $0.contains(fragment) } }

@MainActor @Test func aDeviceRecordTheKeychainWontTakeIsLogged() async throws {
    let keychain = RemoteKeychain.inMemory()
    let remote = try pairedRemote(keychain)
    keychain.failWrites(true)

    _ = await remote.push.register("dz1", PushRegistration(apnsToken: "aa", bundleID: "b", apnsEnvironment: .sandbox))
    #expect(logged("couldn't save device dz1's push registration"))

    remote.noteCapabilities("dz1", [.rotation])
    #expect(logged("couldn't save device dz1's capabilities"))

    remote.devices.seen("dz1")
    remote.devices.flush()
    #expect(logged("couldn't save the paired devices"))
    #expect(remote.devices.devices.first?.lastSeen != nil)
}
