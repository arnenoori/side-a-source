import Foundation
@testable import SideA
import Testing

@Test func anotherIdentityInTheKeychainIsNeverTakenOrDeleted() throws {
    let keychain = try TestKeychain()
    let other = RemoteKeychain(service: "someone.elses", keychain: keychain.keychain)
    let theirs = try #require(try other.identity())

    #expect(try keychain.store.identity(create: false) == nil)
    let ours = try #require(try keychain.store.identity())
    #expect(ours.spkiHash != theirs.spkiHash)
    #expect(try keychain.store.identity(create: false)?.spkiHash == ours.spkiHash)
    #expect(RemoteKeychain.signs(ours))

    keychain.store.deleteIdentity()
    #expect(try keychain.store.identity(create: false) == nil)
    #expect(try other.identity(create: false)?.spkiHash == theirs.spkiHash)
    #expect(RemoteKeychain.signs(try #require(try other.identity(create: false))))

    let replaced = try #require(try keychain.store.identity())
    #expect(replaced.spkiHash != ours.spkiHash)
    #expect(try other.identity(create: false)?.spkiHash == theirs.spkiHash)
}
