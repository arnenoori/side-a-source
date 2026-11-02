import Foundation
import SideAProtocol

/// When the Mac starts, updates and ends each phone's Live Activity (relay-and-release, Live Activity): a push-to-start
/// when something starts working or waiting, an update on any change, a replacement before iOS stops updating it at
/// 8 hours, and an end after 15 idle minutes or when the phone turns them off. A phone that swiped it away gets none
/// until the Mac is idle and busy again, nor does one that never reported the starts it was sent.
public struct LiveActivities: Sendable {
    public static let lifetime: TimeInterval = 7 * 3600 + 45 * 60
    public static let idleEnd: TimeInterval = 15 * 60
    /// How long a push-to-start waits for the phone to report the activity it made before another is tried.
    public static let startWait: TimeInterval = 60
    /// Push-to-starts per busy spell: a phone that makes activities without reporting them must not collect one a minute.
    public static let maxStarts = 3

    public struct Device: Sendable, Equatable {
        public let id: String
        public let wanted: Bool
        public let canStart: Bool
        public init(id: String, wanted: Bool, canStart: Bool) { self.id = id; self.wanted = wanted; self.canStart = canStart }
    }

    public enum Action: Sendable, Equatable {
        case start(device: String)
        case update(device: String, activity: String, priority: Int)
        case end(device: String, activity: String)
    }

    /// One phone's activity. No entry: none, and free to start one.
    enum Card: Sendable, Equatable {
        /// Push-to-start sent, the phone hasn't reported the activity yet.
        case starting(since: TimeInterval, attempts: Int, state: ActivityContentState)
        case running(id: String, started: TimeInterval, state: ActivityContentState?)
        /// Swiped away; none until the next busy spell.
        case dismissed
        /// `maxStarts` went unreported; none until the next busy spell.
        case gaveUp
    }

    var cards: [String: Card] = [:]
    /// Activities sent an `.end` that the phone may still list, so they're neither adopted nor ended again.
    var ending: [String: Set<String>] = [:]
    public private(set) var state = ActivityContentState(working: 0, waiting: 0)
    var idleSince: TimeInterval?

    public init() {}

    public var active: Bool {
        cards.values.contains { card in
            switch card {
            case .starting, .running: true
            case .dismissed, .gaveUp: false
            }
        }
    }

    /// The activities a phone reports it holds. One it no longer lists was swiped away; any beyond the one followed are
    /// frozen cards nothing else would update, so they end.
    public mutating func reported(_ device: String, activities: [String], now: TimeInterval) -> [Action] {
        let listed = Set(activities)
        ending[device] = ending[device]?.intersection(listed)
        if ending[device]?.isEmpty == true { ending[device] = nil }
        let open = listed.subtracting(ending[device] ?? [])
        let kept: String?
        switch cards[device] {
        case .running(let id, let started, let state):
            if listed.contains(id) { kept = id } else {
                cards[device] = .dismissed
                kept = open.sorted().first
                if let kept { cards[device] = .running(id: kept, started: started, state: state) }
            }
        case .starting(let since, _, let state):
            kept = open.sorted().first
            if let kept { cards[device] = .running(id: kept, started: since, state: state) }
        case .dismissed, .gaveUp, nil:
            kept = open.sorted().first
            if let kept { cards[device] = .running(id: kept, started: now, state: nil) }
        }
        let extras = open.subtracting([kept].compactMap { $0 }).sorted()
        ending[device, default: []].formUnion(extras)
        if ending[device]?.isEmpty == true { ending[device] = nil }
        return extras.map { .end(device: device, activity: $0) }
    }

    public mutating func forget(_ device: String) { cards[device] = nil; ending[device] = nil }

    public mutating func changed(_ next: ActivityContentState, devices: [Device], now: TimeInterval) -> [Action] {
        let busy = next.working + next.waiting > 0
        if busy { idleSince = nil } else if idleSince == nil { idleSince = now }
        if busy, state.working + state.waiting == 0 { cards = cards.filter { $0.value != .dismissed && $0.value != .gaveUp } }
        // A request arriving or settling goes at once: one answered elsewhere mustn't sit on the Lock Screen with its
        // Allow and Deny until a low-priority update gets through. Only the working count can wait.
        let urgent = next.waiting != state.waiting || next.topRequest != state.topRequest
        state = next
        var actions: [Action] = []
        for device in devices {
            actions += step(device, busy: busy, urgent: urgent, now: now)
        }
        return actions
    }

    private mutating func step(_ device: Device, busy: Bool, urgent: Bool, now: TimeInterval) -> [Action] {
        var actions: [Action] = []
        switch cards[device.id] {
        case .running(let id, let started, let shown):
            if !device.wanted { return end(device.id, id) }
            let old = now - started >= Self.lifetime
            if old || (!busy && now - (idleSince ?? now) >= Self.idleEnd) {
                actions = end(device.id, id)
                if !old || !busy { return actions }
            } else {
                guard shown != state else { return [] }
                cards[device.id] = .running(id: id, started: started, state: state)
                return [.update(device: device.id, activity: id, priority: urgent ? 10 : 5)]
            }
        case .starting(let since, let attempts, _):
            guard now - since >= Self.startWait else { return [] }
            guard device.wanted, busy else { cards[device.id] = nil; return [] }
            guard device.canStart else { return [] }
            guard attempts < Self.maxStarts else { cards[device.id] = .gaveUp; return [] }
            cards[device.id] = .starting(since: now, attempts: attempts + 1, state: state)
            return [.start(device: device.id)]
        case .dismissed, .gaveUp:
            return []
        case nil:
            break
        }
        if device.wanted, busy, device.canStart {
            actions.append(.start(device: device.id))
            cards[device.id] = .starting(since: now, attempts: 1, state: state)
        }
        return actions
    }

    private mutating func end(_ device: String, _ activity: String) -> [Action] {
        cards[device] = nil
        ending[device, default: []].insert(activity)
        return [.end(device: device, activity: activity)]
    }
}
