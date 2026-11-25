import Foundation
import SideACore
import SideAProtocol

enum Wire {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        guard let data = try? encoder.encode(value) else {
            return .apiError(500, .internalError, "The daemon couldn't encode the answer.")
        }
        return .json(status, data)
    }
}

/// `/v1/ws/events`: every events socket, the ring of recent state events, replay and snapshots
/// (`docs/remote/protocol.md`, WebSocket: /v1/ws/events). The Mac's `EventHub` runs on its listener's queue; this one is
/// an actor, and each socket's messages are handled in the order they arrived.
public actor EventHub {
    public static let helloTime: Duration = .seconds(5)
    public static let maxSubscriptions = 8
    public static let presenceLease: TimeInterval = 45
    public static let snapshotLimit = 512 << 10

    public struct Presence: Sendable, Equatable {
        public let foreground: Bool
        public let viewing: SessionKey?
        public let at: Date
    }

    private final class Client {
        let peer: SocketPeer
        let device: String
        var ready = false
        var greeted = false
        var subscriptions: [SessionKey: Cursor?] = [:]
        var order: [SessionKey] = []
        var presence: Presence?
        init(peer: SocketPeer, device: String) { self.peer = peer; self.device = device }
    }

    public typealias SnapshotBuilder = @Sendable (_ seq: Int, _ epoch: String) async -> StateSnapshot
    public typealias HelloBuilder = @Sendable () async -> Hello

    private var ring: EventRing<Data>
    private var clients: [UInt64: Client] = [:]
    private let snapshot: SnapshotBuilder
    private let hello: HelloBuilder
    /// Told when a phone says hello (its capabilities) and when a socket subscribes to transcripts.
    private var onGreeted: (@Sendable (_ device: String, _ capabilities: Set<Capability>) async -> Void)?
    private var onSubscribed: (@Sendable (_ socket: UInt64, _ device: String, _ sessions: [SessionKey: Cursor?]) async -> Void)?
    public static let socketsPerDevice = 4

    public init(epoch: String, snapshot: @escaping SnapshotBuilder, hello: @escaping HelloBuilder) {
        ring = EventRing(epoch: epoch)
        self.snapshot = snapshot
        self.hello = hello
    }

    public var epoch: String { ring.epoch }
    public var seq: Int { ring.seq }

    public func observe(greeted: (@Sendable (String, Set<Capability>) async -> Void)?,
                        subscribed: (@Sendable (UInt64, String, [SessionKey: Cursor?]) async -> Void)?) {
        onGreeted = greeted
        onSubscribed = subscribed
    }

    public func socketCount(device: String) -> Int { clients.values.filter { $0.device == device }.count }

    /// Takes over a freshly upgraded socket. Called on the connection's event loop through `SocketPeer.onMessage`.
    public nonisolated func attach(_ peer: SocketPeer, device: String) {
        let (messages, input) = AsyncStream<WebSocketCodec.Message>.makeStream()
        peer.onMessage = { input.yield($0) }
        peer.onEnd = { input.finish() }
        Task {
            await self.register(peer, device: device)
            for await message in messages { await self.received(message, from: peer.connection.id) }
            await self.detach(peer.connection.id)
        }
    }

    private func register(_ peer: SocketPeer, device: String) {
        clients[peer.connection.id] = Client(peer: peer, device: device)
        let id = peer.connection.id
        Task {
            try? await Task.sleep(for: Self.helloTime)
            await self.helloDue(id)
        }
    }

    private func helloDue(_ id: UInt64) {
        guard let client = clients[id], !client.ready, !client.greeted else { return }
        client.peer.close(4400, "no hello")
    }

    private func detach(_ id: UInt64) { clients[id] = nil }

    private func received(_ message: WebSocketCodec.Message, from id: UInt64) async {
        guard let client = clients[id] else { return }
        guard case .text(let text) = message, let decoded = try? JSONDecoder().decode(ClientMessage.self, from: Data(text.utf8)) else {
            if !client.ready { client.peer.close(4400, "bad hello") }
            return
        }
        switch decoded {
        case .hello(let epoch, let lastSeq, let capabilities):
            guard !client.greeted else { return }
            client.greeted = true
            await onGreeted?(client.device, capabilities)
            await welcome(client, epoch: epoch, lastSeq: lastSeq)
        case .subscribe(let sessions):
            for (session, cursor) in sessions {
                if !client.subscriptions.keys.contains(session) { client.order.append(session) }
                client.subscriptions[session] = .some(cursor)
            }
            while client.order.count > Self.maxSubscriptions { client.subscriptions.removeValue(forKey: client.order.removeFirst()) }
            await onSubscribed?(id, client.device, sessions)
        case .unsubscribe(let sessions):
            for session in sessions { client.subscriptions.removeValue(forKey: session) }
            client.order.removeAll { sessions.contains($0) }
        case .presence(let foreground, let viewing):
            client.presence = Presence(foreground: foreground, viewing: viewing, at: Date())
        case .unknown:
            break
        }
    }

    /// Replay when the ring still holds everything after `lastSeq` in this epoch; otherwise one snapshot.
    private func welcome(_ client: Client, epoch: String?, lastSeq: Int?) async {
        let greeting = await hello()
        // Events recorded while the snapshot is built land in the ring first; `seq` is read after, so none is skipped.
        let built = await snapshot(ring.seq, ring.epoch)
        guard clients[client.peer.connection.id] != nil else { return }
        client.ready = true
        let now = Date().timeIntervalSince1970
        if let events = ring.replay(epoch: epoch, after: lastSeq, now: now) {
            send(client, .welcome(Welcome(epoch: ring.epoch, seq: ring.seq, replay: true, hello: greeting)))
            for event in events { client.peer.send(text: String(decoding: event, as: UTF8.self)) }
            return
        }
        let scoped = StateSnapshot(seq: ring.seq, epoch: ring.epoch, sessions: built.sessions, finished: built.finished, requests: built.requests,
                                   hosted: built.hosted, accounts: built.accounts, mac: built.mac, incidents: built.incidents,
                                   autopilot: built.autopilot, droppedReplies: built.droppedReplies).scoped(to: client.device)
        guard let data = Self.encode(EventEnvelope(seq: nil, at: now, event: .snapshot(scoped))), data.count <= Self.snapshotLimit else {
            return send(client, .welcome(Welcome(epoch: ring.epoch, seq: ring.seq, replay: false, snapshotOverREST: true, hello: greeting)))
        }
        send(client, .welcome(Welcome(epoch: ring.epoch, seq: ring.seq, replay: false, hello: greeting)))
        client.peer.send(text: String(decoding: data, as: UTF8.self))
    }

    private func send(_ client: Client, _ event: ServerEvent) {
        guard let data = Self.encode(EventEnvelope(seq: nil, at: Date().timeIntervalSince1970, event: event)) else { return }
        client.peer.send(text: String(decoding: data, as: UTF8.self))
    }

    static func encode(_ envelope: EventEnvelope) -> Data? { try? Wire.encoder.encode(envelope) }

    /// A state event: numbered, kept in the ring, and sent to every socket that has its welcome.
    public func record(_ event: ServerEvent) {
        let now = Date().timeIntervalSince1970
        var encoded: Data?
        ring.append(at: now) { seq in
            let data = Self.encode(EventEnvelope(seq: seq, at: now, event: event)) ?? Data()
            encoded = data
            return data
        }
        guard let encoded else { return }
        let text = String(decoding: encoded, as: UTF8.self)
        for client in clients.values where client.ready { client.peer.send(text: text) }
    }

    /// Transcript events go only to the sockets named, and never into the ring.
    public func transcript(_ events: [ServerEvent], to sockets: [UInt64]) {
        for id in sockets { if let client = clients[id], client.ready { events.forEach { send(client, $0) } } }
    }

    /// Each ready socket's cursor for a session.
    public func cursors(_ session: SessionKey) -> [UInt64: Cursor?] {
        clients.compactMapValues { $0.ready ? $0.subscriptions[session] : nil }
    }

    public func advance(_ sockets: [UInt64], session: SessionKey, from: Cursor?, to: Cursor) {
        for id in sockets where clients[id]?.subscriptions[session] == .some(from) { clients[id]?.subscriptions[session] = .some(to) }
    }

    public var subscriptions: Set<SessionKey> { Set(clients.values.flatMap(\.subscriptions.keys)) }

    public func presence(_ device: String) -> Presence? {
        clients.values.filter { $0.device == device }.compactMap(\.presence)
            .filter { -$0.at.timeIntervalSinceNow < Self.presenceLease }.max { $0.at < $1.at }
    }

    /// A revoked or replaced device's sockets close with 4401.
    public func close(device: String, reason: String) {
        for client in clients.values where client.device == device { client.peer.close(4401, reason) }
    }

    public func closeAll(code: UInt16, reason: String) {
        for client in clients.values {
            send(client, .bye(reason: reason))
            client.peer.close(code, reason)
        }
    }
}
