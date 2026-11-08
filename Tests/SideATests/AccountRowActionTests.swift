import Foundation
@testable import SideA
import SideACore
import Testing

@MainActor @Test func eachAccountRowOffersOneAction() {
    let store = AccountStore(demo: true, root: FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))"))
    let accounts = store.config.accounts
    let (active, other, activeCodex, otherCodex) = (accounts[0], accounts[1], accounts[3], accounts[4])
    #expect(store.rowAction(for: active) == .inUse)
    #expect(store.rowAction(for: activeCodex) == .inUse)
    #expect(store.rowAction(for: other) == .use)
    #expect(store.rowAction(for: otherCodex) == .none)

    store.health[other.id] = .signIn()
    #expect(store.rowAction(for: other) == .signIn)
    store.health[active.id] = .signIn()
    #expect(store.rowAction(for: active) == .inUse)
    var unready = otherCodex
    unready.ready = false
    #expect(store.rowAction(for: unready) == .signIn)

    store.health[other.id] = .idle
    #expect(store.rowAction(for: other) == .use)
    store.usage[other.id] = nil
    #expect(store.rowAction(for: other) == .renew)
    store.health[otherCodex.id] = .idle
    store.usage[otherCodex.id] = nil
    #expect(store.rowAction(for: otherCodex) == .none)

    store.signingIn.insert(other.id)
    #expect(store.rowAction(for: other) == .busy)
}
