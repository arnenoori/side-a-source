import Foundation
@testable import SideA
import SideACore
import Testing

/// A removed account once stayed in `usage` and was written back to the usage cache on every save.
@MainActor @Test func removingAnAccountForgetsWhatWasKeptAboutIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))")
    let store = AccountStore(demo: true, root: root)
    store.testBridge = { args in
        if args.first == "forget" { return Data() }
        throw BridgeFailure(stderr: "Side A[signin]: Sign in to Studio again.")
    }
    let studio = store.config.accounts[1], weekend = store.config.accounts[2]
    #expect(!store.isActive(studio))
    await store.refreshUsage(studio.id)
    store.loginEnds[studio.id] = Date().timeIntervalSince1970 + 86_400
    store.poolBlocked[studio.id] = Date().timeIntervalSince1970 + 600
    #expect(store.health[studio.id] == .signIn() && store.signInWarned.contains(studio.id))

    store.remove(studio.id)
    #expect(!store.config.accounts.contains { $0.id == studio.id })
    #expect(store.usage[studio.id] == nil && store.health[studio.id] == nil && store.readAt[studio.id] == nil)
    #expect(store.loginEnds[studio.id] == nil && store.poolBlocked[studio.id] == nil)
    #expect(!store.signInWarned.contains(studio.id) && store.plannable[studio.id] == nil && store.issueText(studio.id) == nil)
    #expect(store.usage[weekend.id] != nil)

    let cache = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("runtime/usage-cache.json"))) as? [String: Any]
    let cached = cache?["usage"] as? [String: Any]
    #expect(cached?[studio.id] == nil && cached?[weekend.id] != nil)
    #expect((cache?["issues"] as? [String: Any])?[studio.id] == nil)
}
