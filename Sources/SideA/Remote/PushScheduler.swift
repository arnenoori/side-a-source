import Foundation
import SideAProtocol

struct PushScheduler {
    static let atMac: TimeInterval = 60
    static let grace: TimeInterval = 10
    static let shortTurn: TimeInterval = 30
    static let soundWindow: TimeInterval = 300
    static let maxReady = 8

    enum Kind: Equatable, Sendable {
        case ask(destructive: Bool)
        case health
        case notice
    }

    enum Action: Equatable {
        case send(String)
        case ready([FinishedSession], quiet: Bool)
    }

    struct Held: Equatable {
        let id: String
        let kind: Kind
        let arrived: Date
    }

    private(set) var held: [Held] = []
    private(set) var ready: [FinishedSession] = []
    private(set) var due: Set<String> = []
    private(set) var lastSound: Date?

    mutating func add(_ id: String, _ kind: Kind, now: Date, presence: UserPresence) -> [Action] {
        held.removeAll { $0.id == id }
        held.append(Held(id: id, kind: kind, arrived: now))
        return tick(now: now, presence: presence)
    }

    /// A turn that just finished, and how long it ran when that's known. Unknown counts as long enough.
    mutating func finished(_ turn: FinishedSession, ran: TimeInterval?, now: Date, presence: UserPresence) -> [Action] {
        ready.removeAll { $0.turnID == turn.turnID || $0.sessionID == turn.sessionID }
        ready.insert(turn, at: 0)
        ready = Array(ready.prefix(Self.maxReady))
        if (ran ?? .infinity) >= Self.shortTurn { due.insert(turn.turnID) }
        due.formIntersection(ready.map(\.turnID))
        return tick(now: now, presence: presence)
    }

    mutating func resolve(_ id: String) {
        held.removeAll { $0.id == id }
        ready.removeAll { $0.turnID == id }
        due.remove(id)
    }

    mutating func tick(now: Date, presence: UserPresence) -> [Action] {
        guard presence.away(for: Self.atMac) else { return [] }
        let going = held.filter { now.timeIntervalSince($0.arrived) >= Self.wait($0.kind) }
        held.removeAll { going.contains($0) }
        var actions = going.map { Action.send($0.id) }
        if !due.isEmpty {
            let quiet = lastSound.map { now.timeIntervalSince($0) < Self.soundWindow } ?? false
            if !quiet { lastSound = now }
            due = []
            actions.append(.ready(ready, quiet: quiet))
        }
        return actions
    }

    /// Seconds until a tick could send something: the soonest grace ending, or the soonest the user could be away if
    /// nobody touches the Mac. Nil with nothing waiting.
    func nextCheck(now: Date, presence: UserPresence) -> TimeInterval? {
        guard !held.isEmpty || !due.isEmpty else { return nil }
        var waits = held.map { Self.wait($0.kind) - now.timeIntervalSince($0.arrived) }.filter { $0 > 0 }
        if !presence.away(for: Self.atMac) { waits.append(Self.atMac - presence.idle) }
        return max(waits.min() ?? 1, 0.5)
    }

    private static func wait(_ kind: Kind) -> TimeInterval { kind == .ask(destructive: false) ? grace : 0 }
}
