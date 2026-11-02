import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import UIKit
import UserNotifications

/// Notification actions from a banner or the Lock Screen (section 5.1): an answer goes through the
/// shared outbox, Open goes to the request or session by its deep link.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Diagnostics.start()
        Diagnostics.watchNetwork()
        DeviceLock.prepare()
        UNUserNotificationCenter.current().delegate = self
        NotificationCategories.register()
        Launch.afterFirstFrame {
            let info = Bundle.main.infoDictionary
            RemoteLog.log(.app, "launch \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")) iOS \(UIDevice.current.systemVersion)"
                          + " paired \(PairedMac.all().map { "\($0.endpoint.name) at \($0.endpoint.addresses.map(\.absoluteString).joined(separator: ", "))" }.joined(separator: "; "))")
            Task { await PushRegistrar.shared.registerIfAllowed() }
            PushRegistrar.shared.watchActivities()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        RemoteLog.log(.push, "APNs token \(token.prefix(4).map { String(format: "%02x", $0) }.joined())…")
        PushRegistrar.shared.received(token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        RemoteLog.error(.push, "APNs registration failed: \(KitLog.describe(error))")
    }

    /// The relay's silent token check; nothing else arrives without an alert.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard await RelayDevice.answer(userInfo) else { return .noData }
        // The relay refuses a Live Activity's token until the device is proven.
        await PushRegistrar.shared.reportActivities()
        return .newData
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        // Actions only on a payload this phone opened; anything else just opens the app.
        guard let payload = PushOpener.verified(response.notification.request) else {
            if let payload = PushPayload(userInfo: content.userInfo) { open(payload) }
            return
        }
        let result: NotificationAnswer.Result
        if let answer = NotificationCategories.answer(for: response.actionIdentifier), let request = payload.rid {
            result = await NotificationAnswer.send(answer, to: request, macID: payload.mac)
        } else if let reply = response as? UNTextInputNotificationResponse, let session = payload.sid {
            result = await NotificationAnswer.reply(reply.userText, to: session, turnID: payload.turnID, macID: payload.mac)
        } else {
            open(payload)
            return
        }
        switch result {
        case .sent, .answeredElsewhere: break
        case .queued(let mac): await couldNotReach(mac, payload)
        case .failed(let message) where response is UNTextInputNotificationResponse: await notice("\(message) Open to send it again.", payload)
        case .failed, .noMac: await couldNotReach(PairedMac.load(payload.mac)?.endpoint.name ?? "your Mac", payload)
        }
    }

    /// The foreground's banners stay plain until the accessory takes them over (M2).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    private func open(_ payload: PushPayload) {
        let path = payload.rid.map { "request/\(payload.mac)/\($0)" } ?? payload.sid.map { "session/\(payload.mac)/\($0)" }
        guard let path, let url = URL(string: "sidea-remote://\(path)") else { return }
        UIApplication.shared.open(url)
    }

    /// "Couldn't reach MacBook Pro. Open to answer." in place of the one that failed.
    private func couldNotReach(_ mac: String, _ payload: PushPayload) async { await notice("Couldn't reach \(mac). Open to answer.", payload) }

    private func notice(_ body: String, _ payload: PushPayload) async {
        let content = UNMutableNotificationContent()
        content.title = payload.title ?? "Side A needs you"
        content.subtitle = payload.subtitle ?? ""
        content.body = body
        content.threadIdentifier = payload.sid ?? ""
        content.userInfo = ["p": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))) ?? [:]]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: payload.rid ?? UUID().uuidString,
                                                                                 content: content, trigger: nil))
    }
}
