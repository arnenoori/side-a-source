import Foundation
import SideAProtocol

/// What goes inside a push (protocol's Push payloads): the words the notification shows, filled to at most 2,048 bytes
/// before sealing. A request's detail is cut to fit; questions or a plan that don't fit whole go without, `full: false`,
/// so nobody answers what they couldn't see. A request whose detail was cut, or runs past what a card shows, goes
/// `full: false` too, and the phone offers only Open for it. So does every edit and patch: a card can't show a diff.
public enum RemotePushPayload {
    public static func request(_ request: RemoteRequest, mac: String, now: Timestamp) -> (category: PushCategory, payload: PushPayload) {
        let subtitle = [request.project, request.accountName].compactMap { $0 }.joined(separator: " · ")
        func payload(_ kind: PushKind, body: String?, questions: [IslandQuestion]? = nil, plan: String? = nil, full: Bool? = nil) -> PushPayload {
            PushPayload(t: kind.rawValue, mac: mac, sent: now, rid: request.id, sid: request.sessionID, title: request.headline,
                        subtitle: subtitle.isEmpty ? nil : subtitle, body: body, gate: kind == .request ? request.allowGate : nil,
                        risk: request.risk, riskReason: request.riskReason, agent: request.agent, questions: questions, plan: plan, full: full)
        }
        switch request.action {
        case .question(let questions):
            let whole = payload(.question, body: nil, questions: questions, full: true)
            return (.question, fits(whole) ? whole : payload(.question, body: nil, full: false))
        case .plan(let plan):
            let whole = payload(.plan, body: nil, plan: plan, full: true)
            return (.plan, fits(whole) ? whole : payload(.plan, body: nil, full: false))
        default:
            let category: PushCategory = request.allowGate == .biometric ? .requestDestructive : .request
            let made = cut(request.detail) { payload(.request, body: $0) }
            let diff: Bool
            switch request.action {
            case .edit, .write, .patch: diff = true
            default: diff = false
            }
            guard diff || made.body != request.detail || request.truncated || !fitsCard(request.detail ?? "") else { return (category, made) }
            return (category, cut(request.detail) { payload(.request, body: $0, full: false) })
        }
    }

    public static func finished(_ finished: FinishedSession, mac: String, now: Timestamp, quiet: Bool = false) -> PushPayload {
        cut(finished.summary) {
            PushPayload(t: PushKind.finished.rawValue, mac: mac, sent: now, sid: finished.sessionID, title: finished.title, turnID: finished.turnID,
                        summary: $0, quiet: quiet ? true : nil)
        }
    }

    /// The Mac's one Ready notification: a single session reads as its own finished turn, more as a count and their names,
    /// newest first. No session or turn, so it offers Open only.
    public static func ready(_ sessions: [FinishedSession], mac: String, now: Timestamp, quiet: Bool) -> PushPayload {
        if sessions.count == 1, let only = sessions.first { return finished(only, mac: mac, now: now, quiet: quiet) }
        var names: [String] = []
        for session in sessions where !names.contains(session.title) { names.append(session.title) }
        return cut(names.joined(separator: ", ")) {
            PushPayload(t: PushKind.finished.rawValue, mac: mac, sent: now, title: "\(sessions.count) sessions ready", body: $0, quiet: quiet ? true : nil)
        }
    }

    /// A health flag that just started on a session.
    public static func health(_ session: RemoteSession, flag: SessionFlag, mac: String, now: Timestamp) -> PushPayload {
        cut(flag.text) { PushPayload(t: PushKind.health.rawValue, mac: mac, sent: now, sid: session.id, title: session.title, body: $0, agent: session.agent) }
    }

    /// In health's words, which every phone can show.
    public static func queuedDropped(session: SessionKey, title: String?, text: String, mac: String, now: Timestamp) -> PushPayload {
        cut("Didn't send: \u{201C}\(text)\u{201D}") { PushPayload(t: PushKind.health.rawValue, mac: mac, sent: now, sid: session, title: title, body: $0) }
    }

    public static func limit(_ account: RemoteAccount, window: UsageWindow, mac: String, now: Timestamp) -> PushPayload {
        PushPayload(t: PushKind.limit.rawValue, mac: mac, sent: now, title: account.name, account: account.name, window: window.label,
                    percent: min(max(Int(window.percent.rounded()), 0), 100), resetsAt: window.resetsAt)
    }

    /// What Autopilot did, in account names and a limit's numbers. Never a session's title or words.
    public static func rotation(title: String, body: String?, account: String?, resetsAt: Timestamp?, mac: String, now: Timestamp) -> PushPayload {
        PushPayload(t: PushKind.rotation.rawValue, mac: mac, sent: now, title: title, body: body, account: account, resetsAt: resetsAt)
    }

    public static func test(mac: String, name: String, now: Timestamp) -> PushPayload {
        PushPayload(t: PushKind.test.rawValue, mac: mac, sent: now, title: "Side A Remote", body: "Test notification from \(name).")
    }

    public static func encoded(_ payload: PushPayload) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(payload)) ?? Data()
    }

    /// The most lines a notification card shows of a request's detail.
    public static let cardLines = 8
    /// About what fits across one, so a long line counts as the lines it wraps to.
    static let cardColumns = 40

    /// A card shows all of it, and nothing in it is laid out to be missed.
    static func fitsCard(_ text: String) -> Bool {
        guard !DisplayText.suspicious(text) else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, ($1.count + cardColumns - 1) / cardColumns) }
        return lines <= cardLines
    }

    static func fits(_ payload: PushPayload) -> Bool { encoded(payload).count <= PushPayload.budget }

    /// The longest prefix of `text` (whole characters, an ellipsis when cut) whose payload fits.
    static func cut(_ text: String?, _ make: (String?) -> PushPayload) -> PushPayload {
        guard let text, !fits(make(text)) else { return make(text) }
        var low = 0, high = text.count
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(make(String(text.prefix(middle)) + "…")) { low = middle } else { high = middle - 1 }
        }
        return make(low == 0 ? nil : String(text.prefix(low)) + "…")
    }
}
