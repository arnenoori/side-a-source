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
        /// Only the app sends it, once it is next opened and reaches the Mac: nothing runs a notification's work later.
        case held(mac: String)
        /// Kept in the app (a reply in the session's field, an answer on its question), with why it didn't go.
        case kept(String)
        case failed(String)
        /// No paired Mac matches the payload's.
        case noMac

        /// The request is settled, or will be once the outbox sends it. A refused answer leaves it waiting on the Mac,
        /// so its notification and Live Activity row stay to answer it another way.
        nonisolated var settles: Bool {
            switch self {
            case .sent, .answeredElsewhere, .queued, .held: true
            case .kept, .failed, .noMac: false
            }
        }
    }

    /// The demo's payloads name this Mac; answering them only pretends.
    static let demoMac = PushOpener.demoMac

    /// `typed`: words the person wrote into the answer, kept on the question if it can't be sent now.
    static func send(_ answer: RemoteAnswer, to request: RequestID, macID: String, typed: (text: String, session: SessionKey)? = nil) async -> Result {
        // Signed with the unlock key, which works only while the phone is unlocked: a Lock Screen allow goes unsigned,
        // and the Mac takes it only if the request's gate is the Lock Screen.
        var confirm: String?
        if let mac = PairedMac.load(macID), let subject = try? ConfirmMessage.subject(requestID: request, answer: answer) {
            confirm = await mac.sign(.unlock, purpose: .allow, subject: subject, fromNotification: true)
        }
        let item = item(answer, to: request, macID: macID, now: Date.now.timeIntervalSince1970, confirm: confirm)
        let result = await post(item)
        guard let typed, !typed.text.isEmpty else { return result }
        switch result {
        // Its signature lasts two minutes, so a queued answer would be refused unless the app sent it soon. The app's
        // engine may be sending it right now, though: then it goes from there, and keeping the words too could send them twice.
        case .queued(let mac):
            guard await outbox()?.withdraw(item.id, now: Date.now.timeIntervalSince1970) == true else { return result }
            NotificationDrafts.keepAnswer(typed.text, request: request, session: typed.session, mac: macID)
            return .kept("Couldn't reach \(mac). Your answer waits on the question in Side A Remote: open it to send.")
        case .failed(let message):
            NotificationDrafts.keepAnswer(typed.text, request: request, session: typed.session, mac: macID)
            return .kept("\(message) Your answer waits on the question in Side A Remote.")
        default:
            return result
        }
    }

    private static func outbox() -> Outbox? { SharedStorage.database.flatMap { try? Outbox(file: $0) } }

    /// The outbox item the app's engine makes for the same answer, so a tap in the app after this one is a replay.
    static func item(_ answer: RemoteAnswer, to request: RequestID, macID: String, now: Timestamp, confirm: String?) -> Outbox.Item {
        .answer(request, answer, macID: macID, now: now, confirm: confirm)
    }

    /// FINISHED's Reply: a follow-up to the turn the push named.
    static func reply(_ text: String, to session: SessionKey, turnID: String?, macID: String) async -> Result {
        if macID == demoMac { return await post(.reply(session, RemoteReply(text: text), macID: macID, now: 0)) }
        guard let mac = PairedMac.load(macID), let outbox = outbox() else { return .noMac }
        var reply = RemoteReply(text: text, turnID: turnID)
        // The push's turn is the finished turn's id, one of `ReplyMark.marks`. The flight keeps this body, so a held
        // reply goes again with the `seen` it was signed with.
        if mac.capabilities?.contains(.repliesSeen) == true { reply.seen = turnID }
        // The Reply action unlocks the phone first, so the unlock key signs. A session the Mac wants Face ID for refuses
        // it, and the app, which can ask, is where that reply goes.
        var confirm: String?
        if let subject = try? ConfirmMessage.subject(action: .reply, target: session, body: reply) {
            confirm = await mac.sign(.unlock, purpose: .action, subject: subject)
        }
        let now = Date.now.timeIntervalSince1970
        let item = Outbox.Item.reply(session, reply, macID: macID, now: now, confirm: confirm)
        // If this process ends before the Mac answers, the flight lets the app settle it as one of its own.
        let flight = ReplyFlight(session: session, turn: UUID().uuidString.lowercased(), body: reply, at: now, phase: .queued(resigned: false),
                                 since: turnID, queuedAt: now)
        let saved = (try? await outbox.enqueue(item)) != nil
        if saved { await outbox.setFlight(flight, item: item.id, mac: macID) }
        let client = RemoteClient(endpoint: mac.endpoint, credentials: KeychainCredentials())
        do {
            var request = try await client.request(item.method, item.path, body: item.body, idempotencyKey: item.id)
            if let confirm { request.setValue(confirm, forHTTPHeaderField: ConfirmSignature.header) }
            _ = try await client.send(request)
            await settle(item, in: outbox)
            return .sent
        } catch let failure as RemoteFailure where failure.error.code == .outcomeUnknown && saved {
            // It may have been typed: a Retry under its key is answered from the first if so, where a draft would go again.
            await outbox.remove(item.id)
            var unsent = flight
            unsent.move(.unsent(reason: "\(mac.endpoint.kind.sentenceThe(mac.endpoint.name)) may not have it."))
            await outbox.setFlight(unsent, item: item.id, mac: macID)
            return .kept("\(mac.endpoint.name) couldn't say whether it got your reply. Open Side A Remote to check, then retry it.")
        } catch let failure as RemoteFailure where !failure.error.retryable {
            await settle(item, in: outbox)
            NotificationDrafts.keep(text, session: session, mac: macID)
            if failure.error.confirmLevel == .biometric { return .kept("This session needs Face ID for a reply. Tap to confirm and send yours.") }
            return .kept("\(failure.error.message) Your reply is in Side A Remote.")
        } catch {
            // A signature lasts two minutes and the Mac may be back much later, so it waits unsigned, unless the app's
            // engine is already sending it.
            guard await outbox.withdraw(item.id, now: Date.now.timeIntervalSince1970) else {
                guard saved else {
                    NotificationDrafts.keep(text, session: session, mac: macID)
                    return .kept("Couldn't reach \(mac.endpoint.name). Your reply is in Side A Remote: open it to send.")
                }
                return .queued(mac: mac.endpoint.name)
            }
            // Posted, so perhaps typed: it goes again only as it went, under this key, which the Mac replays if it landed.
            var waiting = flight
            waiting.move(.unanswered)
            waiting.key = item.id
            await outbox.setFlight(waiting, item: item.id, mac: macID)
            return .held(mac: mac.endpoint.name)
        }
    }

    private static func settle(_ item: Outbox.Item, in outbox: Outbox) async {
        await outbox.remove(item.id)
        await outbox.setFlight(nil, item: item.id, mac: item.macID)
    }

    private static func post(_ item: Outbox.Item) async -> Result {
        if item.macID == demoMac {
            try? await Task.sleep(for: .milliseconds(400))
            return .sent
        }
        guard let mac = PairedMac.load(item.macID),
              let file = SharedStorage.database, let outbox = try? Outbox(file: file) else { return .noMac }
        // Unsaved, it can still go now; but if that fails too it is in no queue, and saying "queued" would be false.
        let saved = (try? await outbox.enqueue(item)) != nil
        let client = RemoteClient(endpoint: mac.endpoint, credentials: KeychainCredentials())
        do {
            var request = try await client.request(item.method, item.path, body: item.body, idempotencyKey: item.id)
            if let confirm = item.confirm { request.setValue(confirm, forHTTPHeaderField: ConfirmSignature.header) }
            _ = try await client.send(request)
            await outbox.remove(item.id)
            return .sent
        } catch let failure as RemoteFailure where !failure.error.retryable {
            await outbox.remove(item.id)
            return failure.error.code == .alreadyResolved ? .answeredElsewhere : .failed(failure.error.message)
        } catch {
            return saved ? .queued(mac: mac.endpoint.name) : .failed("Couldn't send it. Open Side A Remote to try again.")
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

/// The local categories. Actions that change something on the Mac need unlock, except
/// `REQUEST_SAFE`'s Allow.
enum NotificationCategories {
    enum Action {
        static let allow = "ALLOW"
        static let deny = "DENY"
        static let open = "OPEN"
        static let approve = "APPROVE"
        static let approveEdits = "APPROVE_EDITS"
        static let reply = "REPLY"
        /// A single question's typed answer.
        static let answer = "ANSWER"
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
        // A notification can't ask for Face ID, so this reply opens the app with the text in the field, where it can.
        let replyInApp = UNTextInputNotificationAction(identifier: Action.reply, title: "Reply", options: [.foreground],
                                                       textInputButtonTitle: "Next", textInputPlaceholder: "Follow up, then confirm in the app…")
        let answer = UNTextInputNotificationAction(identifier: Action.answer, title: "Answer", options: [.authenticationRequired],
                                                   textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        func category(_ id: PushCategory, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id.rawValue, actions: actions, intentIdentifiers: [], options: [])
        }
        center.setNotificationCategories([
            category(.requestSafe, [allowSafe, deny, open]),
            category(.request, [allow, deny, open]),
            category(.requestDestructive, [deny, open]),
            category(.question, [answer, open]),
            category(.questionOpen, [open]),
            category(.plan, [approve, approveEdits, open]),
            category(.finished, [reply, open]),
            category(.finishedFaceID, [replyInApp, open]),
            category(.limit, [open]),
            category(.health, [open]),
            category(.rotation, [open]),
            category(.macQuiet, [open]),
            category(.test, []),
            category(.answered, []),
            // The Service Extension's fallback when it couldn't read the Mac's words.
            category(.open, [open]),
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
    static let categories: Set<String> = ["REQUEST", "REQUEST_SAFE", "REQUEST_DESTRUCTIVE", "QUESTION", "QUESTION_OPEN", "PLAN", "OPEN"]

    /// Request notifications still up for requests this Mac no longer has open: the "Answered" push never came (the
    /// relay was down, the phone was off), or the Mac quit with them waiting. Only ones delivered before `asked`, when
    /// the open list was read, so a request that arrived since is never taken for gone. One whose Mac can't be told
    /// (Open only, no payload) counts only when this is the one paired Mac.
    /// `finished`, each finished session's turn when the snapshot is in: a Finished notification for a turn no longer
    /// there is stale too, and so is "Answered", which only stands where something was cleared.
    /// Nil `open` leaves request notifications alone.
    static func stale(_ delivered: [Delivered], mac: String, open: Set<RequestID>?, asked: Date, onlyMac: Bool,
                      finished: [SessionKey: String]? = nil) -> [String] {
        delivered.compactMap { note in
            guard note.date < asked else { return nil }
            if let finished {
                if note.category == PushCategory.answered.rawValue { return note.id }
                if let payload = note.payload, payload.kind == .finished, payload.mac == mac {
                    guard let sid = payload.sid else { return finished.isEmpty ? note.id : nil }
                    return finished[sid] == payload.turnID ? nil : note.id
                }
            }
            guard let open else { return nil }
            let request: RequestID
            if let payload = note.payload, payload.kind.asks, let rid = payload.rid {
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

    static func sweep(mac: String, open: Set<RequestID>?, asked: Date, onlyMac: Bool, finished: [SessionKey: String]? = nil) async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications().map { note in
            Delivered(id: note.request.identifier, category: note.request.content.categoryIdentifier,
                      payload: PushPayload(userInfo: note.request.content.userInfo), date: note.date)
        }
        let gone = stale(delivered, mac: mac, open: open, asked: asked, onlyMac: onlyMac, finished: finished)
        if !gone.isEmpty { RemoteLog.log(.push, "cleared \(gone.count) notifications for requests or turns no longer open") }
        clear(gone)
    }
}

/// Words typed into a notification that couldn't go from there, for the session's field. In the App Group: the Content
/// Extension keeps them too.
enum NotificationDrafts {
    private static let key = "notificationDrafts"
    nonisolated(unsafe) private static let store = UserDefaults(suiteName: SharedStorage.appGroup) ?? .standard

    static func keep(_ text: String, session: SessionKey, mac: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var all = store.dictionary(forKey: key) as? [String: String] ?? [:]
        let id = mac + "\n" + session
        all[id] = joined(all[id], text)
        store.set(all, forKey: key)
    }

    static func take(mac: String) -> [SessionKey: String] {
        var all = store.dictionary(forKey: key) as? [String: String] ?? [:]
        var taken: [SessionKey: String] = [:]
        for (id, text) in all {
            let parts = id.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == mac else { continue }
            taken[parts[1]] = text
            all[id] = nil
        }
        if !taken.isEmpty { store.set(all, forKey: key) }
        return taken
    }

    // A question's typed answer is kept against its request, not the session: in the session's field it would go as a
    // reply once the question is gone, and leave the question open.
    private static let answersKey = "notificationAnswers"

    struct KeptAnswer: Equatable {
        let request: RequestID
        let session: SessionKey
        let text: String
    }

    static func keepAnswer(_ text: String, request: RequestID, session: SessionKey, mac: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var all = store.dictionary(forKey: answersKey) as? [String: [String: String]] ?? [:]
        let id = mac + "\n" + request
        all[id] = ["session": session, "text": joined(all[id]?["text"], text)]
        store.set(all, forKey: answersKey)
    }

    static func answers(mac: String) -> [KeptAnswer] {
        let all = store.dictionary(forKey: answersKey) as? [String: [String: String]] ?? [:]
        return all.compactMap { id, kept in
            let parts = id.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == mac, let session = kept["session"], let text = kept["text"] else { return nil }
            return KeptAnswer(request: parts[1], session: session, text: text)
        }
    }

    static func dropAnswer(_ request: RequestID, mac: String) {
        var all = store.dictionary(forKey: answersKey) as? [String: [String: String]] ?? [:]
        guard all.removeValue(forKey: mac + "\n" + request) != nil else { return }
        store.set(all, forKey: answersKey)
    }

    static func joined(_ earlier: String?, _ text: String) -> String {
        guard let earlier = earlier?.trimmingCharacters(in: .whitespacesAndNewlines), !earlier.isEmpty, earlier != text else { return text }
        return earlier + "\n\n" + text
    }
}
