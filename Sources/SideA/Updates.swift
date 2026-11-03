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
    @Published var automaticallyChecks = false { didSet { updater?.automaticallyChecksForUpdates = automaticallyChecks } }
    /// Off: Side A still finds updates and shows them in the menu, but installs only when asked.
    @Published var automaticallyInstalls = false { didSet { updater?.automaticallyDownloadsUpdates = automaticallyInstalls } }
    private let driver = UpdateUserDriver()
    private var updater: SPUUpdater!
    private var observation: AnyCancellable?
    override init() {
        super.init()
        let enabled = !ProcessInfo.processInfo.arguments.contains("--demo") && Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        driver.resumed = { [weak self] item, state, decide in
            guard let self else { return decide(nil) }
            resumed(item, state: state, decide: decide)
        }
        if enabled { try? updater.start() }
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyInstalls = updater.automaticallyDownloadsUpdates
        observation = updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 && enabled }
    }
    func check() { guard canCheck else { return }; NSApp.activate(ignoringOtherApps: true); updater.checkForUpdates() }
    /// Without Sparkle's window: what it finds goes to `available`, and the menu shows it.
    func checkQuietly() -> Bool {
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
    /// Not handled here, so Sparkle ends the session and later checks can still reach the feed.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated { available = version }
        return false
    }
}

struct UpdateButton: View {
    @ObservedObject var updates: Updates
    var body: some View { Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck) }
}
