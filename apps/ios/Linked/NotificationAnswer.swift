import Foundation
import SideAProtocol
import SideARemoteKit
import SideARemoteShared
import UserNotifications

// Compiled into the app and the Notification Content Extension: the packages link statically, so
// each binary carries its own copy rather than sharing one through the framework.

/// Answers from a notification, without the app running: the same outbox item the app would make
/// (`<requestID>:<kind>`, so a second tap is a replay), then one try straight away. What doesn't
/// get through stays queued for the app's engine.
enum NotificationAnswer {
    enum Result: Equatable {
        case sent
        case answeredElsewhere
        /// Still in the outbox; the app sends it when it reaches the Mac.
        case queued(mac: String)
        case failed(String)
        /// No paired Mac matches the payload's.
        case noMac

        /// The request is settled, or will be once the outbox sends it. A refused answer leaves it waiting on the Mac,
        /// so its notification and Live Activity row stay to answer it another way.
        nonisolated var settles: Bool {
            switch self {
            case .sent, .answeredElsewhere, .queued: true
            case .failed, .noMac: false
            }
        }
    }

    /// The demo's payloads name this Mac; answering them only pretends.
    static let demoMac = "demo"

    static func send(_ answer: RemoteAnswer, to request: RequestID, macID: String) async -> Result {
        let body = (try? encoder.encode(AnswerBody(answer: answer))) ?? Data()
        // Signed with the unlock key, which works only while the phone is unlocked: a Lock Screen allow goes unsigned,
        // and the Mac takes it only if the request's gate is the Lock Screen.
        var confirm: String?
        if let mac = PairedMac.load(macID), let subject = try? ConfirmMessage.subject(requestID: request, answer: answer) {
            confirm = await DeviceKeys.header(.unlock, macID: macID, deviceID: mac.deviceID, purpose: .allow, subject: subject,
                                            fromNotification: true)
        }
        return await post(id: "\(request):\(answer.kind.rawValue)", path: "/v1/requests/\(request)/answer", body: body,
                          macID: macID, lifetime: 86_400, confirm: confirm)
    }

    /// FINISHED's Reply: a follow-up to the turn the push named.
    static func reply(_ text: String, to session: SessionKey, turnID: String?, macID: String) async -> Result {
        let reply = RemoteReply(text: text, turnID: turnID)
        let body = (try? encoder.encode(reply)) ?? Data()
        // The Reply action unlocks the phone first, so the unlock key signs. A session the Mac wants Face ID for refuses it,
        // and the app, which can ask, is where that reply goes.
        var confirm: String?
        if let mac = PairedMac.load(macID), let subject = try? ConfirmMessage.subject(action: .reply, target: session, body: reply) {
            confirm = await DeviceKeys.header(.unlock, macID: macID, deviceID: mac.deviceID, purpose: .action, subject: subject)
        }
        return await post(id: UUID().uuidString.lowercased(), path: "/v1/sessions/\(session)/reply", body: body,
                          macID: macID, lifetime: 600, confirm: confirm)
    }

    /// The engine's encoding, so a replayed key carries the same bytes.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func post(id: String, path: String, body: Data, macID: String, lifetime: Double, confirm: String? = nil) async -> Result {
        if macID == demoMac {
            try? await Task.sleep(for: .milliseconds(400))
            return .sent
        }
        guard let mac = PairedMac.load(macID),
              let file = SharedStorage.database, let outbox = try? Outbox(file: file) else { return .noMac }
        let now = Date.now.timeIntervalSince1970
        let item = Outbox.Item(id: id, macID: macID, path: path, body: body, createdAt: now, expiresAt: now + lifetime, confirm: confirm)
        await outbox.enqueue(item)
        let client = RemoteClient(endpoint: mac.endpoint, credentials: KeychainCredentials())
        do {
            var request = try await client.request("POST", path, body: body, idempotencyKey: id)
            if let confirm { request.setValue(confirm, forHTTPHeaderField: ConfirmSignature.header) }
            _ = try await client.send(request)
            await outbox.remove(id)
            return .sent
        } catch let failure as RemoteFailure where !failure.error.retryable {
            await outbox.remove(id)
            return failure.error.code == .alreadyResolved ? .answeredElsewhere : .failed(failure.error.message)
        } catch {
            return .queued(mac: mac.endpoint.name)
        }
    }
}

extension PushPayload {
    /// The decrypted payload, which the Service Extension puts in the notification's `userInfo`
    /// under `p`. The demo's pushes carry it there in the clear.
    init?(userInfo: [AnyHashable: Any]) {
        guard let object = userInfo["p"], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let payload = try? JSONDecoder().decode(PushPayload.self, from: data) else { return nil }
        self = payload
    }
}

/// The local categories (section 5.1). Actions that change something on the Mac need unlock, except
/// `REQUEST_SAFE`'s Allow.
enum NotificationCategories {
    enum Action {
        static let allow = "ALLOW"
        static let deny = "DENY"
        static let open = "OPEN"
        static let approve = "APPROVE"
        static let approveEdits = "APPROVE_EDITS"
        static let reply = "REPLY"
        /// The Content Extension's "Write your own…", swapped in for the question's actions.
        static let writeOwn = "WRITE_OWN"
    }

    /// What a card offers in place of the category's buttons: a push that wasn't opened here gets Open, whatever
    /// category it named. Nil keeps the category's.
    static func actions(for payload: PushPayload?) -> [UNNotificationAction]? {
        payload == nil ? [UNNotificationAction(identifier: Action.open, title: "Open", options: [.foreground])] : nil
    }

    static func register(_ center: UNUserNotificationCenter = .current()) {
        let open = UNNotificationAction(identifier: Action.open, title: "Open", options: [.foreground])
        let deny = UNNotificationAction(identifier: Action.deny, title: "Deny", options: [.destructive])
        let allow = UNNotificationAction(identifier: Action.allow, title: "Allow", options: [.authenticationRequired])
        let allowSafe = UNNotificationAction(identifier: Action.allow, title: "Allow", options: [])
        let approve = UNNotificationAction(identifier: Action.approve, title: "Approve", options: [.authenticationRequired])
        let approveEdits = UNNotificationAction(identifier: Action.approveEdits, title: "Approve + Accept Edits", options: [.authenticationRequired])
        let reply = UNTextInputNotificationAction(identifier: Action.reply, title: "Reply", options: [.authenticationRequired],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Follow up…")
        func category(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
        }
        center.setNotificationCategories([
            category("REQUEST_SAFE", [allowSafe, deny, open]),
            category("REQUEST", [allow, deny, open]),
            category("REQUEST_DESTRUCTIVE", [deny, open]),
            category("QUESTION", [open]),
            category("PLAN", [approve, approveEdits, open]),
            category("FINISHED", [reply, open]),
            category("LIMIT", [open]),
            category("HEALTH", [open]),
            category("ROTATION", [open]),
            category("TEST", []),
            category("ANSWERED", []),
            // The Service Extension's fallback when it couldn't read the Mac's words.
            category("OPEN", [open]),
        ])
    }

    /// The answer an action stands for; nil for Open and the default tap.
    static func answer(for action: String) -> RemoteAnswer? {
        switch action {
        case Action.allow: .allow(confirmDestructive: false)
        case Action.deny: .deny(message: nil)
        case Action.approve: .approvePlan(acceptEdits: false)
        case Action.approveEdits: .approvePlan(acceptEdits: true)
        default: nil
        }
    }
}

/// A request's notification goes once it's answered anywhere: here, on the Mac, or on another
/// device. Its id is the push's collapse id, so it names the delivered notification.
enum DeliveredRequests {
    static func clear(_ ids: [RequestID]) {
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        for id in ids { PushCache.remove(id) }
    }

    struct Delivered: Equatable {
        let id: String
        let category: String
        let payload: PushPayload?
        let date: Date
    }

    /// What a request's notification can be called: the sealed categories, the Open-only fallback, and the
    /// "Couldn't reach" one put in its place, which has no category but keeps the payload.
    static let categories: Set<String> = ["REQUEST", "REQUEST_SAFE", "REQUEST_DESTRUCTIVE", "QUESTION", "PLAN", "OPEN"]

    /// Request notifications still up for requests this Mac no longer has open: the "Answered" push never came (the
    /// relay was down, the phone was off), or the Mac quit with them waiting. Only ones delivered before `asked`, when
    /// the open list was read, so a request that arrived since is never taken for gone. One whose Mac can't be told
    /// (Open only, no payload) counts only when this is the one paired Mac.
    static func stale(_ delivered: [Delivered], mac: String, open: Set<RequestID>, asked: Date, onlyMac: Bool) -> [String] {
        delivered.compactMap { note in
            guard note.date < asked else { return nil }
            let request: RequestID
            if let payload = note.payload, ["request", "question", "plan"].contains(payload.t), let rid = payload.rid {
                guard payload.mac == mac else { return nil }
                request = rid
            } else if note.payload == nil, categories.contains(note.category), onlyMac {
                request = note.id
            } else {
                return nil
            }
            return open.contains(request) ? nil : note.id
        }
    }

    static func sweep(mac: String, open: Set<RequestID>, asked: Date, onlyMac: Bool) async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications().map { note in
            Delivered(id: note.request.identifier, category: note.request.content.categoryIdentifier,
                      payload: PushPayload(userInfo: note.request.content.userInfo), date: note.date)
        }
        let gone = stale(delivered, mac: mac, open: open, asked: asked, onlyMac: onlyMac)
        if !gone.isEmpty { RemoteLog.log(.push, "cleared \(gone.count) notifications for requests no longer open") }
        clear(gone)
    }
}
