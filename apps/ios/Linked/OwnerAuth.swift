import Foundation
import LocalAuthentication
import SideARemoteShared

/// Face ID or the passcode before something a stolen, unlocked phone shouldn't do on its own: terminal input,
/// keys while a request waits, answers from a locked Lock Screen. One success holds for `grace` in this process.
enum OwnerAuth {
    static let grace: TimeInterval = 5 * 60
    nonisolated(unsafe) private static var confirmedAt: Date?
    private static let lock = NSLock()

    static func confirm(reason: String, grace: TimeInterval = grace) async -> Bool {
        if let at = lock.withLock({ confirmedAt }), Date.now.timeIntervalSince(at) < grace { return true }
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return false }
        } catch {
            RemoteLog.log(.app, "owner check declined: \((error as NSError).code)")
            return false
        }
        lock.withLock { confirmedAt = .now }
        return true
    }

    /// Ends the grace, as the app goes to the background.
    static func expire() {
        lock.withLock { confirmedAt = nil }
        DeviceKeys.expire()
    }
}

/// Whether the phone is locked, which an extension can't ask UIKit: a file protected `.complete` can't be read then.
enum DeviceLock {
    private static var probe: URL? { SharedStorage.container?.appendingPathComponent("Library/lock-probe") }

    /// The app writes the probe while unlocked; an extension reads it.
    static func prepare() {
        guard let probe, !FileManager.default.fileExists(atPath: probe.path) else { return }
        try? Data("1".utf8).write(to: probe, options: [.completeFileProtection])
    }

    /// No probe yet counts as locked, so the check asks rather than assumes.
    static var isLocked: Bool {
        guard let probe else { return true }
        return (try? Data(contentsOf: probe)) == nil
    }
}
