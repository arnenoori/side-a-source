import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated deinit {}

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

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        if Self.clearQuietNotice(userInfo) { return .noData }
        guard await RelayDevice.answer(userInfo) else { return .noData }
        await PushRegistrar.shared.reportActivities()
        return .newData
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        if content.categoryIdentifier == PushCategory.macQuiet.rawValue {
            if let link = Self.quietLink(content.userInfo) { open(link) }
            return
        }
        guard let payload = PushOpener.verified(response.notification.request) else {
            guard let payload = PushPayload(userInfo: content.userInfo) else { return }
            if content.userInfo[Self.composeKey] as? Bool == true, let link = Self.composeLink(for: payload) { return open(link) }
            return open(payload)
        }
        let typed = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = response.notification.request.identifier
        let result: NotificationAnswer.Result
        if let answer = NotificationCategories.answer(for: response.actionIdentifier), let request = payload.rid {
            result = await NotificationAnswer.send(answer, to: request, macID: payload.mac)
        } else if let typed, !typed.isEmpty, response.actionIdentifier == NotificationCategories.Action.answer, let request = payload.rid,
                  PushOpener.answersTyped(payload), let question = payload.questions?.first {
            let answer = RemoteAnswer.answers([QuestionAnswer(question: question.question, picked: [], other: typed)])
            result = await NotificationAnswer.send(answer, to: request, macID: payload.mac, typed: payload.sid.map { (text: typed, session: $0) })
        } else if let typed, !typed.isEmpty, let session = payload.sid {
            if content.categoryIdentifier == PushCategory.finishedFaceID.rawValue {
                NotificationDrafts.keep(typed, session: session, mac: payload.mac)
                if let link = Self.composeLink(for: payload) { open(link) }
                return
            }
            result = await NotificationAnswer.reply(typed, to: session, turnID: payload.turnID, macID: payload.mac)
        } else {
            open(payload)
            return
        }
        switch result {
        case .sent, .answeredElsewhere: break
        case .queued(let mac) where payload.rid == nil:
            await notice("Not confirmed yet: open Side A Remote to see whether your reply reached \(mac).", payload, replacing: identifier)
        case .held(let mac):
            await notice("Not sent yet: couldn't reach \(mac). Side A Remote sends your reply when you next open it, unless the session has moved on by then.",
                         payload, replacing: identifier)
        case .kept(let message): await notice(message, payload, replacing: identifier, compose: payload.rid == nil)
        case .failed(let message) where response is UNTextInputNotificationResponse: await notice("\(message) Open to send it again.", payload)
        case .queued, .failed, .noMac:
            if let reason = Self.failureReason(result, payload: payload) { await keepRequest(response.notification.request, payload, reason: reason) }
        }
    }

    static func quietLink(_ userInfo: [AnyHashable: Any], macs: [PairedMac] = PairedMac.all()) -> URL? {
        guard let named = userInfo["q"] as? String,
              let mac = macs.first(where: { $0.relayInstallID.map(RelayDevice.activityMacID(install:)) == named }) else { return nil }
        return URL(string: "sidea-remote://mac/\(mac.endpoint.macID)")
    }

    static let composeKey = "compose"

    static func composeLink(for payload: PushPayload) -> URL? {
        payload.sid.flatMap { URL(string: "sidea-remote://compose/\(payload.mac)/\($0)") }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        Self.presentation(for: PushPayload(userInfo: notification.request.content.userInfo), active: UIApplication.shared.applicationState == .active,
                          live: LiveLink.liveMacs)
    }

    static func presentation(for payload: PushPayload?, active: Bool, live: Set<String>) -> UNNotificationPresentationOptions {
        if active, let payload, live.contains(payload.mac) { return [] }
        return [.banner, .list, .sound]
    }

    private func open(_ payload: PushPayload) {
        guard let url = Self.link(for: payload) else { return }
        open(url)
    }

    private func open(_ url: URL) { UIApplication.shared.open(url) }

    static func link(for payload: PushPayload) -> URL? {
        let path = payload.rid.map { "request/\(payload.mac)/\($0)" } ?? payload.sid.map { "session/\(payload.mac)/\($0)" }
            ?? (PushOpener.grouped(payload) ? "mac/\(payload.mac)" : nil)
        return path.flatMap { URL(string: "sidea-remote://\($0)") }
    }

    private func notice(_ body: String, _ payload: PushPayload, replacing identifier: String? = nil, compose: Bool = false) async {
        let content = UNMutableNotificationContent()
        content.title = payload.title ?? "Side A needs you"
        content.subtitle = payload.subtitle ?? ""
        content.body = body
        content.threadIdentifier = payload.sid ?? ""
        var info: [String: Any] = ["p": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))) ?? [:]]
        if compose { info[Self.composeKey] = true }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: payload.rid ?? identifier ?? UUID().uuidString, content: content, trigger: nil)
        do { try await UNUserNotificationCenter.current().add(request) } catch {
            RemoteLog.error(.push, "couldn't post a notification: \(KitLog.describe(error))")
        }
    }
}
