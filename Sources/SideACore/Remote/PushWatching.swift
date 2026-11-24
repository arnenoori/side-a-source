import Foundation
import SideAProtocol

/// "Quiet while I'm watching": whether a phone in front holds a push back. Only a phone whose own setting says so, that
/// is in front now, and that has the push's session open (a push about no one session, such as a limit, is held by any
/// phone in front). Anything else gets its push: a phone showing the session list or another session didn't see this.
public enum PushWatching {
    /// A phone in front refreshes its presence every 30 s while its socket is up, and says at once when it leaves the
    /// front; this allows one refresh and some slack. Older than that, the phone may have been suspended without a word.
    public static let fresh: TimeInterval = 40

    public static func holds(prefs: NotificationPrefs?, foreground: Bool, viewing: SessionKey?, at: Date, now: Date, session: SessionKey?) -> Bool {
        guard prefs?.suppressWhileWatching ?? true, foreground, now.timeIntervalSince(at) <= fresh else { return false }
        guard let session else { return true }
        return viewing == session
    }
}
