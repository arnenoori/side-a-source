import Foundation
import SideAProtocol

/// What the Mac has told the phone, merged into one state: the snapshot, the events after it and the REST lists that
/// refresh a part of it. A value with no sockets, tasks or clock: each call changes the state and returns what the
/// caller has to do about it. `SyncEngine` owns the connection and runs the effects.
struct Reconciler {
    /// What a call asks of the engine.
    enum Effect: Equatable {
        /// An answer still queued here lost the race to this resolution: it settles as answered elsewhere and leaves the outbox.
        case settle(Outbox.Item, RequestResolution)
    }

    /// The state the phone shows. Only the parts the Mac sends are changed here; the connection, the outbox's items and
    /// outcomes and the address belong to the engine.
    var state = RemoteState()
    /// Every request the Mac has open; `state.requests` is these less the ones with an answer pending.
    var open: [RequestID: RemoteRequest] = [:]
    /// The order `state.resolved` was filled in, so it keeps the last 50.
    private var resolvedOrder: [RequestID] = []
    /// A welcome that can't replay came: events wait for the snapshot that follows it.
    var awaitingSnapshot = false
    /// The Mac's `seq` at a welcome that replays: `state.caughtUp` once events reach it.
    private var replayTo: Int?

    /// What an event that came on the socket did.
    enum Receipt: Equatable {
        /// Not the next one in the sequence, or the state is waiting for a snapshot: nothing changed.
        case ignored
        /// A slice refreshed over REST already reflects it: the sequence moved on and nothing else did.
        case reflected
        /// Some events never arrived: the socket reconnects with the `seq` held.
        case gap
        case applied([Effect])
    }

    /// The Mac's welcome. The epoch changes only with the snapshot, so a drop before it reconnects as the old client.
    mutating func welcomed(_ welcome: Welcome) {
        state.hello = welcome.hello
        awaitingSnapshot = !welcome.replay || welcome.epoch != state.epoch
        replayTo = awaitingSnapshot ? nil : welcome.seq
        state.caughtUp = !awaitingSnapshot && state.seq >= welcome.seq
    }

    /// An event with its place in the sequence. The global `seq` advances only here, one event at a time, and in `apply(snapshot)`.
    mutating func receive(seq: Int?, _ event: ServerEvent) -> Receipt {
        guard let seq else { return .ignored }
        guard !awaitingSnapshot, seq > state.seq else { return .ignored }
        guard seq == state.seq + 1 else { return .gap }
        state.seq = seq
        if let replayTo, seq >= replayTo {
            state.caughtUp = true
            self.replayTo = nil
        }
        // A slice refreshed over REST already reflects events up to its seq.
        if let slice = Self.slice(of: event), seq <= state.sliceSeq[slice] ?? -1 { return .reflected }
        return .applied(apply(event))
    }

    /// A frame that doesn't decode still took its place in the sequence: without its seq the next frame reads as a gap, and
    /// the Mac replays this one again. True when it was the next one: its change is lost, so the state has to be read afresh.
    mutating func undecodable(seq: Int) -> Bool {
        guard !awaitingSnapshot, seq == state.seq + 1 else { return false }
        state.seq = seq
        return true
    }

    /// A snapshot read over REST replaces everything, unless the stream is already further along in the same epoch.
    mutating func refreshed(_ snapshot: StateSnapshot) -> Bool {
        guard snapshot.epoch != state.epoch || snapshot.seq >= state.seq else { return false }
        apply(snapshot)
        return true
    }

    // REST lists: each refreshes its part of the state and never moves `seq`.

    mutating func replace(_ list: RequestList, asked: String?) -> Bool {
        guard fresher(list.seq, .requests, asked: asked) else { return false }
        open = Self.keyed(list.requests, \.id)
        return true
    }

    mutating func replace(_ list: AccountList, asked: String?) -> Bool {
        guard fresher(list.seq, .accounts, asked: asked) else { return false }
        state.accounts = Self.keyed(list.accounts, \.id)
        return true
    }

    /// A list replaces its slice only when newer than both `seq` and the slice's last refresh, and was asked for in the
    /// epoch the state is in now: the lists carry no epoch, and a relaunched Mac's `seq` starts again, so an old one's
    /// answer could look newer than the snapshot that replaced it. Asked before any epoch was known, it can't tell.
    private mutating func fresher(_ seq: Int, _ slice: Slice, asked: String?) -> Bool {
        guard asked == nil || asked == state.epoch else { return false }
        guard seq > state.seq, seq > state.sliceSeq[slice] ?? -1 else { return false }
        state.sliceSeq[slice] = seq
        return true
    }

    /// The Mac no longer has this request open, whichever of an answer's response and its event comes first.
    mutating func closed(_ request: RequestID) { open[request] = nil }

    /// `state.requests`: the open ones, less those with an answer pending in the outbox.
    mutating func project() {
        let answering = Set(state.pending.compactMap(\.answering))
        state.requests = open.filter { !answering.contains($0.key) }
    }

    static func keyed<T, K: Hashable>(_ values: [T], _ key: KeyPath<T, K>) -> [K: T] {
        Dictionary(values.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { $1 })
    }

    static func slice(of event: ServerEvent) -> Slice? {
        switch event {
        case .requestAdd, .requestResolve: .requests
        case .usageUpdate, .accountRemove: .accounts
        default: nil
        }
    }

    mutating func apply(_ snapshot: StateSnapshot) {
        awaitingSnapshot = false
        replayTo = nil
        state.caughtUp = true
        state.seq = snapshot.seq
        state.epoch = snapshot.epoch
        state.sliceSeq = [:]
        state.sessions = Self.keyed(snapshot.sessions, \.id)
        state.finished = Self.keyed(snapshot.finished, \.sessionID)
        open = Self.keyed(snapshot.requests, \.id)
        state.hosted = Self.keyed(snapshot.hosted, \.name)
        state.accounts = Self.keyed(snapshot.accounts, \.id)
        state.mac = snapshot.mac
        state.incidents = snapshot.incidents ?? []
        state.autopilot = snapshot.autopilot
        state.droppedReplies = snapshot.droppedReplies ?? []
    }

    mutating func apply(_ event: ServerEvent) -> [Effect] {
        switch event {
        case .sessionUpsert(let session): state.sessions[session.id] = session
        case .sessionRemove(let id, _): state.sessions[id] = nil
        case .requestAdd(let request): open[request.id] = request
        case .requestResolve(let resolution): return resolve(resolution)
        case .finishedAdd(let finished): state.finished[finished.sessionID] = finished
        case .finishedResolve(let session, let reason):
            state.finished[session] = nil
            if reason == ServerEvent.finishedQueueDropped { state.queueDrops[session, default: 0] += 1 }
        case .usageUpdate(let accounts): for account in accounts { state.accounts[account.id] = account }
        case .accountRemove(let id): state.accounts[id] = nil
        case .hostedUpsert(let hosted): state.hosted[hosted.name] = hosted; state.attention[hosted.name] = nil
        case .hostedRemove(let name): state.hosted[name] = nil; state.attention[name] = nil
        case .hostedAttention(let attention): state.attention[attention.name] = attention
        case .macUpdate(let mac): state.mac = mac
        case .incidentUpdate(let incidents): state.incidents = incidents
        case .autopilotUpdate(let autopilot): state.autopilot = autopilot
        default: break
        }
        return []
    }

    private mutating func resolve(_ resolution: RequestResolution) -> [Effect] {
        open[resolution.requestID] = nil
        state.resolved[resolution.requestID] = resolution
        resolvedOrder.append(resolution.requestID)
        while resolvedOrder.count > 50 { state.resolved[resolvedOrder.removeFirst()] = nil }
        // An answer still queued here lost the race; one from a device may be ours, which its response settles.
        guard resolution.by != .device else { return [] }
        var effects: [Effect] = []
        for item in state.pending where item.answering == resolution.requestID {
            state.pending.removeAll { $0.id == item.id }
            effects.append(.settle(item, resolution))
        }
        return effects
    }
}
