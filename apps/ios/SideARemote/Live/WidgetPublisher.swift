import Foundation
import SideAProtocol
import SideARemoteShared
import WidgetKit

/// Keeps `snapshot.json` in step with what the app shows, and reloads the widgets only when it
/// changes. Live data refreshes `updatedAt` at least every 10 minutes, so a quiet Mac doesn't read
/// as stale on the Home Screen.
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()
    private var last: WidgetSnapshot?

    /// Every paired Mac's model, from `AppRoot`.
    var sources: () -> [AppModel] = { [] }

    /// Every Mac in one snapshot: what needs you anywhere first, then what's working.
    func refresh(now: Date = .now) {
        let macs = sources().filter { $0.isDemo || $0.mac.state == .live || !$0.sessions.sessions.isEmpty }
        guard !macs.isEmpty else { return }
        publish(WidgetSnapshot(macs, now: now), now: now)
    }

    func publish(_ model: AppModel, macID: String, now: Date = .now) {
        publish(WidgetSnapshot(model, macID: macID, now: now), now: now)
    }

    private func publish(_ fresh: WidgetSnapshot, now: Date) {
        var snapshot = fresh
        if var previous = last {
            let age = now.timeIntervalSince(previous.updatedAt)
            previous.updatedAt = snapshot.updatedAt
            if previous == snapshot && age < 600 { return }
        }
        snapshot.updatedAt = now
        last = snapshot
        try? snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Unpaired or forgotten: the widgets ask to pair rather than show a Mac that's gone.
    func clear() {
        last = nil
        WidgetSnapshot.remove()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WidgetSnapshot {
    /// Several Macs: counts add up, needs-you rows from every Mac come before working ones, and each row
    /// keeps its Mac for its link.
    init(_ macs: [AppModel], now: Date = .now) {
        let each = macs.map { WidgetSnapshot($0, macID: $0.macID, now: now) }
        guard var merged = each.first else {
            self.init(macName: "", macID: "", working: 0, waiting: 0, updatedAt: now)
            return
        }
        guard each.count > 1 else {
            self = merged
            return
        }
        let rows = each.flatMap { snapshot in snapshot.sessions.map { var row = $0; row.mac = snapshot.macID; return row } }
        merged.macName = "\(each.count) Macs"
        merged.working = each.map(\.working).reduce(0, +)
        merged.waiting = each.map(\.waiting).reduce(0, +)
        merged.top = each.lazy.compactMap(\.top).first
        merged.tightest = each.compactMap(\.tightest).max { $0.percent < $1.percent }
        merged.sessions = Array((rows.filter { $0.phase == .needsYou } + rows.filter { $0.phase == .working }).prefix(7))
        // The same account seen from two Macs shows once.
        var seen = Set<String>()
        merged.accounts = Array(each.flatMap(\.accounts).filter { seen.insert($0.id).inserted }.prefix(4))
        self = merged
    }

    init(_ model: AppModel, macID: String, now: Date = .now) {
        let open = model.requests.open
        func request(in session: RemoteSession) -> RemoteRequest? { open.first { $0.sessionID == session.id } }
        let needsYou = model.sessions.rows(.needsYou).map { session in
            Session(id: session.id, title: session.title, project: session.project, phase: .needsYou,
                    line: request(in: session)?.accessoryTitle ?? session.step, codex: session.agent == .codex)
        }
        let working = model.sessions.rows(.working).map { session in
            Session(id: session.id, title: session.title, project: session.project, phase: .working, line: session.step,
                    codex: session.agent == .codex)
        }
        let at = now.timeIntervalSince1970
        let top = open.first.map { request in
            Waiting(requestID: request.id, sessionTitle: request.sessionID.flatMap(model.sessions.session)?.title ?? request.title,
                    project: request.project ?? "", headline: RequestText.visible(request.headline), detail: RequestText.visible(request.detail),
                    destructive: request.risk == .destructive)
        }
        let tightest = model.accounts.inUse.flatMap { account in
            model.accounts.tightest(account, now: now).map { window in
                Limit(account: account.name, window: window.shortLabel, percent: window.used(at: at),
                      resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:)))
            }
        }
        self.init(macName: model.mac.name, macID: macID, working: working.count, waiting: needsYou.count, top: top,
                  tightest: tightest, sessions: Array((needsYou + working).prefix(7)),
                  accounts: model.accounts.accounts.prefix(4).map { account in
                      Account(id: account.id, name: account.name, fiveHour: account.usage?.fiveHour?.used(at: at),
                              weekly: account.usage?.weekly?.used(at: at), active: account.active)
                  },
                  updatedAt: now)
    }
}
