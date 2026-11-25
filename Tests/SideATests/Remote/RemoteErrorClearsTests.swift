import Foundation
@testable import SideA
import Testing

@MainActor private func controller(_ keychain: RemoteKeychain = .inMemory()) -> RemoteController {
    RemoteController(store: AccountStore(demo: true), keychain: keychain, addresses: ["127.0.0.1"], port: 1_025)
}

@MainActor @Test func aKeyErrorGoesWhenALaterReadOfTheKeySucceeds() {
    let keychain = RemoteKeychain.inMemory()
    keychain.failWrites(true)
    let remote = controller(keychain)
    #expect(remote.readInstallKey() == nil)
    #expect(remote.error != nil)
    keychain.failWrites(false)
    #expect(remote.readInstallKey() != nil)
    #expect(remote.error == nil)
}

@MainActor @Test func readingTheKeyForAViewNeverChangesTheMessage() {
    let keychain = RemoteKeychain.inMemory()
    keychain.failWrites(true)
    let remote = controller(keychain)
    #expect(remote.installKey == nil)
    #expect(remote.error == nil)
    remote.error = "Paired devices couldn't be read."
    keychain.failWrites(false)
    #expect(remote.installKey != nil)
    #expect(remote.error == "Paired devices couldn't be read.")
}

@MainActor @Test func aSuccessOfSomethingElseLeavesAMessageAlone() {
    let remote = controller()
    remote.report("The relay key couldn't be read.", from: .key)
    remote.resolve(.pairing)
    remote.resolve(.devices)
    #expect(remote.error == "The relay key couldn't be read.")
    remote.resolve(.key)
    #expect(remote.error == nil)
    remote.error = "Paired devices couldn't be read."
    remote.resolve(.devices)
    #expect(remote.error != nil)
}
