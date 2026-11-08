import Foundation
import SideAProtocol

/// When each push goes. Nothing while someone is at the Mac: it waits for them to leave, and goes only if it's still
/// unanswered. A request, question or plan waits a few seconds more, since Autopilot, an auto-answer or the Mac often
/// answers it first. Finished turns gather into one Ready notification per Mac, and only the first in a while makes a
/// sound. Fed the time and the Mac's presence; it never waits itself.
struct PushScheduler {
    /// Input this recent on an unlocked screen is someone at the Mac; this long without, or a locked screen, is away.
    static let atMac: TimeInterval = 60
    /// How long an ask waits to be answered some other way first.
    static let grace: TimeInterval = 10
    /// A turn shorter than this doesn't push on its own.
    static let shortTurn: TimeInterval = 30
    /// Only the first Ready push in this long makes a sound.
    static let soundWindow: TimeInterval = 300
    /// Ready keeps at most this many rows.
    static let maxReady = 8

    enum Kind: Equatable, Sendable {
        /// A request, question or plan. A destructive request skips the grace: it shouldn't sit unseen.
        case ask(destructive: Bool)
        case health
        /// A limit or Autopilot's move: nothing answers it, so it goes once the user is away, the latest under its id.
        case notice
    }

    enum Action: Equatable {
        /// The held push with this id goes now.
        case send(String)
        /// Ready's notification, with every turn in it now, newest first.
        case ready([FinishedSession], quiet: Bool)
    }

    struct Held: Equatable {
        let id: String
        let kind: Kind
        let arrived: Date
    }

    private(set) var held: [Held] = []
    /// What's in Ready, newest first.
    private(set) var ready: [FinishedSession] = []
    /// Turns long enough to push on their own that haven't been pushed yet.
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

    /// Answered, resolved or gone from Ready: a request's or health's id, or a turn's.
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
