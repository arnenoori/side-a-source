import Foundation
import SideACore

extension RemoteRoutes {
    static let snoozeRoutes: [Route] = [
        Route("POST", "v1/sessions/{id}/snooze", snooze),
    ]

    /// Unsigned, as a pin is: it changes where the session is listed, never what it does.
    @Sendable static func snooze(_ context: Context) async -> HTTPResponse {
        guard let body = context.body(SnoozeRequest.self) else { return badJSON }
        let id = context.params["id"] ?? ""
        let now = Date()
        if let choice = body.choice, choice != .needsMe, (body.until ?? 0) <= now.timeIntervalSince1970 {
            return RemoteServer.error(400, .badRequest, "Say when it should wake.")
        }
        return await onMain(context) { _ in
            guard let events = context.controller.events, let row = events.session(id) else { return noSession }
            let snoozes = context.controller.snoozes
            if let choice = body.choice {
                if Snoozes.refusal(row) == .failure {
                    return RemoteServer.error(409, .cannotDeliver, "It has failed or stalled, so it would wake at once. Sort that out first.")
                }
                guard snoozes.snooze(row, choice, until: body.until, now: now) != nil else {
                    return RemoteServer.error(409, .sessionWaiting, "It's asking something. Answer it first.")
                }
            } else {
                snoozes.wake(row.id)
            }
            events.liveChanged()
            return json(200, events.session(id) ?? row)
        }
    }
}
