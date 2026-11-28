import SideAProtocol
import SwiftUI

extension SessionStore {
    /// The limit a running conversation is stopped on, while it still holds.
    func limit(of id: String) -> SessionLimit? {
        _ = desk.limitTick
        return store.sessionLimits(now: Date().timeIntervalSince1970)[id]
    }

    func continues(_ id: String) -> Bool {
        _ = desk.limitTick
        return store.continues(id)
    }

    func setContinues(_ id: String, _ on: Bool) {
        store.setContinues(id, on)
        desk.limitTick += 1
    }

    func limitText(_ session: LiveSession) -> String? {
        guard session.status != "busy", let id = session.sessionID, let limit = limit(of: id) else { return nil }
        return Self.limitText(limit, continues: continues(id))
    }

    /// "Limited · continues 3:40 PM", or "Limited until 3:40 PM" for a session that waits for the user. A reset known
    /// only as the longest it could take says "by".
    static func limitText(_ limit: SessionLimit, continues: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let until = limit.until else { return continues ? "Limited · continues at reset" : "Limited" }
        let at = Date(timeIntervalSince1970: until)
        let time = at.formatted(date: .omitted, time: .shortened)
        let when = calendar.isDate(at, inSameDayAs: now) ? time : "\(at.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        if continues { return "Limited · continues \(limit.worstCase ? "by " : "")\(when)" }
        return limit.worstCase ? "Limited until \(when) at the latest" : "Limited until \(when)"
    }
}

/// A limit-stopped row's menu item: whether Side A sends the session on when the limit lifts.
struct LimitItems: View {
    let model: SessionStore
    let session: LiveSession
    var body: some View {
        if let id = session.sessionID, model.store.config.continueStopped != false, model.limit(of: id) != nil {
            let on = model.continues(id)
            Button(on ? "Don't Continue at Reset" : "Continue at Reset") { model.setContinues(id, !on) }
        }
    }
}

/// Above the composer of a conversation a limit stopped: when it goes on, and the choice not to.
struct LimitBanner: View {
    let model: SessionStore
    let session: LiveSession
    var body: some View {
        if let id = session.sessionID, let text = model.limitText(session) {
            let on = model.continues(id)
            HStack(spacing: 8) {
                Image(systemName: "hourglass").foregroundStyle(.orange)
                Text(text).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if model.store.config.continueStopped != false {
                    Button(on ? "Don't Continue" : "Continue at Reset") { model.setContinues(id, !on) }
                        .buttonStyle(.link).font(.callout)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }
}
