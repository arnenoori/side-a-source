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

/// A launch with Remote off and terminal hosting off: no tmux, no Keychain read, no login shell, no log file.
@MainActor @Test func aRemoteOffHostingOffLaunchTouchesNothing() async throws {
    let store = AccountStore(demo: true)
    let calls = Calls()
    store.hosted = HostedSessions(root: store.root, bridge: { args in
        calls.add(args)
        return Data(#"{"tmux": null}"#.utf8)
    })
    let keychain = RemoteKeychain.inMemory()
    // Fixed addresses make the controller available, as the app in Applications is.
    let remote = RemoteController(store: store, keychain: keychain, addresses: ["127.0.0.1"])
    remote.on = false
    remote.probe = { calls.probe(); return TailscaleStatus(state: .notInstalled) }
    store.remote = remote
    store.hostTerminal = false

    remote.start()
    await store.syncHosting()
    remote.refresh()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!store.hostingWanted)
    #expect(calls.all.isEmpty, "\(calls.all)")
    #expect(keychain.memoryReads == 0 && !remote.opened)
    #expect(calls.probed == 0)

    // Either switch wants hosting: tmux is looked for then, and only then.
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
    // Fixed addresses skip the probe, so this controller has none.
    let probing = RemoteController(store: AccountStore(demo: true), keychain: .inMemory())
    probing.probe = { calls.probe(); return TailscaleStatus(state: .notInstalled) }
    probing.on = true
    probing.refresh()
    for _ in 0..<50 where calls.probed == 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(calls.probed == 1)
}

/// Tailscale not answering at launch, as after an update relaunches the app, isn't believed for good: asked again
/// until it's up, then left alone.
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
    for _ in 0..<100 where calls.probed < 3 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(calls.probed == 3)
    try await Task.sleep(for: .milliseconds(150))
    #expect(calls.probed == 3 && remote.tailscale?.state == .ready)
    remote.on = false
}

/// The Sessions window's composer, row menus and suggestions read state only: with Remote and hosting off, showing
/// them and sending a note start no tmux, read no Keychain and open no log.
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
    // The settings chip reads the phone's row; nothing it shows runs anything.
    _ = SettingsChip.summary(WireBuilders.session(store.sessions.live[0], store: store, finished: []))
    // With the Codex island off, Codex's hook trust is never asked, and nothing is left to ask it again.
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

/// Whether Remote is active is each controller's own: its switch and its phones, read by the island through its store.
@MainActor @Test func eachControllerIsActiveOnItsOwnSwitchAndItsOwnPhones() async throws {
    func controller(on: Bool, phones: [String]) throws -> (AccountStore, RemoteController) {
        let store = AccountStore(demo: true)
        store.testBridge = { _ in Data("{}".utf8) }
        let remote = RemoteController(store: store, keychain: .inMemory(), addresses: ["127.0.0.1"])
        store.remote = remote
        remote.on = on
        for id in phones { try remote.devices.add(phone(id), replacing: nil) }
        // Looks at the device list without changing it, as a revoke of someone who isn't paired does.
        remote.revoke("nobody")
        return (store, remote)
    }
    let (storeA, a) = try controller(on: true, phones: ["d1", "d2"])
    let (storeB, b) = try controller(on: true, phones: [])
    let (storeC, c) = try controller(on: false, phones: ["d1"])
    #expect(a.active && !b.active && !c.active)
    #expect(storeA.island.keepsWaiters && !storeB.island.keepsWaiters && !storeC.island.keepsWaiters)

    // One controller's phones and switch don't reach another.
    c.on = true
    #expect(c.active && !b.active)
    b.on = false
    a.revoke("d2")
    #expect(a.active && c.active)
}

/// Removing the last phone ends what only a phone needed, though the switch stays on.
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
    // A phone paired again makes it active without touching the switch.
    try remote.devices.add(phone("d3"), replacing: nil)
    remote.revoke("nobody")
    #expect(remote.active)
}
