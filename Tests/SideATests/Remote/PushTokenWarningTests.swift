import Foundation
@testable import SideA
import SideACore
import SideAProtocol
import Testing

@MainActor @Test func onlyANotificationAddressThatMovesIsWorthSaying() {
    let now = Date()
    #expect(!RemotePush.warns(from: nil, to: "aa", warned: nil, now: now), "the first report")
    #expect(!RemotePush.warns(from: "aa", to: "aa", warned: nil, now: now), "the same token, as at every launch")
    #expect(RemotePush.warns(from: "aa", to: "bb", warned: nil, now: now))
    #expect(!RemotePush.warns(from: "bb", to: "aa", warned: now, now: now + RemotePush.tokenWarnEvery - 1), "two phones flipping it")
    #expect(RemotePush.warns(from: "bb", to: "aa", warned: now, now: now + RemotePush.tokenWarnEvery))
}

@MainActor @Test func aRegisteredPhonesNewTokenIsNotedOnceAndStillRegistered() async throws {
    let remote = RemoteController(store: AccountStore(demo: true), keychain: .inMemory(), addresses: ["127.0.0.1"], port: 1_025)
    try remote.devices.add(RemoteDevice(id: "d1", name: "iPhone", model: "", system: "", app: "1", build: 1, hash: Data(), secretHash: "", created: 0), replacing: nil)
    func report(_ token: String) async {
        _ = await remote.push.register("d1", PushRegistration(apnsToken: token, bundleID: "b", apnsEnvironment: .sandbox))
    }
    await report("aa")
    #expect(remote.push.tokenWarned.isEmpty)
    await report("aa")
    #expect(remote.push.tokenWarned.isEmpty)
    await report("bb")
    #expect(remote.push.tokenWarned["d1"] != nil)
    #expect(remote.devices.devices.first?.push?.apnsToken == "bb", "background refresh still takes a new token")
}
