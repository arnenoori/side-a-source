import Foundation
import SideACore
import SideAProtocol

/// Explaining and steering rotation from the phone. What changes rotation is signed by the confirm key after Face ID:
/// the server has checked the token, and the signature here binds this device, this Mac, and the exact change.
extension RemoteRoutes {
    static let rotationRoutes: [Route] = [
        Route("GET", "v1/usage/outlook", outlook),
        Route("POST", "v1/accounts/{id}/priority", setPriority),
        Route("POST", "v1/accounts/{id}/auto", setAuto),
        Route("POST", "v1/rotation/swap-at", setSwapAt),
        Route("POST", "v1/rotation/follow-fable", setFollowFable),
        Route("POST", "v1/rotation/pool", refusePool),
    ]

    /// Checks only: the caller has already refused a body it can't act on, so a good signature is never spent on one.
    private static func rotationRefusal(_ context: Context, subject: String) async -> HTTPResponse? {
        await refusal(context, .rotation, subject: subject, needs: .biometric)
    }

    private static func account(_ context: Context, _ id: String) async -> Bool {
        await MainActor.run { context.controller.store?.config.accounts.contains { $0.id == id } == true }
    }

    private static let noAccount = RemoteServer.error(404, "not_found", "That account isn't on the Mac.")

    @Sendable static func setPriority(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        guard let change = context.body(PriorityChange.self), let priority = AccountPriority(rawValue: change.priority.rawValue) else {
            return RemoteServer.error(400, "bad_request", "Send priority: first, normal or last.")
        }
        guard await account(context, id), let subject = try? ConfirmMessage.subject(account: id, priority: change.priority) else { return noAccount }
        if let refusal = await rotationRefusal(context, subject: subject) { return refusal }
        let changed = await MainActor.run { () -> Bool in
            guard let store = context.controller.store, let account = store.config.accounts.first(where: { $0.id == id }) else { return false }
            store.setPriority(id, priority)
            store.autopilotLog.write("\(account.name): priority set to \(priority.title) from the phone.")
            return true
        }
        return changed ? await accounts(context) : noAccount
    }

    @Sendable static func setAuto(_ context: Context) async -> HTTPResponse {
        let id = context.params["id"] ?? ""
        guard let change = context.body(AutopilotChange.self) else { return RemoteServer.error(400, "bad_request", "Send enabled, true or false.") }
        guard await account(context, id), let subject = try? ConfirmMessage.subject(account: id, auto: change.enabled) else { return noAccount }
        if let refusal = await rotationRefusal(context, subject: subject) { return refusal }
        let changed = await MainActor.run { () -> Bool in
            guard let store = context.controller.store, let account = store.config.accounts.first(where: { $0.id == id }) else { return false }
            store.setAuto(id, change.enabled)
            store.autopilotLog.write("\(account.name): Autopilot \(change.enabled ? "on" : "off") for this account, from the phone.")
            return true
        }
        return changed ? await accounts(context) : noAccount
    }

    @Sendable static func setSwapAt(_ context: Context) async -> HTTPResponse {
        guard let change = context.body(SwapAtChange.self), SwapAtChange.choices.contains(change.percent) else {
            return RemoteServer.error(400, "bad_request", "Send percent, one of \(SwapAtChange.choices.map(String.init).joined(separator: ", ")).")
        }
        if let refusal = await rotationRefusal(context, subject: ConfirmMessage.subject(swapAt: change.percent)) { return refusal }
        await MainActor.run {
            context.controller.store?.setSwapAt(Double(change.percent))
            context.controller.store?.autopilotLog.write("Move at set to \(change.percent)% from the phone.")
        }
        return await autopilot(context)
    }

    @Sendable static func setFollowFable(_ context: Context) async -> HTTPResponse {
        guard let change = context.body(AutopilotChange.self) else { return RemoteServer.error(400, "bad_request", "Send enabled, true or false.") }
        if let refusal = await rotationRefusal(context, subject: ConfirmMessage.subject(followFable: change.enabled)) { return refusal }
        await MainActor.run {
            context.controller.store?.setFollowFable(change.enabled)
            context.controller.store?.autopilotLog.write("Follow Fable \(change.enabled ? "on" : "off") from the phone.")
        }
        return await autopilot(context)
    }

    /// Pool mode changes where every `claude` command in Terminal sends its token, so it changes only on the Mac, whatever is signed.
    @Sendable static func refusePool(_ context: Context) async -> HTTPResponse {
        RemoteServer.error(409, "cannot_deliver", "Pool mode only changes on your Mac.", details: ["hint": "poolOnMac"])
    }

    /// Read-only, like the account list it sums up.
    @Sendable static func outlook(_ context: Context) async -> HTTPResponse {
        await onMain(context) { store in json(200, RotationOutlook.build(store, now: Date().timeIntervalSince1970)) }
    }
}

enum RotationOutlook {
    /// As Settings sums up a pool: every account Autopilot may use, through Fable's cap while it follows Fable. Only
    /// Claude has the activity the weekly rhythm comes from, so Codex shows no date.
    @MainActor static func build(_ store: AccountStore, now: Double) -> UsageOutlook {
        let rooms = AgentProvider.allCases.compactMap { provider -> UsageOutlook.Room? in
            let members = store.config.accounts.filter { $0.provider == provider && $0.ready && $0.allowAuto }
            guard let room = PoolRoom(members, usage: provider == .claude ? store.planning(store.usage) : store.usage, full: store.config.moveAt, now: now) else { return nil }
            let trusted = provider == .claude && members.allSatisfy { store.health[$0.id] == nil && store.isFresh($0.id, now: now) }
            let rhythm = trusted ? store.report.flatMap { WeekRhythm($0.activity) } : nil
            let runsOut = CombinedRunOut.estimate(members, usage: store.usage, rhythm: rhythm, now: now)
            return UsageOutlook.Room(provider: provider, accounts: room.accounts, weeklyLeft: Int(room.weeklyLeft.rounded()),
                                     fiveHourLeft: room.fiveHourLeft.map { Int($0.rounded()) }, limited: room.limited,
                                     runsOut: runsOut.map { ($0 / 900).rounded() * 900 })
        }
        return UsageOutlook(rooms: rooms)
    }
}
