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
    #expect(!RemoteController.active && !remote.codex.running)
}
