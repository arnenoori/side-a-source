import CryptoKit
import Foundation
import SideAProtocol
import SideARemoteShared
import UserNotifications

/// What the Notification Service Extension does with a sealed push, compiled into the app too so tests
/// can run it: open it with the pairing's push key, then put the Mac's words on the notification.
enum PushOpener {
    /// The demo's payloads name this Mac.
    static let demoMac = "demo"

    enum Opened {
        case opened(PushPayload, Data)
        case noKey
        case unreadable
    }

    /// The key and device id from pairing; the AAD binds the category and collapse id APNs delivered.
    /// The sealed push doesn't say which Mac sent it, so each paired Mac's key is tried; only its own opens it.
    static func open(_ sealed: String, category: PushCategory, collapseID: String) -> Opened {
        var result = Opened.noKey
        for mac in PairedMac.all() {
            guard let stored = SharedKeychain.shared.data("pushKey.\(mac.endpoint.macID)"), stored.count == 4 + 32 else { continue }
            let key = PushKey(key: SymmetricKey(data: stored.dropFirst(4)), keyID: Data(stored.prefix(4)))
            result = open(sealed, key: key, deviceID: mac.deviceID, macID: mac.endpoint.macID, category: category, collapseID: collapseID)
            if case .opened = result { return result }
        }
        return result
    }

    /// A payload sealed for another device, category, request or Mac doesn't open.
    static func open(_ sealed: String, key: PushKey, deviceID: String, macID: String, category: PushCategory, collapseID: String) -> Opened {
        guard let data = try? PushEnvelope.open(sealed, with: key, category: category, collapseID: collapseID, deviceID: deviceID),
              let payload = try? JSONDecoder().decode(PushPayload.self, from: data),
              payload.mac == macID else { return .unreadable }
        return .opened(payload, data)
    }

    static func fill(_ content: UNMutableNotificationContent, with payload: PushPayload, data: Data, category: PushCategory,
                     identifier: String) {
        let shown = words(payload)
        content.title = shown.title
        content.subtitle = shown.subtitle
        content.body = shown.body
        // One thread per project: the subtitle reads "side-a · Work".
        content.threadIdentifier = payload.subtitle?.components(separatedBy: " · ").first ?? payload.t
        content.relevanceScore = payload.kind.asks ? 1 : 0.3
        let local = payload.kind == .request && cutOff(payload) || grouped(payload) ? PushCategory.open : category.local(for: payload)
        // Anything hidden in it needs an unlock and a look at the escapes, never the Lock Screen's Allow.
        content.categoryIdentifier = (local == .requestSafe && !allowsLocked(payload) ? PushCategory.request : local).rawValue
        var info = content.userInfo
        info.removeValue(forKey: "e")
        info["p"] = try? JSONSerialization.jsonObject(with: data)
        // Only the opened payload's ids, never ones the push carried in the clear.
        for key in ["rid", "sid", "turnID"] { info.removeValue(forKey: key) }
        if let rid = payload.rid { info["rid"] = rid }
        if let sid = payload.sid { info["sid"] = sid }
        if let turnID = payload.turnID { info["turnID"] = turnID }
        let digest = digest(data)
        info["h"] = digest
        content.userInfo = info
        // An update to a notification already shown: the Mac says it comes without a sound.
        if payload.quiet == true { content.sound = nil }
        // Only what was opened here is acted on: the app and the card look it up by the notification's id, and this
        // notification by its own payload's digest too, which a later push under the same id can't replace.
        PushCache.store(data, for: identifier)
        PushCache.store(data, for: own(identifier, digest))
        if let rid = payload.rid, rid != identifier { PushCache.store(data, for: rid) }
    }

    /// Names one opened payload: Ready reuses one notification id per Mac, so the id alone can name a later turn's.
    static func digest(_ data: Data) -> String { Data(SHA256.hash(data: data).prefix(16)).base64URL }

    private static func own(_ identifier: String, _ digest: String) -> String { identifier + "_" + digest }

    /// The payload `fill` put on this very notification: by its digest, so one that replaced the cache under the same
    /// id doesn't stand in for it; and naming the request, session and turn the notification says it's about.
    private static func opened(_ request: UNNotificationRequest) -> PushPayload? {
        let info = request.content.userInfo
        let payload = if let digest = info["h"] as? String { cached(own(request.identifier, digest)) } else { cached(request.identifier) }
        guard let payload, info["rid"] as? String == payload.rid, info["turnID"] as? String == payload.turnID,
              (info["sid"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) == payload.sid else { return nil }
        return payload
    }

    /// The payload this phone opened for a request, by its id.
    static func cached(_ id: String) -> PushPayload? {
        PushCache.load(id).flatMap { try? JSONDecoder().decode(PushPayload.self, from: $0) }
    }

    /// The payload a notification action may act on: the one this phone opened from a sealed push, never the
    /// cleartext `userInfo`, which anyone who can send a push could write. Nil when it wasn't opened here, or when the
    /// notification isn't what `fill` made of it: a later push under the same collapse id, with no `mutable-content`,
    /// replaces the words and category without the Service Extension running.
    static func verified(_ request: UNNotificationRequest) -> PushPayload? {
        let info = request.content.userInfo
        #if DEBUG
        // The demo's pushes are in the clear.
        if let p = info["p"] as? [String: Any], p["mac"] as? String == demoMac,
           let data = try? JSONSerialization.data(withJSONObject: p) { return try? JSONDecoder().decode(PushPayload.self, from: data) }
        #endif
        // A paired Mac's, or the review demo's own request ("demo"): only this app and its Service Extension write the
        // cache, and a sealed push opens only with its own Mac's id, never the demo's.
        guard let payload = opened(request), payload.mac == demoMac || PairedMac.load(payload.mac) != nil else { return nil }
        return shows(payload, on: request.content) ? payload : nil
    }

    static func shows(_ payload: PushPayload, on content: UNNotificationContent) -> Bool {
        words(payload) == Words(title: content.title, subtitle: content.subtitle, body: content.body)
            && content.categoryIdentifier == category(of: payload)
    }

    struct Words: Equatable {
        let title: String
        let subtitle: String
        let body: String
    }

    /// The only words a notification for this payload may show, on the notification and on its card.
    static func words(_ payload: PushPayload) -> Words {
        var text = body(payload)
        // A command cut to fit the push can't be allowed from here (it's OPEN): the user hasn't seen all of it.
        if payload.kind == .request, cutOff(payload) { text += "\nOpen to see the full command." }
        return Words(title: RequestText.visible(payload.title ?? defaultTitle(payload)),
                     subtitle: RequestText.visible(payload.subtitle ?? ""), body: RequestText.visible(text))
    }

    /// The card can't show all of it. Judged here too, so a Mac that says `full` for what a card would lose isn't believed.
    nonisolated static func cutOff(_ payload: PushPayload) -> Bool {
        payload.full == false || (payload.kind == .request && !RequestText.fitsCard(payload.body ?? ""))
    }

    /// Ready for more than one session: no one turn to reply to, so Open only.
    nonisolated static func grouped(_ payload: PushPayload) -> Bool { payload.kind == .finished && payload.sid == nil }

    /// Whether the Lock Screen may allow it on a locked phone: the Mac's gate says so and nothing is hidden in it.
    nonisolated static func allowsLocked(_ payload: PushPayload) -> Bool {
        payload.gate == .lockScreen && !cutOff(payload)
            && ![payload.title, payload.subtitle, payload.body].contains { $0.map(RequestText.hasEscapes) == true }
    }

    /// The category `fill` gives this payload.
    private static func category(of payload: PushPayload) -> String? {
        switch payload.kind {
        case .request:
            if cutOff(payload) { return PushCategory.open.rawValue }
            if payload.gate == .biometric { return PushCategory.requestDestructive.rawValue }
            return (allowsLocked(payload) ? PushCategory.requestSafe : PushCategory.request).rawValue
        case .question: return PushCategory.question.rawValue
        case .plan: return PushCategory.plan.rawValue
        case .finished: return (grouped(payload) ? PushCategory.open : PushCategory.finished).rawValue
        case .limit: return PushCategory.limit.rawValue
        case .health: return PushCategory.health.rawValue
        case .rotation: return PushCategory.rotation.rawValue
        case .test: return PushCategory.test.rawValue
        default: return nil
        }
    }

    /// The Mac's words couldn't be read here: say so plainly, and offer only Open.
    static func generic(_ content: UNMutableNotificationContent, body: String?) {
        content.title = "Side A"
        content.subtitle = ""
        content.body = body ?? "Open Side A Remote to see what your Mac sent."
        content.categoryIdentifier = "OPEN"
        content.userInfo.removeValue(forKey: "e")
    }

    static func defaultTitle(_ payload: PushPayload) -> String {
        switch payload.kind {
        case .question: "\(payload.agent?.title ?? "A session") has a question"
        case .plan: "Plan ready"
        case .finished: "Finished"
        case .limit: "\(payload.account ?? "An account") is at \(payload.percent ?? 0)%"
        case .health: "A session looks stuck"
        case .rotation: "Autopilot moved your sessions"
        case .test: "Notifications work"
        default: "Side A"
        }
    }

    static func body(_ payload: PushPayload) -> String {
        if cutOff(payload) { return "Open to answer." }
        switch payload.kind {
        case .question: return payload.body ?? payload.questions?.first?.question ?? ""
        case .plan: return payload.body ?? payload.plan.map { String($0.prefix(240)) } ?? ""
        case .finished: return payload.summary ?? payload.body ?? ""
        case .limit:
            let reset = payload.resetsAt.map { "Resets \(Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened))" }
            return [payload.window, reset].compactMap { $0 }.joined(separator: " · ")
        case .rotation:
            if let body = payload.body { return body }
            guard let account = payload.account else { return "" }
            return payload.resetsAt.map { "\(account) back \(Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened))" } ?? account
        default: return payload.body ?? ""
        }
    }
}
