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

@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published var automaticallyChecks = false { didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks } }
    /// Off: Side A still finds updates and shows them in the menu, but installs only when asked.
    @Published var automaticallyInstalls = false { didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyInstalls } }
    private var controller: SPUStandardUpdaterController!
    private var observation: AnyCancellable?
    override init() {
        super.init()
        let enabled = !ProcessInfo.processInfo.arguments.contains("--demo") && Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = SPUStandardUpdaterController(startingUpdater: enabled, updaterDelegate: self, userDriverDelegate: nil)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyInstalls = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 && enabled }
    }
    func check() { guard canCheck else { return }; NSApp.activate(ignoringOtherApps: true); controller.checkForUpdates(nil) }
    /// Without Sparkle's window: what it finds goes to `available`, and the menu shows it.
    func checkQuietly() -> Bool {
        guard canCheck else { return false }
        controller.updater.checkForUpdatesInBackground()
        return true
    }
    /// The newer version Sparkle found; shown in the menu so a silent update is never invisible.
    @Published private(set) var available: String?
    private var installNow: (() -> Void)?
    /// Restarts into a downloaded update, or shows Sparkle's dialog if it is not downloaded yet.
    func install() { if let installNow { installNow() } else { check() } }
    // Sparkle calls its delegate on the main thread.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { available = version; lastFailure.checked() }
    }
    /// For the menu's fallback and diagnostics.
    var failure: Int? { lastFailure.code }
    @Published private var lastFailure = UpdateFailure()
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { lastFailure.checked() }
    }
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        let domain = error.domain, code = error.code
        MainActor.assumeIsolated { lastFailure.aborted(domain: domain, code: code) }
    }
    var willRelaunch: (() -> Void)?
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { willRelaunch?() }
    }
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let block = immediateInstallationBlock
        MainActor.assumeIsolated { available = version; installNow = block }
        return true
    }
}

struct UpdateButton: View {
    @ObservedObject var updates: Updates
    var body: some View { Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck) }
}
