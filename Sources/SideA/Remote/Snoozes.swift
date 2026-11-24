import Foundation
import SideACore

/// Snoozed sessions, kept on the Mac beside pins so every phone shows the same list. A snooze only moves a row; whatever
/// would need the person wakes it at once, so nothing that needs them is ever hidden.
@MainActor
final class Snoozes {
    struct Entry: Codable, Equatable {
        var snooze: SessionSnooze
        /// What the session was doing when last looked at: a new turn means someone sent it a message, and for
        /// `needsMe`, working then idle means it finished.
        var turnID: String?
        var status: SessionStatus
    }

    enum Wake: String { case request, failure, time, finished, message }

    static let forget: TimeInterval = 7 * 86_400

    private let url: URL
    private(set) var entries: [SessionKey: Entry]
    private var timer: Task<Void, Never>?
    var changed: (@MainActor () -> Void)?

    init(url: URL, changed: (@MainActor () -> Void)? = nil) {
        self.url = url
        self.changed = changed
        entries = (try? JSONDecoder().decode([SessionKey: Entry].self, from: Data(contentsOf: url))) ?? [:]
        // After a restart nothing else may change while they sleep, so only this wakes them on time.
        schedule()
    }

    /// `prompt` is when the session's own rollout last recorded a typed message. Only one after the snooze was set is a
    /// message to it, so a restart reading an old one wakes nothing.
    static func woken(_ entry: Entry, _ row: RemoteSession, prompt: Double? = nil, now: TimeInterval) -> Wake? {
        if !row.openRequests.isEmpty || row.status == .waiting { return .request }
        if row.failure != nil || [.failing, .stuck].contains(row.flag?.kind) { return .failure }
        if let until = entry.snooze.until, now >= until { return .time }
        if row.turnID != nil, entry.turnID != nil, row.turnID != entry.turnID { return .message }
        if let prompt, prompt > entry.snooze.at { return .message }
        if entry.snooze.choice == .needsMe, entry.status == .working || entry.status == .starting,
           [.idle, .finished, .exited].contains(row.status) { return .finished }
        return nil
    }

    func current(_ row: RemoteSession, prompt: Double? = nil, now: Date = Date()) -> SessionSnooze? {
        guard var entry = entries[row.id] else { return nil }
        if Self.woken(entry, row, prompt: prompt, now: now.timeIntervalSince1970) != nil {
            entries[row.id] = nil
            save()
            return nil
        }
        if entry.status != row.status || (entry.turnID == nil && row.turnID != nil) {
            entry.status = row.status
            entry.turnID = entry.turnID ?? row.turnID
            entries[row.id] = entry
            save()
        }
        return entry.snooze
    }

    /// Why a snooze of this row would wake at once: it asks something, or it has failed or stalled.
    static func refusal(_ row: RemoteSession) -> Wake? {
        let entry = Entry(snooze: SessionSnooze(choice: .needsMe, until: nil, at: 0), turnID: row.turnID, status: row.status)
        return woken(entry, row, now: 0).flatMap { [.request, .failure].contains($0) ? $0 : nil }
    }

    /// Nil when `refusal` has a reason: a snooze saved then would be dropped by the next row build.
    @discardableResult
    func snooze(_ row: RemoteSession, _ choice: SessionSnooze.Choice, until: TimeInterval?, now: Date = Date()) -> SessionSnooze? {
        guard Self.refusal(row) == nil else { return nil }
        let snooze = SessionSnooze(choice: choice, until: choice == .needsMe ? nil : until, at: now.timeIntervalSince1970)
        entries[row.id] = Entry(snooze: snooze, turnID: row.turnID, status: row.status)
        save()
        schedule(now: now)
        return snooze
    }

    func wake(_ id: SessionKey) {
        guard entries.removeValue(forKey: id) != nil else { return }
        save()
        changed?()
    }

    /// A finished turn's notification stays quiet while the session sleeps through it; one that finishing wakes isn't.
    /// Past its `until` it is awake, though the timer or the next row build may not have said so yet.
    func quiets(_ id: SessionKey, now: Date = Date()) -> Bool {
        guard let entry = entries[id], entry.snooze.until.map({ now.timeIntervalSince1970 < $0 }) ?? true else { return false }
        return entry.snooze.choice != .needsMe
    }

    func prune(keeping ids: Set<SessionKey>, now: Date = Date()) {
        let kept = entries.filter { ids.contains($0.key) || now.timeIntervalSince1970 - $0.value.snooze.at < Self.forget && $0.value.snooze.until.map { now.timeIntervalSince1970 < $0 } ?? true }
        guard kept.count != entries.count else { return }
        entries = kept
        save()
    }

    private func schedule(now: Date = Date()) {
        timer?.cancel()
        guard let soonest = entries.values.compactMap(\.snooze.until).min() else { return timer = nil }
        let wait = max(0, soonest - now.timeIntervalSince1970) + 1
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            changed?()
            schedule()
        }
    }

    private func save() {
        do { try PrivateFile.write(entries, to: url) } catch {
            RemoteLog.shared("couldn't save snoozed sessions: \(error.localizedDescription)")
        }
    }
}
