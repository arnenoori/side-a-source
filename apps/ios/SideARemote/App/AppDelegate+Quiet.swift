import UserNotifications

extension AppDelegate {
    /// The relay's "gone quiet" notice for one Mac is delivered under this id, its collapse id.
    static func quietNoticeID(_ macID: String) -> String { "mac-quiet-" + macID }

    /// The relay's silent push for a Mac that is back (`back`: the Mac's id as a Live Activity names it): its notice is
    /// taken down and nothing is shown. Whatever the push carries, only that one Mac's notice id can be removed.
    static func clearQuietNotice(_ userInfo: [AnyHashable: Any], center: UNUserNotificationCenter = .current()) -> Bool {
        guard let macID = userInfo["back"] as? String, !macID.isEmpty else { return false }
        center.removeDeliveredNotifications(withIdentifiers: [quietNoticeID(macID)])
        return true
    }
}
