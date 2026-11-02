import ActivityKit
import CryptoKit
import Foundation
import SideAProtocol
import SideARemoteShared
import UserNotifications

/// App Review's way in without a Mac: the review notes give a pairing link, `https://getsidea.com/pair#review=<code>`,
/// that opens the built-in demo through the real scanner or as a link. The code isn't a secret; it opens sample data
/// and nothing else, and nothing in the demo touches the network.
enum ReviewDemo {
    /// SHA-256 of the code in the review notes.
    static let codeHash = "51182f201359c0d73e19e4a02d812f85c0e43010fa846822d719f035d867a811"

    /// A pairing link, in any of its forms, carrying the review code.
    static func matches(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased(), host = url.host()?.lowercased()
        let form = (scheme == "sidea-remote" && host == "pair" && ["", "/"].contains(url.path()))
            || (scheme == "https" && host == "getsidea.com" && ["/pair", "/pair/"].contains(url.path()))
        guard form, let fragment = url.fragment(), fragment.hasPrefix("review=") else { return false }
        let code = fragment.dropFirst("review=".count).uppercased()
        let hash = SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
        return hash == codeHash
    }

    static let requestID = "review-request"

    /// What the Lock Screen request carries, as the Service Extension would leave it: answering it goes nowhere
    /// (`NotificationAnswer` settles the demo Mac's answers on the phone).
    static var payload: PushPayload {
        PushPayload(t: "request", mac: NotificationAnswer.demoMac, sent: Date.now.timeIntervalSince1970, rid: requestID,
                    sid: DemoData.ID.syncTest, title: "Allow Bash", subtitle: "side-a · Work", body: "swift test --filter SyncEngineTests",
                    gate: .unlock, agent: .claude)
    }

    /// Asked when the demo opens, while the reviewer is in the app; the Lock Screen request needs it.
    static func askForNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// The Live Activity, started locally as a push-to-start would; ActivityKit only starts one in the foreground.
    static func startActivity() {
        guard Activity<MacActivityAttributes>.activities.isEmpty else { return }
        if let data = try? JSONEncoder().encode(payload) { PushCache.store(data, for: requestID) }
        let state = MacActivityAttributes.ContentState(working: 3, waiting: 1, topRequest: requestID,
                                                       soonestReset: .now.addingTimeInterval(2 * 3600 + 14 * 60), tightestPercent: 82)
        _ = try? Activity.request(attributes: MacActivityAttributes(macID: NotificationAnswer.demoMac),
                                  content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(30 * 60)))
    }

    /// A request on the Lock Screen 10 s after the app leaves the screen, with Allow and Deny.
    static func scheduleRequest() {
        let payload = payload
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let content = content(payload)
        // Where `PushOpener.verified` looks, so the actions act on what this phone wrote, as for a real push.
        PushCache.store(data, for: requestID)
        let request = UNNotificationRequest(identifier: requestID, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    static func content(_ payload: PushPayload) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = payload.title ?? "Allow Bash"
        content.subtitle = payload.subtitle ?? ""
        content.body = payload.body ?? ""
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = PushCategory.request.rawValue
        content.threadIdentifier = "side-a"
        content.userInfo = ["rid": requestID, "sid": payload.sid ?? ""]
        return content
    }

    /// Back before it fired: it doesn't arrive while the app is on screen.
    static func cancelRequest() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestID])
    }

    /// Leave Demo: nothing of it stays on the Lock Screen.
    static func end() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestID])
        PushCache.remove(requestID)
        Task {
            for activity in Activity<MacActivityAttributes>.activities where activity.attributes.macID == NotificationAnswer.demoMac {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
