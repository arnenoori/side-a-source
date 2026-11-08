import Foundation
@testable import SideA
import Testing

@MainActor private func store(installed: Bool, calls: @escaping @MainActor ([String]) -> Void = { _ in }) -> AccountStore {
    let store = AccountStore(demo: true, root: FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))"))
    store.testBridge = { args in
        calls(args)
        return Data(#"{"installed":\#(installed)}"#.utf8)
    }
    return store
}

/// Each switch asks the bridge for `<command> on|off` and shows what it says is installed, not what was asked.
@MainActor @Test func eachIntegrationSwitchShowsWhatTheBridgeInstalled() async {
    var asked: [[String]] = []
    let on = store(installed: true) { asked.append($0) }
    on.shellSwitching = false
    await on.setShellSwitching(true)
    await on.setLiveLimits(true)
    await on.setLimitHook(true)
    #expect(on.shellSwitching && on.liveLimits && on.limitHook)
    #expect(asked == [["shell", "on"], ["live", "on"], ["hook", "on"]])

    let refused = store(installed: false)
    refused.limitHook = true
    await refused.setShellSwitching(true)
    await refused.setHostTerminal(true)
    await refused.setLimitHook(false)
    #expect(!refused.shellSwitching && !refused.hostTerminal && !refused.limitHook)
    #expect(refused.error == nil)
}

@MainActor @Test func aSwitchTheBridgeCouldntSetKeepsItsStateAndSaysWhy() async {
    let store = AccountStore(demo: true, root: FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))"))
    store.testBridge = { _ in throw BridgeFailure(message: "Side A: ~/.zshrc isn't writable.") }
    store.shellSwitching = true
    await store.setShellSwitching(false)
    #expect(store.shellSwitching)
    #expect(store.error == "Side A: ~/.zshrc isn't writable.")
    store.error = nil
    store.testBridge = { _ in Data("{}".utf8) }
    await store.setLimitHook(true)
    #expect(!store.limitHook)
    #expect(store.error != nil)
}
