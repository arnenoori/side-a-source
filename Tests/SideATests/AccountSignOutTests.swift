import Foundation
@testable import SideA
import SideACore
import Testing

@MainActor private final class Calls { var argv: [[String]] = [] }

@MainActor private func demoStore(_ calls: Calls, failing: Set<String>) -> AccountStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))")
    let store = AccountStore(demo: true, root: root)
    store.testBridge = { args in
        calls.argv.append(args)
        if let command = args.first, failing.contains(command) { throw BridgeFailure(stderr: "Side A: the helper didn't finish.") }
        return Data()
    }
    return store
}

@MainActor @Test func signingOutIsOnlyReportedOnceTheBridgeHasDoneIt() async throws {
    let calls = Calls()
    let store = demoStore(calls, failing: [])
    let studio = store.config.accounts[1]
    #expect(studio.ready && !store.isActive(studio))
    await store.signOut(studio.id)
    #expect(calls.argv == [["logout", studio.id]])
    #expect(store.config.accounts[1].ready == false && store.error == nil)
}

@MainActor @Test func aSignOutTheBridgeFailedIsntShownAsDone() async throws {
    let calls = Calls()
    let store = demoStore(calls, failing: ["logout"])
    let studio = store.config.accounts[1]
    await store.signOut(studio.id)
    #expect(store.config.accounts[1].ready)
    #expect(store.error == "Couldn't sign out of \(studio.name). Try again.")
}

@MainActor @Test func removingAnAccountWhoseSavedSignInCouldntBeForgottenSaysSo() async throws {
    let calls = Calls()
    let store = demoStore(calls, failing: ["forget"])
    let studio = store.config.accounts[1]
    #expect(studio.provider == .claude)
    store.remove(studio.id)
    #expect(!store.config.accounts.contains { $0.id == studio.id })
    for _ in 0..<250 where store.error == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(store.error == "Removed \(studio.name), but its saved sign-in is still in your Keychain.")
}
