import Foundation
import SideAProtocol
import SideARemoteShared
import UserNotifications

/// Opens the sealed payload (relay-and-release, "Notification Service Extension"): words, thread and
/// relevance from the Mac, and `REQUEST` loosened to `REQUEST_SAFE` only when the authenticated payload
/// says the Lock Screen may allow it. No networking: everything shown is in the payload.
final class NotificationService: UNNotificationServiceExtension {
    nonisolated deinit {}

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        Diagnostics.start()
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        // Until the sealed payload opens, nothing on this notification may act: if time runs out, it shows Open only.
        if let fallback = content.mutableCopy() as? UNMutableNotificationContent {
            PushOpener.generic(fallback, body: nil)
            fallback.userInfo.removeValue(forKey: "p")
            bestAttempt = fallback
        }
        // Nothing sealed: the demo's payload in the clear (Debug), or a push someone other than the Mac wrote. Only the
        // first keeps its words and actions. A push without `mutable-content` never reaches this extension, so its words
        // and category show as sent; `PushOpener.verified` is what keeps them from being acted on.
        guard let sealed = content.userInfo["e"] as? String else {
            #if DEBUG
            if (content.userInfo["p"] as? [String: Any])?["mac"] as? String == "demo" { return contentHandler(content) }
            #endif
            RemoteLog.error(.push, "unsealed \(content.categoryIdentifier) \(request.identifier): Open only")
            PushOpener.generic(content, body: nil)
            content.userInfo.removeValue(forKey: "p")
            contentHandler(content)
            return
        }
        let category = PushCategory(rawValue: content.categoryIdentifier)
        switch PushOpener.open(sealed, category: category, collapseID: request.identifier) {
        case .opened(let payload, let data):
            RemoteLog.log(.push, "opened \(content.categoryIdentifier) \(request.identifier)")
            PushOpener.fill(content, with: payload, data: data, category: category, identifier: request.identifier)
        case .noKey:
            RemoteLog.error(.push, "no push key for \(content.categoryIdentifier) \(request.identifier)")
            PushOpener.generic(content, body: "Open Side A Remote to reconnect.")
        case .unreadable:
            RemoteLog.error(.push, "unreadable \(content.categoryIdentifier) \(request.identifier)")
            PushOpener.generic(content, body: nil)
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt { contentHandler(bestAttempt) }
    }
}
