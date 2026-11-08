import AppKit
import Combine
import Sparkle
import SwiftUI

/// The Sparkle error code of the last update cycle that failed, until one goes right.
struct UpdateFailure: Equatable {
    private(set) var code: Int?
    /// No update, a cancel, or "install later" aren't failures; "no update" also means the feed answered.
    mutating func aborted(domain: String, code: Int) {
        guard domain == SUSparkleErrorDomain else { return }
        if code == 1001 { self.code = nil } else if ![4007, 4008].contains(code) { self.code = code }
    }
    mutating func checked() { code = nil }
}

/// While a downloaded update waits for Side A to quit, Sparkle resumes it on every check instead of reading the feed.
enum StagedUpdate {
    /// Whether the feed lists a build newer than `build`, the one waiting to install.
    static func superseded(build: String, feed: Data) -> Bool {
        let reader = FeedBuilds()
        let parser = XMLParser(data: feed)
        parser.delegate = reader
        guard parser.parse() else { return false }
        return reader.builds.contains { $0.compare(build, options: .numeric) == .orderedDescending }
    }

    private final class FeedBuilds: NSObject, XMLParserDelegate {
        var builds: [String] = []
        private var text: String?
        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if element == "sparkle:version" { text = "" }
            if element == "enclosure", let build = attributes["sparkle:version"] { builds.append(build) }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text?.append(string) }
        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            guard element == "sparkle:version", let build = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            if !build.isEmpty { builds.append(build) }
            text = nil
        }
    }
}

/// When a downloaded update may restart Side A by itself: nobody at the Mac, and nothing a relaunch would cut off.
enum QuietInstall {
    /// No keyboard or pointer input for this long, unless the screen is locked.
    static let away: TimeInterval = 10 * 60
    /// How often a waiting update looks again.
    static let interval: TimeInterval = 60

    /// What Side A is in the middle of.
    struct Activity: Equatable, Sendable {
        /// Requests, questions and plans waiting in the island.
        var pending = 0
        /// Pool requests being answered.
        var poolInFlight = 0
        /// Anything else a relaunch would break, by name: a sign-in, a login renewal, an unsent reply.
        var busy: [String] = []
    }

    enum Hold: Equatable {
        case off, nothingStaged, someoneHere, waiting(Int), pool(Int), busy(String)
    }

    /// Why not now, or nil when the update may install and relaunch.
    static func hold(automatic: Bool, staged: Bool, presence: UserPresence, activity: Activity) -> Hold? {
        guard automatic else { return .off }
        guard staged else { return .nothingStaged }
        guard presence.away(for: away) else { return .someoneHere }
        if activity.pending > 0 { return .waiting(activity.pending) }
        if activity.poolInFlight > 0 { return .pool(activity.poolInFlight) }
        if let first = activity.busy.first { return .busy(first) }
        return nil
    }

    /// Whether Side A keeps Sparkle's install-now block for a download. Off, or critical: Sparkle's own way, as before.
    static func takesOver(automatic: Bool, critical: Bool) -> Bool { automatic && !critical }
}

/// The version this Mac last ran, so the menu can say "Updated to X" for a day afterwards.
struct UpdateHistory {
    static let shown: TimeInterval = 24 * 3600
    private static let lastKey = "SideALastLaunchedVersion", toKey = "SideAUpdatedTo", atKey = "SideAUpdatedAt"
    let defaults: UserDefaults

    /// Records a launch of `version`; newer than the last one launched counts as an update.
    func launched(_ version: String, now: Date = Date()) {
        let last = defaults.string(forKey: Self.lastKey)
        defaults.set(version, forKey: Self.lastKey)
        guard let last, last != version else { return }
        if version.compare(last, options: .numeric) == .orderedDescending {
            defaults.set(version, forKey: Self.toKey)
            defaults.set(now.timeIntervalSince1970, forKey: Self.atKey)
        } else {
            defaults.removeObject(forKey: Self.toKey)
        }
    }

    /// The version this Mac updated to within the last day, while it is still the one running.
    func recent(_ current: String, now: Date = Date()) -> String? {
        guard let version = defaults.string(forKey: Self.toKey), version == current,
              let at = defaults.object(forKey: Self.atKey) as? Double else { return nil }
        let age = now.timeIntervalSince1970 - at
        return age >= 0 && age < Self.shown ? version : nil
    }

    /// The release on GitHub, made from releases/vX.Y.Z.md.
    static func notes(_ version: String) -> URL {
        URL(string: "https://github.com/arnenoori/side-a-releases/releases/tag/v\(version)")!
    }
}

/// Sparkle's own windows, except that an update it resumes from disk goes to `resumed` first.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    let standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    /// Answers with a choice, or nil to show Sparkle's window.
    var resumed: ((SUAppcastItem, SPUUserUpdateState, @escaping (SPUUserUpdateChoice?) -> Void) -> Void)?

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard state.stage != .notDownloaded, let resumed else {
            return standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
        }
        resumed(appcastItem, state) { [standard] choice in
            if let choice { reply(choice) } else { standard.showUpdateFound(with: appcastItem, state: state, reply: reply) }
        }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) { standard.show(request, reply: reply) }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { standard.showUserInitiatedUpdateCheck(cancellation: cancellation) }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { standard.showUpdateReleaseNotes(with: downloadData) }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) { standard.showUpdaterError(error, acknowledgement: acknowledgement) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { standard.showDownloadInitiated(cancellation: cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) { standard.showDownloadDidReceiveData(ofLength: length) }
    func showDownloadDidStartExtractingUpdate() { standard.showDownloadDidStartExtractingUpdate() }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { standard.showReady(toInstallAndRelaunch: reply) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }
    func showUpdateInFocus() { standard.showUpdateInFocus() }
    func dismissUpdateInstallation() { standard.dismissUpdateInstallation() }
}

@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    /// Downloads in the background and installs at a quiet moment (`QuietInstall`). Off: Side A still finds updates and
    /// shows them in the menu, but installs only when asked or on quit.
    @Published var automaticallyUpdates = false {
        didSet {
            if enabled { updater?.automaticallyDownloadsUpdates = automaticallyUpdates }
            if staged != nil { watchStaged() }
        }
    }
    /// Who is at the Mac; tests put their own in.
    var presence: () -> UserPresence = { UserPresence.now() }
    /// What Side A is in the middle of; the app connects its store.
    var activity: () -> QuietInstall.Activity = { QuietInstall.Activity() }
    /// A packaged app with a feed; `swift run`, tests and the demo leave Sparkle and its settings alone.
    private var enabled = false
    private let driver = UpdateUserDriver()
    private var updater: SPUUpdater!
    private var observation: AnyCancellable?
    private let history: UpdateHistory
    private let version: String?
    /// Set when the build installed was already superseded: the relaunched app looks for the newer one at once.
    private static let checkAfterRelaunchKey = "SideACheckAfterUpdate"
    init(history: UpdateHistory = UpdateHistory(defaults: .standard),
         version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) {
        self.history = history
        self.version = version
        super.init()
        enabled = !ProcessInfo.processInfo.arguments.contains("--demo") && Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        driver.resumed = { [weak self] item, state, decide in
            guard let self else { return decide(nil) }
            resumed(item, state: state, decide: decide)
        }
        if enabled {
            // Checking is always on; the one switch decides what happens with what a check finds.
            if !updater.automaticallyChecksForUpdates { updater.automaticallyChecksForUpdates = true }
            if let version { history.launched(version) }
            try? updater.start()
        }
        automaticallyUpdates = updater.automaticallyDownloadsUpdates
        observation = updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                canCheck = $0 && enabled
                if canCheck, UserDefaults.standard.bool(forKey: Self.checkAfterRelaunchKey) {
                    UserDefaults.standard.removeObject(forKey: Self.checkAfterRelaunchKey)
                    DispatchQueue.main.async { [weak self] in _ = self?.checkQuietly() }
                }
            }
    }
    /// The version Side A updated to in the last day, for the menu.
    func updated(now: Date = Date()) -> String? { version.flatMap { history.recent($0, now: now) } }
    /// Sparkle's window, or, while Side A holds a downloaded update (and Sparkle can't check), an offer to install it.
    func check() {
        if let staged {
            NSApp?.activate(ignoringOtherApps: true)
            if confirmInstall(staged.version) { installStaged(asked: true) }
            return
        }
        guard canCheck else { return }
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }
    /// Check for Updates… or Update to X can do something: Sparkle is free, or an update is waiting.
    var canUpdate: Bool { canCheck || staged != nil }
    /// Asks whether to restart into `version` now; tests answer for the user.
    var confirmInstall: (String) -> Bool = { version in
        let alert = NSAlert()
        alert.messageText = "Side A \(version) Is Ready"
        alert.addButton(withTitle: "Restart to Update")
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Without Sparkle's window: what it finds goes to `available`, and the menu shows it. A waiting update is already
    /// in the menu, so there is nothing more to find until it installs.
    func checkQuietly() -> Bool {
        if staged != nil { return true }
        guard canCheck else { return false }
        updater.checkForUpdatesInBackground()
        return true
    }
    /// The newer version Sparkle found; shown in the menu so a silent update is never invisible.
    @Published private(set) var available: String?
    private var installRequested = false
    /// The waiting build dropped this cycle because the feed has a newer one.
    private var dropped: String?
    private var drops = 0
    /// Restarts into a downloaded update once the feed confirms it is the newest, or shows Sparkle's dialog.
    func install() {
        if staged != nil { return installStaged(asked: true) }
        guard canCheck else { return }
        installRequested = true
        check()
    }
    private func resumed(_ item: SUAppcastItem, state: SPUUserUpdateState, decide: @escaping (SPUUserUpdateChoice?) -> Void) {
        let build = item.versionString, feed = updater.feedURL
        Task {
            if let feed, await Self.feed(feed, supersedes: build) {
                dropped = build
                available = nil
                return decide(.skip)
            }
            if installRequested, state.stage == .installing { decide(.install) }
            else if state.userInitiated || item.isCriticalUpdate { decide(nil) }
            else { decide(.dismiss) }
        }
    }
    private nonisolated static func feed(_ url: URL, supersedes build: String) async -> Bool {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return StagedUpdate.superseded(build: build, feed: data)
    }
    // Sparkle calls its delegate on the main thread.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { available = version; lastFailure.checked() }
    }
    /// For the menu's fallback and diagnostics.
    var failure: Int? { lastFailure.code }
    @Published private var lastFailure = UpdateFailure()
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { available = nil; lastFailure.checked() }
    }
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        let domain = error.domain, code = error.code
        MainActor.assumeIsolated { lastFailure.aborted(domain: domain, code: code) }
    }
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { finishedCycle() }
    }
    /// After dropping a superseded download, checks the feed again so the newest build is what's offered.
    private func finishedCycle() {
        let interactive = installRequested
        installRequested = false
        guard let build = dropped else { drops = 0; return }
        dropped = nil
        if UserDefaults.standard.string(forKey: "SUSkippedVersion") == build { UserDefaults.standard.removeObject(forKey: "SUSkippedVersion") }
        drops += 1
        guard drops <= 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if interactive { install() } else { _ = checkQuietly() }
        }
    }
    var willRelaunch: (() -> Void)?
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { willRelaunch?() }
    }

    // MARK: Quiet install

    /// A download Sparkle handed over: `install` relaunches into it without any window.
    struct Staged {
        let build: String
        let version: String
        let install: () -> Void
    }
    /// Set until the app quits: Sparkle has no way to take the block back, and its session stays open until it's used.
    @Published private(set) var staged: Staged?
    private var watch: Timer?
    private var installing = false
    /// Someone asked for the waiting update while a quiet install was reading the feed.
    private var installAsked = false
    /// The block was called; another call would only ask Sparkle to relaunch twice.
    private var installed = false

    /// Update Automatically on: Side A keeps the install-now block and uses it at a quiet moment; Sparkle's later cycles
    /// wait until then. Off, or a critical update: not handled here, so Sparkle ends the session, later checks can
    /// still reach the feed, and the update installs on quit or from the menu as before.
    /// Turned off after Side A took a block: Sparkle can't take it back, so it stays held. It installs when asked
    /// (Update to X, Check for Updates…) or, as Sparkle does for any download it has prepared, when Side A quits.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString, build = item.versionString, critical = item.isCriticalUpdate
        nonisolated(unsafe) let block = immediateInstallationBlock
        return MainActor.assumeIsolated {
            available = version
            guard QuietInstall.takesOver(automatic: automaticallyUpdates, critical: critical) else { return false }
            staged = Staged(build: build, version: version, install: block)
            installed = false
            watchStaged()
            return true
        }
    }

    /// Looks each minute while the switch is on and the block unused; stops otherwise.
    private func watchStaged() {
        watch?.invalidate()
        watch = nil
        guard automaticallyUpdates, staged != nil, !installed else { return }
        let timer = Timer(timeInterval: QuietInstall.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfQuiet() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    /// Why a waiting update isn't installing right now, or nil when it may.
    var hold: QuietInstall.Hold? {
        QuietInstall.hold(automatic: automaticallyUpdates, staged: staged != nil, presence: presence(), activity: activity())
    }

    /// Each minute while an update waits.
    func installIfQuiet() {
        guard hold == nil else { return }
        installStaged(asked: false)
    }

    /// Reads the feed first. A waiting build it has superseded still installs, since Sparkle can't swap downloads while
    /// it waits, and the relaunched app checks again straight away for the newer one.
    /// The feed is read with Side A's own request, so it works while Sparkle's session is stalled; when it can't be
    /// read, the update installs anyway.
    private func installStaged(asked: Bool) {
        guard let staged, !installed else { return }
        if asked { installAsked = true }
        guard !installing else { return }
        installing = true
        let feed = enabled ? updater.feedURL : nil
        Task {
            defer { installing = false; installAsked = false }
            if let feed, await Self.feed(feed, supersedes: staged.build) {
                UserDefaults.standard.set(true, forKey: Self.checkAfterRelaunchKey)
            }
            // The feed can take seconds, and someone may have come back meanwhile.
            guard installAsked || hold == nil else { return }
            fire()
        }
    }

    /// Calls Sparkle's block once, on the main thread.
    private func fire() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let staged, !installed else { return }
        installed = true
        watchStaged()
        staged.install()
    }
}

extension AccountStore {
    /// What an automatic update waits for before relaunching Side A.
    var relaunchActivity: QuietInstall.Activity {
        var busy: [String] = []
        if !signingIn.isEmpty || !adopting.isEmpty { busy.append("a sign-in") }
        if !waking.isEmpty { busy.append("a login renewal") }
        if bridgeChanges > 0 { busy.append("an account change") }
        if poolTesting { busy.append("a pool test") }
        if island.replying != nil { busy.append("a reply in the island") }
        if sessions.drafts.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            || sessions.attachments.values.contains(where: { !$0.isEmpty }) { busy.append("an unsent message") }
        if remote.pairing != nil { busy.append("pairing a phone") }
        if keepAwake.busy { busy.append("Keep Awake's helper") }
        return QuietInstall.Activity(pending: island.pending.count, poolInFlight: pool?.inFlight ?? 0, busy: busy)
    }
}

struct UpdateButton: View {
    @ObservedObject var updates: Updates
    var body: some View { Button("Check for Updates…") { updates.check() }.disabled(!updates.canUpdate) }
}
