import Foundation
@testable import SideA
import SideACore
import Testing

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [[String]] = []
    private var probes = 0
    func add(_ args: [String]) { lock.withLock { list.append(args) } }
    func probe() { lock.withLock { probes += 1 } }
    var all: [[String]] { lock.withLock { list } }
    var probed: Int { lock.withLock { probes } }
}

@MainActor @Test func aRemoteOffHostingOffLaunchTouchesNothing() async throws {
    let store = AccountStore(demo: true)
    let calls = Calls()
    store.hosted = HostedSessions(root: store.root, bridge: { args in
        calls.add(args)
        return Data(#"{"tmux": null}"#.utf8)
    })
    let keychain = RemoteKeychain.inMemory()
    let remote = RemoteController(store: store, keychain: keychain, addresses: ["127.0.0.1"])
    remote.on = false
    remote.probe = { calls.probe(); return TailscaleStatus(state: .notInstalled) }
    store.remote = remote
    store.hostTerminal = false

    remote.start()
    await store.syncHosting()
    remote.refresh()
    // swiftlint:disable:next sleep_as_sync_in_tests -- proving that nothing starts with Remote off
    try await Task.sleep(for: .milliseconds(50))
    #expect(!store.hostingWanted)
    #expect(calls.all.isEmpty, "\(calls.all)")
    #expect(keychain.memoryReads == 0 && !remote.opened)
    #expect(calls.probed == 0)

    store.hostTerminal = true
    await store.syncHosting()
    #expect(calls.all.map { Array($0.prefix(2)) } == [["hosting", "install"]])
    store.hostTerminal = false
    await store.syncHosting()
    #expect(calls.all.count == 1 && !store.hosted.available)
    remote.on = true
    #expect(store.hostingWanted)

    remote.start()
    #expect(remote.opened && keychain.memoryReads > 0)
    let probing = RemoteController(store: AccountStore(demo: true), keychain: .inMemory())
    probing.probe = { calls.probe(); return TailscaleStatus(state: .notInstalled) }
    probing.on = true
    probing.refresh()
    await eventually { calls.probed >= 1 }
    #expect(calls.probed == 1)
}

@MainActor @Test func aTailscaleThatWasntUpIsAskedAgain() async throws {
    let calls = Calls()
    let remote = RemoteController(store: AccountStore(demo: true), keychain: .inMemory())
    remote.reprobeAfter = .milliseconds(30)
    remote.probe = {
        calls.probe()
        return TailscaleStatus(state: calls.probed < 3 ? .stopped : .ready)
    }
    remote.on = true
    remote.refresh()
    await eventually { calls.probed >= 3 }
    #expect(calls.probed == 3)
    // swiftlint:disable:next sleep_as_sync_in_tests -- proving it is left alone once up: three re-probe intervals (30 ms each) pass with no more asks
    try await Task.sleep(for: .milliseconds(90))
    #expect(calls.probed == 3 && remote.tailscale?.state == .ready)
    remote.on = false
}

@MainActor @Test func theSessionsWindowsNewControlsTouchNothingWithRemoteOff() async throws {
    let store = AccountStore(demo: true)
    let calls = Calls()
    store.hosted = HostedSessions(root: store.root, bridge: { args in
        calls.add(args)
        return Data(#"{"tmux": null}"#.utf8)
    })
    let keychain = RemoteKeychain.inMemory()
    let remote = RemoteController(store: store, keychain: keychain, addresses: ["127.0.0.1"])
    remote.on = false
    store.remote = remote
    store.hostTerminal = false
    store.island.installed[.claude] = true
    store.sessions.live = [LiveSession(pid: 931, sessionID: "s-work", name: nil, title: nil, cost: nil, cwd: "/tmp/app", status: "busy",
                                       waitingFor: nil, since: nil, agent: "claude")]

    let target = ComposerTarget("s-work", store: store)
    #expect(target.canReply && target.becomesNote && !target.hosted)
    await store.sessions.loadCommands()
    store.sessions.drafts["s-work"] = "check the logs"
    store.sessions.compose("s-work", how: .now)
    for _ in 0..<50 where store.sessions.outcomes["s-work"] == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(store.sessions.outcomes["s-work"]?.result == .sent(.note))
    _ = SettingsChip.summary(WireBuilders.session(store.sessions.live[0], store: store, finished: []))
    store.island.installed[.codex] = false
    store.island.codexMail = "review"
    await store.readCodexMailTrust()
    #expect(store.island.codexMail == nil)
    #expect(calls.all.isEmpty, "\(calls.all)")
    #expect(!store.hostingWanted && !store.hosted.available && keychain.memoryReads == 0 && !remote.opened)
    #expect(!remote.active && !remote.codex.running)
}

private func phone(_ id: String) -> RemoteDevice {
    RemoteDevice(id: id, name: "iPhone", model: "", system: "", app: "1", build: 1, hash: Data(), secretHash: "", created: 0)
}

@MainActor @Test func eachControllerIsActiveOnItsOwnSwitchAndItsOwnPhones() async throws {
    func controller(on: Bool, phones: [String]) throws -> (AccountStore, RemoteController) {
        let store = AccountStore(demo: true)
        store.testBridge = { _ in Data("{}".utf8) }
        let remote = RemoteController(store: store, keychain: .inMemory(), addresses: ["127.0.0.1"])
        store.remote = remote
        remote.on = on
        for id in phones { try remote.devices.add(phone(id), replacing: nil) }
        remote.revoke("nobody")
        return (store, remote)
    }
    let (storeA, a) = try controller(on: true, phones: ["d1", "d2"])
    let (storeB, b) = try controller(on: true, phones: [])
    let (storeC, c) = try controller(on: false, phones: ["d1"])
    #expect(a.active && !b.active && !c.active)
    #expect(storeA.island.keepsWaiters && !storeB.island.keepsWaiters && !storeC.island.keepsWaiters)

    c.on = true
    #expect(c.active && !b.active)
    b.on = false
    a.revoke("d2")
    #expect(a.active && c.active)
}

@MainActor @Test func removingTheLastPhoneWhileRemoteStaysOnMakesItInactive() async throws {
    let store = AccountStore(demo: true)
    store.testBridge = { _ in Data("{}".utf8) }
    let remote = RemoteController(store: store, keychain: .inMemory(), addresses: ["127.0.0.1"])
    store.remote = remote
    remote.on = true
    try remote.devices.add(phone("d1"), replacing: nil)
    remote.revoke("nobody")
    #expect(remote.active && store.island.keepsWaiters && remote.on)

    remote.revoke("d1")
    #expect(remote.on && !remote.active && !store.island.keepsWaiters)
    try remote.devices.add(phone("d3"), replacing: nil)
    remote.revoke("nobody")
    #expect(remote.active)
}
