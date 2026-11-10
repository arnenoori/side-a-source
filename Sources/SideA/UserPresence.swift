import CoreGraphics
import Foundation

/// Whether someone is at this Mac: recent keyboard or pointer input, with the screen unlocked.
struct UserPresence: Sendable, Equatable {
    var idle: TimeInterval
    var locked: Bool

    static func now() -> UserPresence {
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return UserPresence(idle: idle, locked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false)
    }

    /// No input for `window` seconds, or the screen is locked.
    func away(for window: TimeInterval) -> Bool { locked || idle >= window }
}
