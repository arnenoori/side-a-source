import AppKit
import Combine
import Sparkle
import SwiftUI

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
        controller = SPUStandardUpdaterController(startingUpdater: enabled, updaterDelegate: self, userDriverDelegate: nil)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyInstalls = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 && enabled }
    }
    func check() { guard canCheck else { return }; NSApp.activate(ignoringOtherApps: true); controller.checkForUpdates(nil) }
    /// The newer version Sparkle found; shown in the menu so a silent update is never invisible.
    @Published private(set) var available: String?
    private var installNow: (() -> Void)?
    /// Restarts into a downloaded update, or shows Sparkle's dialog if it is not downloaded yet.
    func install() { if let installNow { installNow() } else { check() } }
    // Sparkle calls its delegate on the main thread.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { available = version }
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
