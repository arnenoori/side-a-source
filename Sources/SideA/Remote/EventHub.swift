import Foundation
import SideACore

/// `/v1/ws/events`: every events socket, the ring of recent state events, replay and snapshots. Runs on the server's
/// queue. State events arrive from the main actor in order (each through `queue.async`), so the ring's order is theirs.
final class EventHub: @unchecked Sendable {
    static let helloTime: TimeInterval = 5
    static let maxSubscriptions = 8
    static let presenceLease: TimeInterval = 45

    struct Presence: Sendable, Equatable {
        let foreground: Bool
        let viewing: SessionKey?
        let at: Date
    }

    private let queue: DispatchQueue
    private var ring: EventRing<Data>
    private var clients: [UInt64: Client] = [:]
    /// Built on the main actor in one pass; the hub stamps it with the seq at the moment it lands on the queue.
    private let snapshot: @MainActor @Sendable () -> @Sendable (Int, String) -> StateSnapshot
    private let hello: @MainActor @Sendable () -> Hello
    var socketsChanged: (@Sendable ([String: Int]) -> Void)?
    var subscribed: (@Sendable (_ client: UInt64, _ sessions: [SessionKey: Cursor?]) -> Void)?
    /// A phone's `hello`: what it can do, by its device.
    var greeted: (@Sendable (_ device: String, _ capabilities: Set<Capability>) -> Void)?

    private final class Client {
        let peer: WebSocketPeer
        var ready = false
        /// Its `hello` came; the welcome follows a main-actor hop, and a second `hello` meanwhile gets none.
        var greeted = false
        var subscriptions: [SessionKey: Cursor?] = [:]
        var order: [SessionKey] = []
        var presence: Presence?
        init(peer: WebSocketPeer) { self.peer = peer }
    }

    var epoch: String { ring.epoch }
    var seq: Int { ring.seq }

    /// The ring's events after `seq`, from off the queue: for tests.
    func recorded(after seq: Int) -> [ServerEvent] {
        queue.sync {
            (ring.replay(epoch: ring.epoch, after: seq, now: Date().timeIntervalSince1970) ?? [])
                .compactMap { try? JSONDecoder().decode(EventEnvelope.self, from: $0).event }
        }
    }

    init(queue: DispatchQueue, epoch: String, snapshot: @escaping @MainActor @Sendable () -> @Sendable (Int, String) -> StateSnapshot,
         hello: @escaping @MainActor @Sendable () -> Hello) {
        self.queue = queue
        ring = EventRing(epoch: epoch)
        self.snapshot = snapshot
        self.hello = hello
    }

    // MARK: Sockets

    func attach(_ peer: WebSocketPeer) {
        let client = Client(peer: peer)
        clients[peer.id] = client
        peer.message = { [weak self] message in self?.received(message, from: peer.id) }
        peer.ending = { [weak self] in
            self?.clients[peer.id] = nil
            self?.reportSockets()
        }
        queue.asyncAfter(deadline: .now() + Self.helloTime) { [weak self, weak peer] in
            guard let self, let peer, let client = self.clients[peer.id], !client.ready else { return }
            peer.close(4400, "no hello")
        }
        reportSockets()
    }

    private func reportSockets() {
        socketsChanged?(clients.values.reduce(into: [:]) { $0[$1.peer.device, default: 0] += 1 })
    }

    private func received(_ message: WebSocketCodec.Message, from id: UInt64) {
        guard let client = clients[id] else { return }
        guard case .text(let text) = message, let decoded = try? JSONDecoder().decode(ClientMessage.self, from: Data(text.utf8)) else {
            if !client.ready { client.peer.close(4400, "bad hello") }
            return
        }
        switch decoded {
        case .hello(let epoch, let lastSeq, let capabilities):
            guard !client.greeted else { return }
            client.greeted = true
            greeted?(client.peer.device, capabilities)
            welcome(client, epoch: epoch, lastSeq: lastSeq)
        case .subscribe(let sessions):
            for (session, cursor) in sessions {
                if !client.subscriptions.keys.contains(session) { client.order.append(session) }
                client.subscriptions[session] = .some(cursor)
            }
            while client.order.count > Self.maxSubscriptions { client.subscriptions.removeValue(forKey: client.order.removeFirst()) }
            subscribed?(id, sessions)
        case .unsubscribe(let sessions):
            for session in sessions { client.subscriptions.removeValue(forKey: session) }
            client.order.removeAll { sessions.contains($0) }
        case .presence(let foreground, let viewing):
            client.presence = Presence(foreground: foreground, viewing: viewing, at: Date())
        case .unknown:
            break
        }
    }

    /// Replay when the ring still holds everything after `lastSeq` in this epoch; otherwise one snapshot. Both are
    /// decided after one hop to the main actor, so every event recorded before it is already in the ring.
    private func welcome(_ client: Client, epoch: String?, lastSeq: Int?) {
        let snapshot = snapshot, hello = hello
        let id = client.peer.id
        DispatchQueue.main.async {
            let (build, greeting) = MainActor.assumeIsolated { (snapshot(), hello()) }
            self.queue.async { [self] in
                guard let client = clients[id] else { return }
                client.ready = true
                if let events = ring.replay(epoch: epoch, after: lastSeq, now: Date().timeIntervalSince1970) {
                    send(client, .welcome(SideAProtocol.Welcome(epoch: ring.epoch, seq: ring.seq, replay: true, hello: greeting)))
                    for event in events { client.peer.send(.text(String(decoding: event, as: UTF8.self))) }
                    return
                }
                // Over 512 KiB the snapshot would fill the socket's send budget (4008, and a reconnect into the same
                // snapshot): the phone reads it from GET /v1/state instead.
                guard let snapshot = Self.encode(EventEnvelope(seq: nil, at: Date().timeIntervalSince1970, event: .snapshot(build(ring.seq, ring.epoch).scoped(to: client.peer.device)))),
                      snapshot.count <= Self.snapshotLimit else {
                    return send(client, .welcome(SideAProtocol.Welcome(epoch: ring.epoch, seq: ring.seq, replay: false, snapshotOverREST: true, hello: greeting)))
                }
                send(client, .welcome(SideAProtocol.Welcome(epoch: ring.epoch, seq: ring.seq, replay: false, hello: greeting)))
                client.peer.send(.text(String(decoding: snapshot, as: UTF8.self)))
            }
        }
    }

    private func send(_ client: Client, _ event: ServerEvent, seq: Int? = nil) {
        guard let data = Self.encode(EventEnvelope(seq: seq, at: Date().timeIntervalSince1970, event: event)) else { return }
        client.peer.send(.text(String(decoding: data, as: UTF8.self)))
    }

    static func encode(_ envelope: EventEnvelope) -> Data? { try? RemoteRoutes.encoder.encode(envelope) }

    static let snapshotLimit = 512 << 10

    // MARK: Events

    /// A state event: sequenced, kept in the ring, sent to every socket past its welcome.
    func record(_ event: ServerEvent, at: Timestamp) {
        let now = Date().timeIntervalSince1970
        var encoded: Data?
        ring.append(at: now) { seq in
            let data = Self.encode(EventEnvelope(seq: seq, at: at, event: event)) ?? Data()
            encoded = data
            return data
        }
        guard let encoded else { return }
        let text = String(decoding: encoded, as: UTF8.self)
        for client in clients.values where client.ready { client.peer.send(.text(text)) }
    }

    /// Transcript events go only to the sockets named, and never into the ring.
    /// From the main actor: the sends happen on the hub's queue, where sockets attach and go.
    func transcript(_ events: [ServerEvent], to ids: [UInt64]) {
        queue.async { [self] in
            for id in ids { if let client = clients[id], client.ready { events.forEach { send(client, $0) } } }
        }
    }

    /// Each subscribed socket's cursor for a session, from the main actor.
    func cursors(_ session: SessionKey) -> [UInt64: Cursor?] {
        queue.sync { clients.compactMapValues { $0.ready ? $0.subscriptions[session] : nil } }
    }

    /// A delta went out: the sockets that held `from` now hold `to`. One that resubscribed since keeps its own.
    func advance(_ ids: [UInt64], session: SessionKey, from: Cursor?, to: Cursor) {
        queue.async { [self] in
            for id in ids where clients[id]?.subscriptions[session] == .some(from) { clients[id]?.subscriptions[session] = .some(to) }
        }
    }

    /// Every session some socket is subscribed to, from the main actor.
    var subscriptions: Set<SessionKey> { queue.sync { Set(clients.values.flatMap(\.subscriptions.keys)) } }

    /// Who is looking at what, for skipping a push the user is already watching.
    /// From the main actor; the hub's state belongs to its queue.
    func presence(_ device: String) -> Presence? {
        queue.sync { current(device) }
    }

    private func current(_ device: String) -> Presence? {
        clients.values.filter { $0.peer.device == device }.compactMap(\.presence)
            .filter { -$0.at.timeIntervalSinceNow < Self.presenceLease }.max { $0.at < $1.at }
    }

    func farewell(_ peer: WebSocketPeer, reason: String) {
        guard let client = clients[peer.id] else { return }
        send(client, .bye(reason: reason))
    }
}
