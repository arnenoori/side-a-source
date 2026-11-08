import Foundation
@testable import SideA
import SideACore
import Sparkle
import Testing

private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sa-\(UUID().uuidString.prefix(8))") }

/// Holds a call until the test lets it go.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    var waiting: Int { waiters.count }
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor private func until(_ what: @autoclosure () async -> Bool) async throws {
    for _ in 0..<500 where !(await what()) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await what())
}

private func tailnet(login: String? = "me@example.com") -> TailscaleStatus {
    var status = TailscaleStatus(state: .ready)
    status.addresses = ["127.0.0.1"]
    status.login = login
    return status
}

// MARK: Sign-in

@MainActor @Test func aSignInFinishingDuringAnotherAccountsCheckStillVerifies() async throws {
    let store = AccountStore(demo: true, root: temporaryRoot())
    store.checksLogins = true
    store.config.accounts = [Account(name: "A", email: "a@example.com", allowAuto: true), Account(name: "B", email: "b@example.com", allowAuto: true)]
    store.activeIDs = [:]
    let (a, b) = (store.config.accounts[0].id, store.config.accounts[1].id)
    let slow = Gate()
    store.testBridge = { args in
        switch args.first {
        case "login": return Data()
        case "status":
            if args[1] == b { await slow.wait() }
            let email = args[1] == a ? "a@example.com" : "b@example.com"
            return Data(#"{"loggedIn":true,"email":"\#(email)","authMethod":"oauth"}"#.utf8)
        default: throw BridgeFailure(message: "not in this test")
        }
    }
    let other = Task { await store.verify(b, reportError: false) }
    try await until(await slow.waiting == 1)
    #expect(await store.signIn(a))
    #expect(store.config.accounts[0].ready && !store.config.accounts[1].ready)
    await slow.release()
    #expect(await other.value)
}

@MainActor @Test func twoChecksOfOneAccountShareOneAnswerAndBothCanSayWhy() async throws {
    let store = AccountStore(demo: true, root: temporaryRoot())
    store.checksLogins = true
    store.config.accounts = [Account(name: "A", email: "a@example.com", allowAuto: true)]
    let id = store.config.accounts[0].id
    let slow = Gate()
    var calls = 0
    store.testBridge = { _ in
        calls += 1
        await slow.wait()
        throw BridgeFailure(message: "Finish signing in, then return to Side A.")
    }
    let quiet = Task { await store.verify(id, reportError: false) }
    try await until(await slow.waiting == 1)
    let asked = Task { await store.verify(id) }
    try await Task.sleep(for: .milliseconds(20))
    await slow.release()
    #expect(await quiet.value == false)
    #expect(await asked.value == false)
    #expect(calls == 1 && store.error == "Finish signing in, then return to Side A.")
    #expect(await store.verify(id, reportError: false) == false)
    #expect(calls == 2)
}

// MARK: Login health

private func room(at now: Double) -> [UsageWindow] {
    [UsageWindow(id: "five_hour", label: "5-hour", percent: 10, resetsAt: now + 3600), UsageWindow(id: "seven_day", label: "Weekly", percent: 10, resetsAt: now + 86_400)]
}

/// A session's reading clears `stale` and `failing`, so the source can still move; it must not make the login a target.
@MainActor @Test func aSessionsReadingDoesntMakeASignedOutLoginATarget() throws {
    let store = AccountStore(demo: true, root: temporaryRoot())
    let now = Date().timeIntervalSince1970
    store.config.accounts = [Account(name: "Out", email: "o@example.com", ready: true, allowAuto: true), Account(name: "Fine", email: "f@example.com", ready: true, allowAuto: true)]
    let (out, fine) = (store.config.accounts[0], store.config.accounts[1])
    store.usage = [out.id: AccountUsage(windows: room(at: now), stale: true), fine.id: AccountUsage(windows: room(at: now))]
    store.health[out.id] = .signIn(replacedBy: "Fine")

    #expect(store.takeLive(room(at: now), for: out.id, at: now + 1))
    #expect(store.usage[out.id]?.stale == false)
    #expect(store.health[out.id] == .signIn(replacedBy: "Fine"))
    #expect(Planner.best([out], usage: store.usage, health: store.health, active: nil, full: store.config.moveAt, now: now) == nil)
    #expect(Planner.best([out, fine], usage: store.usage, health: store.health, active: nil, full: store.config.moveAt, now: now) == fine.id)
    #expect(store.poolAccount(.claude, session: nil, excluding: [fine.id]) == nil)
    #expect(store.accountIssue(out, now: now) == AccountIssue(kind: .replaced, replacedBy: "Fine"))
}

@MainActor @Test func aSessionsReadingClearsOnlyWhatItDisproves() {
    let store = AccountStore(demo: true, root: temporaryRoot())
    let now = Date().timeIntervalSince1970
    let id = store.config.accounts[0].id
    store.usage[id] = nil
    for (n, passing) in [LoginHealth.offline, .idle].enumerated() {
        store.health[id] = passing
        #expect(store.takeLive(room(at: now), for: id, at: now + Double(n)))
        #expect(store.health[id] == nil)
    }
    store.health[id] = .verify
    #expect(store.takeLive(room(at: now), for: id, at: now + 5))
    #expect(store.health[id] == .verify && store.accountIssue(store.config.accounts[0], now: now) == AccountIssue(kind: .verifying))
}

@Test func healthKeepsItsSavedWordsAndOnlySignInStopsWork() {
    for state in [LoginHealth.idle, .verify, .offline, .signIn()] { #expect(LoginHealth(saved: state.saved) == state) }
    #expect(LoginHealth(saved: "anything else") == nil)
    #expect([LoginHealth.idle, .verify, .offline].allSatisfy(\.takesWork) && !LoginHealth.signIn(replacedBy: "x").takesWork)
}

// MARK: Pool sharing

@MainActor private func sharing() -> (AccountStore, PoolProxy) {
    let store = AccountStore(demo: true, root: temporaryRoot())
    let pool = PoolProxy(key: String(repeating: "a", count: 64), decisions: store)
    store.poolPreferredPort = 0
    store.poolRun = .running(pool, port: 0)
    store.config.poolShare = true
    return (store, pool)
}

/// Security: the Mac must not listen on Tailscale with the setting off.
@MainActor @Test func turningShareOffWhileTailscaleIsAskedLeavesNothingListening() async throws {
    let (store, pool) = sharing()
    defer { pool.stop() }
    let slow = Gate()
    store.tailscaleStatus = { await slow.wait(); return tailnet() }
    let first = Task { await store.syncPoolShare() }
    try await until(await slow.waiting == 1)
    #expect(store.poolShareState == .connecting)
    store.config.poolShare = false
    await store.syncPoolShare()
    #expect(store.poolShareState == .off)
    await slow.release()
    await first.value
    #expect(!pool.isShared && store.poolShareState == .off && store.poolShareCommand == nil)
}


@MainActor struct PoolShareListening {
    /// On, off and on again during one question: the last word is on, and one listener answers it.
    @Test func theLastShareSettingWins() async throws {
        let (store, pool) = sharing()
        defer { pool.stop() }
        let slow = Gate()
        store.tailscaleStatus = { await slow.wait(); return tailnet() }
        let first = Task { await store.syncPoolShare() }
        try await until(await slow.waiting == 1)
        store.config.poolShare = false
        await store.syncPoolShare()
        store.config.poolShare = true
        await store.syncPoolShare()
        await slow.release()
        await first.value
        #expect(store.poolShareProblem == nil)
        #expect(pool.isShared && store.poolShareCommand != nil)
    }

    @Test func shareRecoversOnceTailscaleIsOn() async {
        let (store, pool) = sharing()
        defer { pool.stop() }
        store.tailscaleStatus = { TailscaleStatus(state: .stopped) }
        await store.syncPoolShare()
        #expect(store.poolShareProblem == "Turn on Tailscale on this Mac to share its pool." && !pool.isShared)
        store.tailscaleStatus = { tailnet() }
        await store.syncPoolShare()
        #expect(store.poolShareProblem == nil)
        #expect(store.poolShareCommand != nil && pool.isShared)
        store.tailscaleStatus = { tailnet(login: "tagged-devices") }
        await store.syncPoolShare()
        #expect(store.poolShareProblem != nil && !pool.isShared)
    }
}

/// The pool went away during the question: its proxy doesn't start sharing.
@MainActor @Test func aPoolStoppedWhileTailscaleIsAskedDoesntShare() async throws {
    let (store, pool) = sharing()
    defer { pool.stop() }
    let slow = Gate()
    store.tailscaleStatus = { await slow.wait(); return tailnet() }
    let first = Task { await store.syncPoolShare() }
    try await until(await slow.waiting == 1)
    store.poolRun = .off
    await slow.release()
    await first.value
    #expect(!pool.isShared)
}

/// A pool with no file serves nobody and used to block every later try.
@MainActor @Test func aPoolFileThatCantBeWrittenLeavesNoPoolAndCanBeRetried() async throws {
    let root = temporaryRoot()
    let runtime = root.appendingPathComponent("runtime")
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        try? FileManager.default.removeItem(at: root)
    }
    try (String(repeating: "b", count: 64) + "\n").write(to: runtime.appendingPathComponent("pool-key"), atomically: true, encoding: .utf8)
    let store = AccountStore(demo: true, root: root)
    store.checksLogins = true
    store.poolPreferredPort = 0
    store.config.pool = true
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: runtime.path)
    await store.syncPool()
    #expect(store.pool == nil && store.poolPort == nil && store.error?.hasPrefix("Pool mode couldn't start") == true)

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
    await store.syncPool()
    #expect(store.pool != nil && FileManager.default.fileExists(atPath: store.poolFile.path))
    store.config.pool = false
    await store.syncPool()
    #expect(store.pool == nil)
}

// MARK: Hosting

@MainActor @Test func stoppingHostingDuringInstallKeepsItStopped() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let slow = Gate()
    let hosted = HostedSessions(root: root, bridge: { _ in
        await slow.wait()
        return Data(#"{"tmux":"/usr/bin/true"}"#.utf8)
    })
    let install = Task { await hosted.install() }
    try await until(await slow.waiting == 1)
    hosted.stop()
    await slow.release()
    await install.value
    #expect(!hosted.available)
}

// MARK: Updates

@Test func anUpdateFailureClearsWhenACheckGoesRight() {
    var failure = UpdateFailure()
    failure.aborted(domain: SUSparkleErrorDomain, code: 2001)
    #expect(failure.code == 2001)
    // A cancel or "install later" says nothing either way.
    failure.aborted(domain: SUSparkleErrorDomain, code: 4007)
    failure.aborted(domain: "elsewhere", code: 1)
    #expect(failure.code == 2001)
    failure.aborted(domain: SUSparkleErrorDomain, code: 1001)
    #expect(failure.code == nil)
    failure.aborted(domain: SUSparkleErrorDomain, code: 2001)
    failure.checked()
    #expect(failure.code == nil)
}

@Test func aWaitingUpdateIsDroppedOnlyWhenTheFeedHasANewerBuild() {
    let feed = Data("""
    <?xml version="1.0" standalone="yes"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
    <item><title>0.5.46</title><sparkle:version>54</sparkle:version><sparkle:shortVersionString>0.5.46</sparkle:shortVersionString>
    <enclosure url="https://example.com/SideA-0.5.46.dmg" length="1" type="application/octet-stream"></enclosure></item>
    </channel></rss><!-- sparkle-signatures: -->
    """.utf8)
    #expect(StagedUpdate.superseded(build: "53", feed: feed))
    #expect(StagedUpdate.superseded(build: "9", feed: feed))
    #expect(!StagedUpdate.superseded(build: "54", feed: feed))
    #expect(!StagedUpdate.superseded(build: "100", feed: feed))
    let attribute = Data(#"<rss xmlns:sparkle="s"><channel><item><enclosure sparkle:version="55" url="u"/></item></channel></rss>"#.utf8)
    #expect(StagedUpdate.superseded(build: "54", feed: attribute))
    #expect(!StagedUpdate.superseded(build: "54", feed: Data("not a feed".utf8)))
}

/// Update Automatically off: taking the install-now block would keep Sparkle's session open, and then no later check
/// reaches the feed, so it's left alone exactly as before.
@MainActor @Test func aDownloadWaitingForQuitLeavesSparkleFreeToCheckAgain() {
    let updates = Updates()
    updates.automaticallyUpdates = false
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: UpdateUserDriver(), delegate: nil)
    var installed = false
    #expect(!updates.updater(updater, willInstallUpdateOnQuit: .empty(), immediateInstallationBlock: { installed = true }))
    #expect(updates.available != nil)
    #expect(updates.staged == nil)
    #expect(updates.hold == .off)
    updates.installIfQuiet()
    #expect(!installed)
}

/// Update Automatically on: the block is kept and used once nobody is at the Mac and nothing is under way.
@MainActor @Test func aDownloadInstallsByItselfOnceTheMacIsQuiet() async throws {
    let updates = Updates()
    updates.automaticallyUpdates = true
    var presence = UserPresence(idle: 5, locked: false)
    var activity = QuietInstall.Activity(pending: 1)
    updates.presence = { presence }
    updates.activity = { activity }
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: UpdateUserDriver(), delegate: nil)
    var installs = 0
    #expect(updates.updater(updater, willInstallUpdateOnQuit: .empty(), immediateInstallationBlock: { installs += 1 }))
    #expect(updates.staged != nil)
    #expect(updates.hold == .someoneHere)
    updates.installIfQuiet()
    presence = UserPresence(idle: 1, locked: true)
    #expect(updates.hold == .waiting(1))
    updates.installIfQuiet()
    try await Task.sleep(for: .milliseconds(50))
    #expect(installs == 0)
    activity = QuietInstall.Activity()
    #expect(updates.hold == nil)
    updates.installIfQuiet()
    try await until(installs == 1)
}

/// Holding the block stalls Sparkle, so canCheck stays false; Update to X still installs at once.
@MainActor @Test func updateToXInstallsAHeldUpdateWhileSparkleIsStalled() async throws {
    let updates = Updates()
    updates.automaticallyUpdates = true
    updates.presence = { UserPresence(idle: 0, locked: false) }
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: UpdateUserDriver(), delegate: nil)
    var installs = 0, onMain = true
    #expect(updates.updater(updater, willInstallUpdateOnQuit: .empty(), immediateInstallationBlock: {
        installs += 1; onMain = onMain && Thread.isMainThread
    }))
    #expect(!updates.canCheck)
    #expect(updates.canUpdate)
    #expect(updates.hold == .someoneHere)
    updates.install()
    try await until(installs == 1)
    #expect(onMain)
}

/// Turned off after the block was taken: nothing installs by itself, but asking still works, and so does checking.
@MainActor @Test func turningUpdatesOffWhileOneWaitsKeepsItInstallableByHand() async throws {
    let updates = Updates()
    updates.automaticallyUpdates = true
    updates.presence = { UserPresence(idle: 0, locked: true) }
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: UpdateUserDriver(), delegate: nil)
    var installs = 0
    #expect(updates.updater(updater, willInstallUpdateOnQuit: .empty(), immediateInstallationBlock: { installs += 1 }))
    updates.automaticallyUpdates = false
    #expect(updates.staged != nil)
    #expect(updates.hold == .off)
    updates.installIfQuiet()
    #expect(updates.checkQuietly())
    var asked: [String] = [], answer = false
    updates.confirmInstall = { asked.append($0); return answer }
    updates.check()
    try await Task.sleep(for: .milliseconds(50))
    #expect(installs == 0)
    #expect(asked == [updates.staged?.version ?? "?"])
    answer = true
    updates.check()
    try await until(installs == 1)
    #expect(asked.count == 2)
}

/// The quiet install, Update to X and Check for Updates… all at once: Sparkle's block runs once.
@MainActor @Test func aHeldUpdateIsInstalledOnlyOnce() async throws {
    let updates = Updates()
    updates.automaticallyUpdates = true
    updates.presence = { UserPresence(idle: 601, locked: false) }
    updates.confirmInstall = { _ in true }
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: UpdateUserDriver(), delegate: nil)
    var installs = 0
    #expect(updates.updater(updater, willInstallUpdateOnQuit: .empty(), immediateInstallationBlock: { installs += 1 }))
    updates.installIfQuiet()
    updates.install()
    updates.check()
    try await until(installs == 1)
    updates.install()
    updates.installIfQuiet()
    updates.check()
    try await Task.sleep(for: .milliseconds(50))
    #expect(installs == 1)
}

@Test func aQuietInstallWaitsForEveryConditionAtOnce() {
    let away = UserPresence(idle: 601, locked: false), quiet = QuietInstall.Activity()
    func hold(automatic: Bool = true, staged: Bool = true, presence: UserPresence = away, activity: QuietInstall.Activity = quiet) -> QuietInstall.Hold? {
        QuietInstall.hold(automatic: automatic, staged: staged, presence: presence, activity: activity)
    }
    #expect(hold() == nil)
    #expect(hold(presence: UserPresence(idle: 5, locked: true)) == nil)
    #expect(hold(presence: UserPresence(idle: 599, locked: false)) == .someoneHere)
    #expect(hold(presence: UserPresence(idle: 0, locked: false)) == .someoneHere)
    #expect(hold(activity: QuietInstall.Activity(pending: 2)) == .waiting(2))
    #expect(hold(activity: QuietInstall.Activity(poolInFlight: 1)) == .pool(1))
    #expect(hold(activity: QuietInstall.Activity(busy: ["a sign-in", "pairing a phone"])) == .busy("a sign-in"))
    #expect(hold(staged: false) == .nothingStaged)
    // Off: nothing installs on its own, whatever else is true.
    #expect(hold(automatic: false) == .off)
    #expect(hold(automatic: false, presence: UserPresence(idle: 0, locked: true)) == .off)
}

@Test func onlyANonCriticalUpdateWithTheSwitchOnIsTakenOver() {
    #expect(QuietInstall.takesOver(automatic: true, critical: false))
    #expect(!QuietInstall.takesOver(automatic: true, critical: true))
    #expect(!QuietInstall.takesOver(automatic: false, critical: false))
    #expect(!QuietInstall.takesOver(automatic: false, critical: true))
}

@Test func updatedToShowsForADayAfterANewerVersionLaunches() {
    let history = UpdateHistory(defaults: temporaryDefaults())
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    history.launched("0.5.47", now: start)
    #expect(history.recent("0.5.47", now: start) == nil)
    let updated = start.addingTimeInterval(3600)
    history.launched("0.5.48", now: updated)
    #expect(history.recent("0.5.48", now: updated) == "0.5.48")
    #expect(history.recent("0.5.48", now: updated.addingTimeInterval(UpdateHistory.shown - 1)) == "0.5.48")
    #expect(history.recent("0.5.48", now: updated.addingTimeInterval(UpdateHistory.shown)) == nil)
    #expect(history.recent("0.5.48", now: updated.addingTimeInterval(-60)) == nil)
    // A relaunch of the same version doesn't restart the day.
    history.launched("0.5.48", now: updated.addingTimeInterval(7200))
    #expect(history.recent("0.5.48", now: updated.addingTimeInterval(UpdateHistory.shown + 60)) == nil)
    // An older copy opened afterwards isn't an update.
    history.launched("0.5.10", now: updated)
    #expect(history.recent("0.5.10", now: updated) == nil)
    #expect(UpdateHistory.notes("0.5.48").absoluteString == "https://github.com/arnenoori/side-a-releases/releases/tag/v0.5.48")
}

@MainActor @Test func accountWorkInProgressHoldsAnUpdate() async throws {
    let store = AccountStore(demo: true, root: temporaryRoot())
    #expect(store.relaunchActivity == QuietInstall.Activity())
    store.signingIn.insert("a")
    #expect(store.relaunchActivity.busy == ["a sign-in"])
    store.signingIn = []
    store.waking.insert("a")
    #expect(store.relaunchActivity.busy == ["a login renewal"])
    store.waking = []
    store.sessions.drafts["s"] = "half a thought"
    #expect(store.relaunchActivity.busy == ["an unsent message"])
    store.sessions.drafts["s"] = "  "
    #expect(store.relaunchActivity.busy.isEmpty)
    let gate = Gate()
    store.testBridge = { (_: [String]) in await gate.wait(); return Data() }
    let swap = Task { try await store.bridgeOutput(["swap", "slot", "b"]) }
    try await until(store.relaunchActivity.busy == ["an account change"])
    await gate.release()
    _ = try await swap.value
    #expect(store.relaunchActivity.busy.isEmpty)
    _ = try await store.bridgeOutput(["usage", "a"])
    #expect(!AccountStore.changes(["usage", "a"]) && !AccountStore.changes(["cleanup", "disk"]) && AccountStore.changes(["cleanup", "archive"]))
}

// MARK: Key check

private final class Signatures: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [DispatchSemaphore] = []
    var started: Int { lock.withLock { gates.count } }
    func sign() -> Bool {
        let gate = DispatchSemaphore(value: 0)
        lock.withLock { gates.append(gate) }
        gate.wait()
        return true
    }
    func finish(_ n: Int) { lock.withLock { gates[n] }.signal() }
}

/// The old key's check answering after Make New Key must not vouch for the new one.
@MainActor @Test func aKeyCheckFromBeforeMakeNewKeyVouchesForNothing() async throws {
    let keychain = try TestKeychain()
    let store = AccountStore(demo: true, root: temporaryRoot())
    let remote = RemoteController(store: store, keychain: keychain.store, addresses: ["127.0.0.1"], port: freePort())
    store.remote = remote
    defer { remote.server?.stop() }
    let signatures = Signatures()
    remote.signs = { _ in signatures.sign() }
    remote.on = true
    remote.start()
    try await until(signatures.started == 1)
    remote.makeNewKey()
    try await until(signatures.started == 2)
    signatures.finish(0)
    try await Task.sleep(for: .milliseconds(100))
    #expect(remote.server == nil)
    signatures.finish(1)
    try await until(remote.server != nil)
}
