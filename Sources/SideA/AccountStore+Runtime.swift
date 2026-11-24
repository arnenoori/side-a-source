import Foundation
import SideACore

extension AccountStore {
    var reportURL: URL { root.appendingPathComponent("runtime/report.json") }
    var usageCacheURL: URL { root.appendingPathComponent("runtime/usage-cache.json") }

    func noteCrashes() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let key = "crashesNotedUntil"
        // swiftlint:disable:next user_defaults_standard -- the crash-notice cursor is private to this method
        let since = UserDefaults.standard.object(forKey: key) as? Date ?? Date().addingTimeInterval(-7 * 86_400)
        // swiftlint:disable:next user_defaults_standard -- the crash-notice cursor is private to this method
        UserDefaults.standard.set(Date(), forKey: key)
        for crash in CrashReports.crashes(since: since) {
            let version = crash.version.map { " \($0)" } ?? ""
            let line = "Side A\(version) stopped unexpectedly on \(crash.at.formatted(date: .abbreviated, time: .shortened)): \(crash.summary)"
            autopilotLog.write(line)
            RemoteLog.shared(line)
        }
    }
}
