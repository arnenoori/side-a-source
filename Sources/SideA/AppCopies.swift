import AppKit

/// Two copies share one Keychain, one data folder and one update installer, so only one may run.
enum AppCopies {
    static let releaseID = "com.arnenoori.sidea"
    static var isRelease: Bool { Bundle.main.bundleIdentifier == releaseID }

    static func claimLaunch() {
        guard !ProcessInfo.processInfo.arguments.contains("--demo") else { return }
        let me = NSRunningApplication.current
        let others = [releaseID, releaseID + ".dev"]
            .flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
            .filter { $0.processIdentifier != me.processIdentifier }
        guard !others.isEmpty else { return }
        let mine = build(Bundle.main.bundleURL)
        if let keeper = others.first(where: { $0.bundleURL == Bundle.main.bundleURL || build($0.bundleURL) > mine }) {
            keeper.activate()
            exit(0)
        }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline { usleep(50_000) }
    }

    private static func build(_ url: URL?) -> Int {
        guard let url, let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return 0 }
        return Int(info["CFBundleVersion"] as? String ?? "") ?? 0
    }

    private static let declinedKey = "declinedMoveToApplications"

    /// Sparkle refuses to update a copy on a disk image or a translocated one.
    @MainActor static func offerMove() {
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let folders = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        guard isRelease, !folders.contains(where: { here.path.hasPrefix($0.path + "/") }),
              !UserDefaults.standard.bool(forKey: declinedKey) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Side A to Applications?"
        alert.informativeText = "Side A keeps itself up to date from there. From Downloads or a disk image, updates can't install."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: declinedKey)
            return
        }
        let system = folders[0]
        let folder = FileManager.default.isWritableFile(atPath: system.path) ? system : folders[1]
        let destination = folder.appendingPathComponent("Side A.app")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: here, to: destination)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Side A couldn't move itself"
            failure.informativeText = "Drag Side A into your Applications folder, then open it from there."
            failure.runModal()
            return
        }
        let original = here.path.contains("/AppTranslocation/") || here.path.hasPrefix("/Volumes/") ? nil : here
        if let original { try? FileManager.default.trashItem(at: original, resultingItemURL: nil) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in }
    }
}
