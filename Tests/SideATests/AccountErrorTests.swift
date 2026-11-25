import Foundation
@testable import SideA
import SideACore
import Testing

@MainActor private func makeStore(loggedIn: @escaping @MainActor () -> Bool) -> (AccountStore, String, String) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))")
    let store = AccountStore(demo: true, root: root)
    store.checksLogins = true
    store.config.accounts = [Account(name: "A", email: "a@example.com", allowAuto: true), Account(name: "B", email: "b@example.com", allowAuto: true)]
    store.activeIDs = [:]
    let (a, b) = (store.config.accounts[0].id, store.config.accounts[1].id)
    store.testBridge = { args in
        guard args.first == "status" else { throw BridgeFailure(message: "not in this test") }
        let email = args[1] == a ? "a@example.com" : "b@example.com"
        return Data(#"{"loggedIn":\#(loggedIn()),"email":"\#(email)","authMethod":"oauth"}"#.utf8)
    }
    return (store, a, b)
}

@MainActor @Test func anAccountsErrorGoesWhenItsLoginCheckLaterSucceeds() async {
    var ok = false
    let (store, a, _) = makeStore { ok }
    #expect(await store.verify(a) == false)
    #expect(store.error == "Finish signing in, then return to Side A.")
    ok = true
    #expect(await store.verify(a))
    #expect(store.error == nil)
}

@MainActor @Test func anotherAccountsSuccessLeavesAnErrorAlone() async {
    var ok = false
    let (store, a, b) = makeStore { ok }
    #expect(await store.verify(a) == false)
    ok = true
    #expect(await store.verify(b))
    #expect(store.error == "Finish signing in, then return to Side A.")
}

@MainActor @Test func anErrorWithNoSubjectOutlivesEverySuccess() {
    let (store, a, _) = makeStore { true }
    store.error = "The library couldn't be read."
    store.resolve(.account(a))
    store.resolve(.pool)
    #expect(store.error == "The library couldn't be read.")
    store.report("Pool mode couldn't start: busy", for: .pool)
    store.resolve(.account(a))
    #expect(store.error != nil)
    store.resolve(.pool)
    #expect(store.error == nil)
}

@MainActor @Test func aNewLoginTakesTheSignInAgainMarkOffTheAccount() {
    let (store, a, _) = makeStore { true }
    store.usage[a] = AccountUsage(windows: [], stale: true)
    store.health[a] = .signIn(replacedBy: nil)
    store.forgetOldLoginHealth(a)
    #expect(store.usage[a]?.stale == false)
    #expect(store.health[a] == nil)
}
