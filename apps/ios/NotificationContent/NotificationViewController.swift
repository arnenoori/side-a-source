import SideAProtocol
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// The long-press view for QUESTION, PLAN and the REQUEST categories (section 5.3). SwiftUI in a
/// hosting controller, sized by the content's own height. A question answers from here; a plan and
/// a request keep the category's actions below.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var host: UIHostingController<NotificationCard>?
    private var card: NotificationCardModel?

    func didReceive(_ notification: UNNotification) {
        Diagnostics.start()
        let content = notification.request.content
        // The card shows and answers only a payload this phone opened from a sealed push, never the push's own words.
        let payload = PushOpener.verified(notification.request)
        let card = NotificationCardModel(category: content.categoryIdentifier, payload: payload)
        if let actions = NotificationCategories.actions(for: payload) { extensionContext?.notificationActions = actions }
        card.onWriteOwn = { [weak self] in self?.offerTextInput() }
        card.onOpen = { [weak self] in self?.extensionContext?.performNotificationDefaultAction() }
        card.onSent = { [weak self] in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notification.request.identifier])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.extensionContext?.dismissNotificationContentExtension() }
        }
        card.onHeight = { [weak self] height in
            guard let self, preferredContentSize.height != height else { return }
            preferredContentSize = CGSize(width: view.bounds.width, height: height)
        }
        self.card = card
        let view = NotificationCard(card: card)
        if let host {
            host.rootView = view
        } else {
            let host = UIHostingController(rootView: view)
            host.sizingOptions = []
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.backgroundColor = .clear
            self.view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            ])
            host.didMove(toParent: self)
            self.host = host
        }
    }

    /// The category's buttons, while the card is up: a typed answer or one of the actions.
    func didReceive(_ response: UNNotificationResponse, completionHandler completion: @escaping (UNNotificationContentExtensionResponseOption) -> Void) {
        guard let card else { return completion(.dismissAndForwardAction) }
        if let typed = response as? UNTextInputNotificationResponse, response.actionIdentifier == NotificationCategories.Action.writeOwn {
            card.typed(typed.userText)
            completion(.doNotDismiss)
        } else if let answer = NotificationCategories.answer(for: response.actionIdentifier), card.payload != nil {
            card.send(answer)
            completion(.doNotDismiss)
        } else {
            completion(.dismissAndForwardAction)
        }
    }

    /// "Write your own…": the question's actions become one text field.
    private func offerTextInput() {
        extensionContext?.notificationActions = [
            UNTextInputNotificationAction(identifier: NotificationCategories.Action.writeOwn, title: "Write Your Own…",
                                          options: [.authenticationRequired], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"),
            UNNotificationAction(identifier: NotificationCategories.Action.open, title: "Open", options: [.foreground]),
        ]
    }
}
