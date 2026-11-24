import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import UserNotifications

extension AppDelegate {
    static let failedSuffix = ".failed"

    /// The words for an answer that didn't settle its request: the Mac's own reason when it refused, and only an
    /// unreachable Mac when that is what happened.
    static func failureReason(_ result: NotificationAnswer.Result, payload: PushPayload) -> String? {
        switch result {
        case .failed(let message): message
        case .queued(let mac): "Couldn't reach \(mac). Open to answer."
        case .noMac: "Couldn't reach \(PairedMac.load(payload.mac)?.displayName ?? PairedMac.all().map(\.endpoint.kind).shared.your()). Open to answer."
        default: nil
        }
    }

    /// The request as it was: iOS takes a notification down once one of its actions runs, so a request that is still
    /// open is put back unchanged, with the same words and category, so Allow and Deny still act on it.
    static func retained(_ original: UNNotificationRequest) -> UNNotificationRequest {
        let content = original.content.mutableCopy() as? UNMutableNotificationContent ?? UNMutableNotificationContent()
        content.sound = nil
        return UNNotificationRequest(identifier: original.identifier, content: content, trigger: nil)
    }

    static func failureNotice(_ reason: String, for payload: PushPayload, original: UNNotificationRequest) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = payload.title ?? "Side A needs you"
        content.subtitle = payload.subtitle ?? ""
        content.body = reason
        content.threadIdentifier = original.content.threadIdentifier
        content.userInfo = ["p": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))) ?? [:]]
        return UNNotificationRequest(identifier: original.identifier + failedSuffix, content: content, trigger: nil)
    }

    func keepRequest(_ original: UNNotificationRequest, _ payload: PushPayload, reason: String) async {
        for request in [Self.retained(original), Self.failureNotice(reason, for: payload, original: original)] {
            do { try await UNUserNotificationCenter.current().add(request) } catch {
                RemoteLog.error(.push, "couldn't post a notification: \(KitLog.describe(error))")
            }
        }
    }
}
