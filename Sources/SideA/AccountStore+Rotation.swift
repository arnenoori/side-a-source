import Foundation
import SideACore
import SideAProtocol

/// `runtime/rotation.json`: Autopilot's newest moves and holds, whole. A demo keeps its own in memory.
struct RotationRecords {
    static let limit = 100
    let url: URL?
    private(set) var records: [RotationRecord]

    init(url: URL?) {
        self.url = url
        records = url.flatMap { try? PrivateFile.read([RotationRecord].self, from: $0) } ?? []
    }

    mutating func add(_ record: RotationRecord) {
        records.append(record)
        records.removeFirst(max(records.count - Self.limit, 0))
        if let url { try? PrivateFile.write(records, to: url) }
    }
}

extension AccountStore {
    /// The live sessions on an account, for a move's record; a folder's name stands in for a title on disk.
    func rotationSessions(on id: String) -> [RotationRecord.Session] {
        sessions.live.filter { $0.provider == .claude && sessions.accountID(of: $0) == id }.map {
            RotationRecord.Session(id: WireBuilders.key($0), project: sessions.project(of: $0.cwd))
        }
    }

    func recordRotation(_ record: RotationRecord) {
        rotationRecords.add(record)
        remote.events?.autopilotChanged()
    }

    /// Per login in use, where its sessions go when it fills up. Codex logins are never traded, so only Claude's.
    func nextMoves(now: Double) -> [NextMove] {
        guard config.smartMode, unknownLogins[.claude] == nil else { return [] }
        let accounts = config.accounts.filter { $0.provider == .claude }
        let slots = busyLogins ?? [:]
        let busy = Set(slots.values).union([activeIDs[.claude]].compactMap { $0 }).union(signingIn)
        let logins = (slots.keys.sorted().compactMap { slot in slots[slot].map { (slot: Optional(slot), id: $0) } }
            + [activeIDs[.claude]].compactMap { $0 }.map { (slot: String?.none, id: $0) })
        var seen = Set<String>()
        return logins.compactMap { login -> NextMove? in
            guard seen.insert(login.id).inserted, let account = accounts.first(where: { $0.id == login.id }), account.allowAuto else { return nil }
            let held = login.slot.flatMap { heldMoves[$0] }
            let planned = usageForPlanning(slot: login.slot)
            let to = held?.to ?? Planner.next(after: account, among: accounts, usage: planned, health: health, busy: busy, full: config.moveAt, now: now)
            return NextMove(id: account.id, from: account.name, to: to.flatMap { id in config.accounts.first { $0.id == id }?.name },
                            atPercent: Int(config.moveAt.rounded()), minutes: minutesUntilSwap(account.id, now: now), held: held != nil)
        }
    }

    /// As the tick plans a slot: by what its own sessions run, unknown models following the newest session.
    func usageForPlanning(slot: String?) -> [String: AccountUsage] {
        switch slot.flatMap({ Planner.needsFable(slotModels[$0]) }) {
        case true?: plannable.compactMapValues(\.forFable)
        case false?: plannable
        case nil: planning(plannable)
        }
    }

    /// Rounded to five minutes, so a reading a minute later says the same. Nil when the 5-hour window resets first.
    private func minutesUntilSwap(_ id: String, now: Double) -> Int? {
        guard let minutes = minutesToLimit(id) else { return nil }
        if let reset = usage[id]?.fiveHour?.resetsAt, reset < now + minutes * 60 { return nil }
        return max(Int((minutes / 5).rounded()) * 5, 5)
    }

    /// Sessions whose own last reply was a limit error, by conversation, while that limit still holds.
    func sessionLimits(now: Double) -> [String: SessionLimit] {
        var found: [String: SessionLimit] = [:]
        for (id, hit) in limitHits {
            guard let value = usage[id] else { continue }
            let window = value.windows.first { $0.id == hit.limit }
            let reset = window?.resetsAt
            let stillOut = hit.limit.hasPrefix("model:") ? (window?.used(at: now) ?? 0) >= Planner.limited : !Planner.hasHeadroom(value, full: config.moveAt, now: now)
            guard stillOut, reset.map({ $0 > now }) ?? true else { continue }
            let worst = hit.at + UsageWindow.seconds(of: hit.limit)
            for session in hit.sessions {
                found[session] = SessionLimit(window: hit.limit, accountID: id, until: reset, worstCase: reset == worst)
            }
        }
        return found
    }

    /// The first account sessions stopped on a limit can use again: one Autopilot may move them to, or their own.
    func waitingSummary(limits: [String: SessionLimit], now: Double) -> WaitingSummary? {
        let running = Set(sessions.live.compactMap(\.sessionID))
        let stopped = limits.filter { running.contains($0.key) }
        guard !stopped.isEmpty else { return nil }
        let theirs = Set(stopped.values.map(\.accountID))
        let usable = config.accounts.filter { $0.provider == .claude && (theirs.contains($0.id) || (config.smartMode && $0.allowAuto)) }
        guard let (account, at) = Planner.nextAvailable(usable, usage: plannable, full: config.moveAt, now: now) else {
            guard let first = stopped.values.filter({ $0.until != nil }).min(by: { $0.until! < $1.until! }), let at = first.until,
                  let name = config.accounts.first(where: { $0.id == first.accountID })?.name else { return nil }
            return WaitingSummary(account: name, at: at, worstCase: first.worstCase)
        }
        let worst = stopped.values.contains { $0.accountID == account.id && $0.until == at && $0.worstCase }
        return WaitingSummary(account: account.name, at: at, worstCase: worst)
    }

    /// Why Autopilot skips an account, or is about to.
    func accountIssue(_ account: Account, now: Double) -> AccountIssue? {
        guard account.ready else { return AccountIssue(kind: .signedOut) }
        switch health[account.id] {
        case .signIn(let other): return other.map { AccountIssue(kind: .replaced, replacedBy: $0) } ?? AccountIssue(kind: .signIn)
        case .verify: return AccountIssue(kind: .verifying)
        case .offline: return AccountIssue(kind: .offline)
        case .idle, nil: break
        }
        guard let end = loginEnds[account.id], end - now < 3 * 86_400 else { return nil }
        return AccountIssue(kind: .signInEnds, endsAt: end)
    }

    /// The held move's cost, from the statusline's copy of what Claude Code last said. Claude Code doesn't document
    /// `prompt_cache`, so anything but the shape seen so far says nothing.
    func recacheTokens(slot: String) -> Int? {
        guard slot == URL(fileURLWithPath: slot).lastPathComponent, !slot.hasPrefix(".") else { return nil }
        struct Live: Decodable {
            struct Cache: Decodable { let warm: Bool?; let recache_tokens_if_cold: Int? }
            let prompt_cache: Cache?
        }
        let url = root.appendingPathComponent("runtime/live/\(slot).json")
        guard let data = try? Data(contentsOf: url), let cache = (try? JSONDecoder().decode(Live.self, from: data))?.prompt_cache,
              cache.warm == true, let tokens = cache.recache_tokens_if_cold, tokens > 0 else { return nil }
        return tokens
    }

    // MARK: Pushes

    /// A login moved; the phone says where to and why.
    func pushMoved(to: String, reason: String) {
        guard RemoteController.active else { return }
        remote.push.rotation(title: "Now on \(to)", body: reason.isEmpty ? nil : reason, account: nil, resetsAt: nil, blocks: false)
    }

    func pushAllOut(fable: Bool, back: String, at: Double) {
        guard RemoteController.active else { return }
        remote.push.rotation(title: fable ? "Fable out" : "All out", body: nil, account: back, resetsAt: at, blocks: true)
    }

    func pushStuck(_ account: Account, reset: Double?) {
        guard RemoteController.active else { return }
        remote.push.rotation(title: "\(account.name) is full", body: reset == nil ? "No account free" : nil, account: reset == nil ? nil : account.name, resetsAt: reset, blocks: true)
    }
}
