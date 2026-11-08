import Foundation
import SideAProtocol

public enum Connection: Sendable, Equatable {
    case idle, connecting, live(since: Timestamp), offline(retryAt: Timestamp, reason: String)
    case unpaired, needsUpdate(mac: Bool)
    /// Every address answered with a TLS key other than the pinned one: pair again. Nothing more is sent.
    case keyChanged

    public var isLive: Bool { if case .live = self { true } else { false } }

    /// What only the Mac's next answer can change: shown until that answer comes, through any retry on the way to it.
    var isTerminal: Bool {
        switch self {
        case .unpaired, .needsUpdate, .keyChanged: true
        default: false
        }
    }
}

/// What became of an outbox item once it left the queue.
public enum OutboxOutcome: Sendable, Equatable {
    /// 2xx, or a replay of one: the response body.
    case delivered(Data)
    /// Someone else answered first: on the Mac, in the terminal, or on another device.
    case answeredElsewhere(RequestResolution?)
    /// 409 `outcome_unknown`: it may or may not have reached the Mac. Never retried; the row offers a Retry with a new key.
    case unknown
    /// The Mac refused it; shown on the row it came from.
    case failed(APIError)
    /// The Mac couldn't be reached before the item expired.
    case notDelivered
}

/// A part of the state that a REST list can refresh on its own.
public enum Slice: String, Sendable, Codable { case sessions, requests, hosted, accounts }

/// Everything the UI shows for one Mac, value-typed so it crosses actors freely.
public struct RemoteState: Sendable, Equatable {
    public var hello: Hello?
    public var connection: Connection = .idle
    public var epoch: String?
    public var seq: Int = 0
    public var sessions: [SessionKey: RemoteSession] = [:]
    public var finished: [SessionKey: FinishedSession] = [:]
    /// How many times the Mac gave up on each session's queued follow-ups.
    public var queueDrops: [SessionKey: Int] = [:]
    /// From the snapshot: what the Mac still remembers giving up on. Announced live by `queueDrops`.
    public var droppedReplies: [DroppedReply] = []
    /// Open only, less those with an answer pending in the outbox.
    public var requests: [RequestID: RemoteRequest] = [:]
    /// The last 50, for "Answered on Mac".
    public var resolved: [RequestID: RequestResolution] = [:]
    public var hosted: [String: HostedSession] = [:]
    public var accounts: [String: RemoteAccount] = [:]
    public var mac: MacState?
    /// Open incidents on the providers' status pages.
    public var incidents: [Incident] = []
    /// From the snapshot and `autopilot.update`; nil from a Mac without `rotation`.
    public var autopilot: AutopilotState?
    /// The latest attention notice per hosted session, until the session changes.
    public var attention: [String: HostedAttention] = [:]
    /// How fresh each slice refreshed over REST is; never moves `seq`.
    public var sliceSeq: [Slice: Int] = [:]
    /// Optimistic: answers and replies not yet confirmed.
    public var pending: [Outbox.Item] = []
    /// Outbox items that left the queue, by item id; the last 50.
    public var outcomes: [String: OutboxOutcome] = [:]
    /// The retries the user tapped, by the first attempt's id, oldest first.
    public var retries: [String: [String]] = [:]
    /// Where the engine's rotation through the endpoint's addresses stood at the last hello. The routed transport picks
    /// the path each request takes, so the one that answered may be another address or the relay.
    public var address: URL?
    /// The Mac said goodbye because it is going to sleep; true until it next answers.
    public var macAsleep = false
    /// Round after round no direct path answered and the relay turned this phone away; false once the Mac answers.
    public var relayRefused = false
    public init() {}

    /// What a row shows for an item: the outcome of its latest retry, or its own; nil while one is in flight.
    public func latestOutcome(of id: String) -> OutboxOutcome? {
        outcomes[retries[id]?.last ?? id]
    }
}

public struct SyncTiming: Sendable {
    public var backoffBase: Double = 0.5
    public var backoffCap: Double = 30
    public var jitter: Double = 0.2
    /// Connected this long, the next drop starts the backoff over.
    public var resetAfter: Double = 60
    public var ping: Double = 15
    public var presence: Double = 30
    public var coalesce: Double = 0.016
    public var tooManyConnections: Double = 10
    public init() {}
    public static let standard = SyncTiming()

    func backoff(_ attempt: Int) -> Double {
        let delay = min(backoffCap, backoffBase * pow(2, Double(min(attempt, 30))))
        return delay * (1 + Double.random(in: -jitter...jitter))
    }
}

/// One paired Mac: its events socket, state, transcript feeds and outbox.
public actor SyncEngine {
    /// As paired, then with the addresses each trusted hello reports.
    public private(set) var endpoint: Endpoint
    public nonisolated let updates: AsyncStream<RemoteState>
    /// The REST client on the address in use, for the calls the engine doesn't wrap.
    public private(set) var client: RemoteClient

    private let outbox: Outbox
    private let info: ClientInfo
    private let timing: SyncTiming
    private let now: @Sendable () -> Timestamp
    private let owner = UUID().uuidString.lowercased()
    private let continuation: AsyncStream<RemoteState>.Continuation

    private var stored = RemoteState()
    private var open: [RequestID: RemoteRequest] = [:]
    private var resolvedOrder: [RequestID] = []
    private var outcomeOrder: [String] = []
    /// The items behind `outcomes`, so a tapped Retry can send one again.
    private var settled: [String: Outbox.Item] = [:]
    private var lastClockKey: Int64 = 0
    private var feeds: [SessionKey: TranscriptFeed] = [:]
    private var foreground = true
    private var viewing: SessionKey?
    /// How many screens `watch` each session.
    private var watchers: [SessionKey: Int] = [:]
    private var run: Task<Void, Never>?
    private var socket: (any SocketConnection)?
    private var waiting: Task<Void, Never>?
    private var addressIndex = 0
    private var awaitingSnapshot = false
    private var bye: String?
    private var draining = false
    /// Something asked for a drain while one ran, so the empty claim that ends it may have missed that item.
    private var drainAgain = false
    /// Runs between a claim that found nothing and what the drain does about it.
    private var afterEmptyClaim: (@Sendable () async -> Void)?
    private var drainAttempt = 0
    private var drainRetry: Task<Void, Never>?
    private var flushing = false
    /// Started and not stopped by its owner: a loop that ended on its own comes back with the foreground.
    private var started = false
    /// Which connection `socket` is; a late pong failure from an earlier one changes nothing.
    private var socketGeneration = 0
    private var relayRefusals = 0

    /// Without a transport, one that pins `endpoint.serverKeyHash` on every connection.
    public init(endpoint: Endpoint, credentials: any CredentialStore, outbox: Outbox, transport: (any Transport)? = nil,
                info: ClientInfo = .current, timing: SyncTiming = .standard, now: @escaping @Sendable () -> Timestamp = { Date().timeIntervalSince1970 }) {
        self.endpoint = endpoint; self.outbox = outbox; self.info = info; self.timing = timing; self.now = now
        client = RemoteClient(endpoint: endpoint, credentials: credentials, transport: transport, info: info)
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public var state: RemoteState { stored }

    public func start() {
        started = true
        guard run == nil else { return }
        run = Task { await self.loop() }
    }

    public func stop() {
        started = false
        halt()
    }

    private func halt() {
        run?.cancel()
        run = nil
        waiting?.cancel()
        socketGeneration += 1
        socket?.close(code: 1000, reason: nil)
        socket = nil
        set(.idle)
    }

    /// Skips the wait before the next attempt: the app came forward or the network changed.
    public func reconnectNow() { waiting?.cancel() }

    // MARK: Presence

    public func setForeground(_ foreground: Bool) async {
        self.foreground = foreground
        if foreground {
            if run == nil {
                if started { start() }
            } else if stored.connection.isLive {
                checkSocket()
            } else {
                reconnectNow()
            }
        }
        await sendPresence()
    }

    public func setViewing(_ session: SessionKey?) async {
        viewing = session
        await sendPresence()
    }

    /// A transcript on screen: its feed, and presence saying it's the one being read. Each call needs its own `unwatch`.
    public func watch(_ session: SessionKey) async -> TranscriptFeed {
        watchers[session, default: 0] += 1
        let feed = transcript(session)
        await setViewing(session)
        return feed
    }

    /// The screen that called `watch` went away. The feed closes with the last screen on its session, and presence
    /// clears only if no other session took over in the meantime.
    public func unwatch(_ session: SessionKey) async {
        let left = (watchers[session] ?? 1) - 1
        watchers[session] = left > 0 ? left : nil
        guard left <= 0 else { return }
        await feeds.removeValue(forKey: session)?.close()
        if viewing == session, watchers[session] == nil { await setViewing(nil) }
    }

    // MARK: Transcripts

    public func transcript(_ session: SessionKey) -> TranscriptFeed {
        if let feed = feeds[session] { return feed }
        let feed = TranscriptFeed(sessionID: session,
                                  fetch: { [weak self] page in
                                      guard let self else { throw CancellationError() }
                                      return try await self.client.transcript(session, page)
                                  },
                                  subscribe: { [weak self] key, cursor in await self?.subscribe([key: cursor]) },
                                  unsubscribe: { [weak self] key in await self?.unsubscribe(key) })
        feeds[session] = feed
        return feed
    }

    public func message(_ session: SessionKey, seq: Int) async throws -> TranscriptMessage {
        var generation = await feeds[session]?.window.generation ?? ""
        if generation.isEmpty { generation = try await client.transcript(session, .latest, limit: 1).generation }
        return try await client.message(session, seq: seq, generation: generation)
    }

    private func subscribe(_ sessions: [SessionKey: Cursor?]) async {
        guard stored.connection.isLive, !sessions.isEmpty else { return }
        await send(.subscribe(sessions: sessions))
    }

    private func unsubscribe(_ session: SessionKey) async {
        // Watched again while the last feed closed: the new one keeps the subscription.
        guard watchers[session] == nil else { return }
        feeds[session] = nil
        if stored.connection.isLive { await send(.unsubscribe(sessions: [session])) }
    }

    // MARK: Mutations

    /// `confirm` is the `X-SideA-Confirm` value the app signed for this answer, when the request's gate needs one.
    /// `mode` with `.allow` also switches the session's mode (`AnswerBody.mode`); its confirm signs
    /// `ConfirmMessage.subject(requestID:allowMode:)`.
    @discardableResult public func answer(_ request: RequestID, _ answer: RemoteAnswer, mode: PermissionMode? = nil,
                                          confirm: String? = nil) async -> Outbox.Item {
        // The same key a notification action uses, so a retried tap is a replay. A tap after a refusal is a new attempt:
        // that key could only replay the refusal, or read as its outcome here.
        let first = Outbox.Item.answerID(request, answer, mode: mode)
        let id = switch stored.outcomes[first] {
        case .failed?, .unknown?, .notDelivered?: "\(first):a\(clockKey())"
        default: first
        }
        return await enqueue(.answer(request, answer, mode: mode, id: id, macID: endpoint.macID, now: now(), confirm: confirm))
    }

    /// A reply to a finished session needs its `FinishedSession.turnID`.
    /// `confirm` signs it (`ConfirmPolicy.reply`), so an item queued past the signature's two minutes is refused and signed again.
    /// `id` is the Idempotency-Key, for a caller that recorded it first.
    @discardableResult public func reply(_ session: SessionKey, _ reply: RemoteReply, confirm: String? = nil,
                                         id: String = UUID().uuidString.lowercased()) async -> Outbox.Item {
        await enqueue(.reply(session, reply, id: id, macID: endpoint.macID, now: now(), confirm: confirm))
    }

    /// `.nextStep` is Stop Before Next Step: stop mail, hosted or not.
    @discardableResult public func interrupt(_ session: SessionKey, when: InterruptRequest.When = .now) async -> Outbox.Item {
        let body = when == .now ? Data() : (try? RemoteClient.encoder.encode(InterruptRequest(when: when))) ?? Data()
        return await enqueue(Outbox.Item(macID: endpoint.macID, path: "/v1/sessions/\(session)/interrupt", body: body, createdAt: now(),
                                         expiresAt: now() + 600))
    }

    /// Take Back: `DELETE /v1/sessions/{id}/mail`, withdrawing what the composer queued. Queued behind that
    /// session's earlier items, so a Take Back right after a Note reaches the Mac after it. The key is
    /// `<session>:takeback:<n>`, `n` from the clock so it is never reused across launches.
    @discardableResult public func takeBack(sessionID session: SessionKey) async -> Outbox.Item {
        await enqueue(Outbox.Item(id: "\(session):takeback:\(clockKey())", macID: endpoint.macID, method: "DELETE", path: "/v1/sessions/\(session)/mail",
                                         createdAt: now(), expiresAt: now() + 600))
    }

    /// From the clock, so a key made with it is never reused across launches.
    private func clockKey() -> Int64 {
        lastClockKey = max(lastClockKey + 1, Int64(now() * 1000))
        return lastClockKey
    }

    /// Retry, from the user's tap only and never on its own: the item settled as `.unknown` or `.notDelivered`
    /// goes again under a new key, `<first id>:r<n>`. The first attempt and its outcome stay; `state.retries`
    /// links them. For an answer this is harmless: if the first one landed, the retry gets `.answeredElsewhere`
    /// and the row reads Answered. Nil when the item didn't settle that way, or has aged out of `outcomes`.
    /// `confirm` is a fresh `X-SideA-Confirm` for an item that carried one: a signature lasts two minutes, so the tap
    /// that retries signs again.
    @discardableResult public func retry(itemID: String, confirm: String? = nil) async -> Outbox.Item? {
        guard let item = settled[itemID], [.unknown, .notDelivered].contains(stored.outcomes[itemID]) else { return nil }
        let first = item.retryOf ?? item.id
        let again = item.retried((stored.retries[first]?.count ?? 0) + 1, now: now(), confirm: confirm)
        stored.retries[first, default: []].append(again.id)
        return await enqueue(again)
    }

    /// Not queued: it needs the Mac now. `confirm` signs `ConfirmMessage.subject(start:)`, with the confirm key for what
    /// `ConfirmPolicy.start` says takes Face ID.
    public func startHosted(_ start: StartHosted, confirm: String? = nil) async throws -> HostedSession {
        try await client.post("/v1/hosted", json: start, confirm: confirm)
    }

    public func upload(_ data: Data, mime: String) async throws -> Upload {
        let request = try await client.request("POST", "/v1/uploads", body: data, contentType: mime, idempotencyKey: UUID().uuidString.lowercased())
        return try JSONDecoder().decode(Upload.self, from: try await client.send(request).0)
    }

    /// `GET /v1/state`: a complete snapshot, so it replaces everything and sets `epoch` and `seq`,
    /// unless the stream is already further along in the same epoch.
    public func refresh() async throws {
        let snapshot: StateSnapshot = try await client.get("/v1/state")
        guard snapshot.epoch != stored.epoch || snapshot.seq >= stored.seq else { return }
        apply(snapshot)
        publish()
    }

    // REST slices: each refreshes its part of the state and never moves `seq`.

    public func refreshSessions() async throws {
        let list = try await client.sessions()
        guard fresher(list.seq, .sessions) else { return }
        stored.sessions = Self.keyed(list.sessions, \.id)
        stored.finished = Self.keyed(list.finished, \.sessionID)
        publish()
    }

    public func refreshRequests() async throws {
        let list = try await client.requests()
        guard fresher(list.seq, .requests) else { return }
        open = Self.keyed(list.requests, \.id)
        publish()
    }

    public func refreshHosted() async throws {
        let list = try await client.hosted()
        guard fresher(list.seq, .hosted) else { return }
        stored.hosted = Self.keyed(list.hosted, \.name)
        publish()
    }

    public func refreshAccounts() async throws { apply(try await client.accounts()) }

    /// Switches the active account and applies the list the Mac answers with.
    public func useAccount(_ id: String, confirm: String) async throws { apply(try await client.useAccount(id, confirm: confirm)) }

    /// Changes an account's priority and applies the list the Mac answers with.
    public func setPriority(_ id: String, _ priority: PriorityLevel, confirm: String) async throws { apply(try await client.setPriority(id, priority, confirm: confirm)) }

    /// Changes an account's Auto and applies the list the Mac answers with.
    public func setAuto(_ id: String, _ enabled: Bool, confirm: String) async throws { apply(try await client.setAuto(id, enabled, confirm: confirm)) }

    private func apply(_ list: AccountList) {
        guard fresher(list.seq, .accounts) else { return }
        stored.accounts = Self.keyed(list.accounts, \.id)
        publish()
    }

    /// A list replaces its slice only when newer than both `seq` and the slice's last refresh.
    private func fresher(_ seq: Int, _ slice: Slice) -> Bool {
        guard seq > stored.seq, seq > stored.sliceSeq[slice] ?? -1 else { return false }
        stored.sliceSeq[slice] = seq
        return true
    }

    private static func keyed<T, K: Hashable>(_ values: [T], _ key: KeyPath<T, K>) -> [K: T] {
        Dictionary(values.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { $1 })
    }

    private func enqueue(_ item: Outbox.Item) async -> Outbox.Item {
        await outbox.enqueue(item)
        await reloadPending()
        Task { await self.drain() }
        return item
    }

    // MARK: Connection

    enum Next: Equatable { case stop(Connection), now, after(Double, String), backoff(String), nextAddress(String, keyChanged: Bool = false, refused: Bool = false) }

    private func loop() async {
        var attempt = 0
        // Addresses in this round that offered a key other than the pinned one.
        var keyChanged = 0
        var refused = false
        while !Task.isCancelled {
            await reloadPending()
            let token: String?
            do { token = try await client.credentials.token(for: endpoint.macID) } catch { token = nil }
            if Task.isCancelled { return }
            guard token != nil else { run = nil; return set(.unpaired) }
            if !stored.connection.isLive, !stored.connection.isTerminal { set(.connecting) }
            let opened = now()
            var next = await greet()
            if next == nil {
                keyChanged = 0
                next = await connect()
            }
            // Halted while awaiting: `socket`, `run` and the connection may already be the next run's.
            if Task.isCancelled { return }
            socket = nil
            if now() - opened >= timing.resetAfter { attempt = 0 }
            let delay: Double
            switch next! {
            case .stop(let connection): run = nil; return set(connection)
            case .now: continue
            case .nextAddress(let reason, let changed, let turnedAway):
                // Try the Mac's other addresses before waiting; wait once all of them have failed.
                if changed { keyChanged += 1 }
                if turnedAway { refused = true }
                addressIndex += 1
                client = client.at(endpoint.addresses[addressIndex % endpoint.addresses.count])
                if addressIndex % endpoint.addresses.count != 0 { continue }
                // One stray network can sit in the middle; every address saying so means the Mac's key is new.
                if keyChanged == endpoint.addresses.count { run = nil; return set(.keyChanged) }
                keyChanged = 0
                relayRefusals = refused ? relayRefusals + 1 : 0
                refused = false
                if relayRefusals >= Self.refusalsToOfferPairing, !stored.relayRefused { stored.relayRefused = true }
                delay = timing.backoff(attempt)
                attempt += 1
                offline(retryAt: now() + delay, reason: reason)
            case .after(let seconds, let reason): delay = seconds; offline(retryAt: now() + seconds, reason: reason)
            case .backoff(let reason):
                delay = timing.backoff(attempt)
                attempt += 1
                offline(retryAt: now() + delay, reason: reason)
            }
            let wait = Task { _ = try? await Task.sleep(for: .seconds(delay)) }
            waiting = wait
            await wait.value
        }
    }

    /// Rounds of the Mac's addresses before a relay's refusal is worth offering Pair Again for: a relay that lost its
    /// device list says the same until the Mac reconnects to it.
    static let refusalsToOfferPairing = 3

    private func offline(retryAt: Timestamp, reason: String) {
        if !stored.connection.isTerminal { set(.offline(retryAt: retryAt, reason: reason)) }
    }

    /// `GET /v1/hello` first: is the Mac there, can we talk, are we still paired.
    private func greet() async -> Next? {
        let hello: Hello
        do { hello = try await client.hello() } catch let failure as RemoteFailure {
            if failure.status == 503 { return .backoff(failure.error.message) }
            return failure.status == 426 ? .stop(.needsUpdate(mac: failure.error.code == .upgradeMac)) : .backoff(failure.error.message)
        } catch is ServerKeyChanged {
            return .nextAddress("\(endpoint.name) has a new security key", keyChanged: true)
        } catch let refused as RelayRefused {
            return .nextAddress(refused.localizedDescription, refused: true)
        } catch {
            return .nextAddress(error.localizedDescription)
        }
        guard !Task.isCancelled else { return .stop(.idle) }
        stored.hello = hello
        stored.address = client.address
        stored.macAsleep = false
        stored.relayRefused = false
        relayRefusals = 0
        // A trusted hello's addresses (a LAN one learned after pairing) join the rotation now, not at next launch. Only
        // one that knows this phone carries any.
        if hello.paired == true {
            await client.transport.learned(hello.endpoints)
            let learned = endpoint.updated(with: hello.endpoints)
            if learned != endpoint {
                endpoint = learned
                addressIndex = learned.addresses.firstIndex(of: client.address) ?? 0
            }
        }
        publish()
        if let side = hello.needsUpdate(clientBuild: info.build) { return .stop(.needsUpdate(mac: side == .mac)) }
        if hello.paired == false { return .stop(.unpaired) }
        if !hello.remoteOn { return .backoff("Remote is off on \(endpoint.name)") }
        return nil
    }

    private func connect() async -> Next {
        let socket: any SocketConnection
        do { socket = try await client.socket("/v1/ws/events") } catch { return .backoff(error.localizedDescription) }
        guard !Task.isCancelled else {
            socket.close(code: 1000, reason: nil)
            return .stop(.idle)
        }
        self.socket = socket
        bye = nil
        socketGeneration += 1
        let generation = socketGeneration
        let keepalive = Task { await self.keepalive(socket, generation) }
        defer {
            keepalive.cancel()
            if !Task.isCancelled { socketGeneration += 1 }
        }
        do {
            try await socket.send(.text(Self.text(.hello(epoch: stored.epoch, lastSeq: stored.epoch == nil ? nil : stored.seq,
                                                         capabilities: info.capabilities))))
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard !Task.isCancelled else { return .stop(.idle) }
                guard case .text(let text) = message,
                      let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: Data(text.utf8)) else { continue }
                if let next = await handle(envelope) {
                    socket.close(code: 1000, reason: nil)
                    return next
                }
            }
            return .stop(.idle)
        } catch let closed as SocketClosed {
            return Self.next(after: closed, bye: bye)
        } catch {
            return .backoff(error.localizedDescription)
        }
    }

    static func next(after closed: SocketClosed, bye: String?) -> Next {
        switch closed.code {
        case 1000: .stop(.idle)
        case 4008: .now
        case 4401: .stop(.unpaired)
        case 4426: .stop(.needsUpdate(mac: closed.reason?.contains("mac") ?? false))
        case 4429: .after(10, "Too many connections to the Mac")
        case 1001: .backoff(bye.map { "Side A on the Mac closed (\($0))" } ?? "Side A on the Mac closed")
        default: .backoff(closed.reason.flatMap { $0.isEmpty ? nil : $0 } ?? "Connection closed (\(closed.code))")
        }
    }

    private func keepalive(_ socket: any SocketConnection, _ generation: Int) async {
        var sincePresence = 0.0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(timing.ping))
            guard !Task.isCancelled else { return }
            do { try await socket.sendPing() } catch { return lost(socket, generation) }
            sincePresence += timing.ping
            if sincePresence >= timing.presence {
                sincePresence = 0
                await sendPresence()
            }
        }
    }

    /// Back in front while "live": the socket may have died with the app suspended, so it answers a ping now.
    private func checkSocket() {
        guard let socket else { return }
        let generation = socketGeneration
        Task {
            do { try await socket.sendPing() } catch { self.lost(socket, generation) }
        }
    }

    /// No pong: a half-open socket never ends by itself, so it's closed here and the loop connects again.
    private func lost(_ socket: any SocketConnection, _ generation: Int) {
        guard generation == socketGeneration else { return }
        set(.connecting)
        socket.close(code: 4008, reason: "no pong")
    }

    /// Applies one frame; returns what to do when the socket must be dropped.
    private func handle(_ envelope: EventEnvelope) async -> Next? {
        let event = envelope.event
        switch event {
        case .welcome(let welcome):
            stored.hello = welcome.hello
            // The epoch changes only with the snapshot, so a drop before it reconnects as the old client.
            awaitingSnapshot = !welcome.replay || welcome.epoch != stored.epoch
            stored.macAsleep = false
            stored.relayRefused = false
            set(.live(since: now()))
            if welcome.snapshotOverREST {
                do {
                    let snapshot = try await client.get("/v1/state", as: StateSnapshot.self)
                    guard !Task.isCancelled else { return .stop(.idle) }
                    apply(snapshot)
                } catch { return .backoff(error.localizedDescription) }
                publish()
            }
            var cursors: [SessionKey: Cursor?] = [:]
            for (key, feed) in feeds { cursors[key] = await feed.cursor }
            guard !Task.isCancelled else { return .stop(.idle) }
            await subscribe(cursors)
            await sendPresence()
            drainAttempt = 0
            Task { await self.drain() }
            return nil
        case .snapshot(let snapshot):
            apply(snapshot)
            publish()
            return nil
        case .bye(let reason):
            bye = reason
            if reason == ServerEvent.byeSleep { stored.macAsleep = true }
            return nil
        case .transcriptAppend(let delta), .transcriptReplace(let delta):
            await feeds[delta.sessionID]?.receive(event)
            return nil
        case .transcriptReset(let session, _):
            await feeds[session]?.receive(event)
            return nil
        default:
            break
        }
        guard let seq = envelope.seq else { return nil }
        guard !awaitingSnapshot, seq > stored.seq else { return nil }
        // A skipped event: reconnect with lastSeq and let the server repair from its ring or a snapshot.
        guard seq == stored.seq + 1 else { return .now }
        stored.seq = seq
        // A slice refreshed over REST already reflects events up to its seq.
        if let slice = Self.slice(of: event), seq <= stored.sliceSeq[slice] ?? -1 { return nil }
        apply(event)
        publish()
        return nil
    }

    static func slice(of event: ServerEvent) -> Slice? {
        switch event {
        case .sessionUpsert, .sessionRemove, .finishedAdd, .finishedResolve: .sessions
        case .requestAdd, .requestResolve: .requests
        case .hostedUpsert, .hostedRemove, .hostedAttention: .hosted
        case .usageUpdate, .accountRemove: .accounts
        default: nil
        }
    }

    private func apply(_ snapshot: StateSnapshot) {
        awaitingSnapshot = false
        stored.seq = snapshot.seq
        stored.epoch = snapshot.epoch
        stored.sliceSeq = [:]
        stored.sessions = Self.keyed(snapshot.sessions, \.id)
        stored.finished = Self.keyed(snapshot.finished, \.sessionID)
        open = Self.keyed(snapshot.requests, \.id)
        stored.hosted = Self.keyed(snapshot.hosted, \.name)
        stored.accounts = Self.keyed(snapshot.accounts, \.id)
        stored.mac = snapshot.mac
        stored.incidents = snapshot.incidents ?? []
        stored.autopilot = snapshot.autopilot
        stored.droppedReplies = snapshot.droppedReplies ?? []
    }

    private func apply(_ event: ServerEvent) {
        switch event {
        case .sessionUpsert(let session): stored.sessions[session.id] = session
        case .sessionRemove(let id, _): stored.sessions[id] = nil
        case .requestAdd(let request): open[request.id] = request
        case .requestResolve(let resolution): resolve(resolution)
        case .finishedAdd(let finished): stored.finished[finished.sessionID] = finished
        case .finishedResolve(let session, let reason):
            stored.finished[session] = nil
            if reason == ServerEvent.finishedQueueDropped { stored.queueDrops[session, default: 0] += 1 }
        case .usageUpdate(let accounts): for account in accounts { stored.accounts[account.id] = account }
        case .accountRemove(let id): stored.accounts[id] = nil
        case .hostedUpsert(let hosted): stored.hosted[hosted.name] = hosted; stored.attention[hosted.name] = nil
        case .hostedRemove(let name): stored.hosted[name] = nil; stored.attention[name] = nil
        case .hostedAttention(let attention): stored.attention[attention.name] = attention
        case .macUpdate(let mac): stored.mac = mac
        case .incidentUpdate(let incidents): stored.incidents = incidents
        case .autopilotUpdate(let autopilot): stored.autopilot = autopilot
        default: break
        }
    }

    private func resolve(_ resolution: RequestResolution) {
        open[resolution.requestID] = nil
        stored.resolved[resolution.requestID] = resolution
        resolvedOrder.append(resolution.requestID)
        while resolvedOrder.count > 50 { stored.resolved[resolvedOrder.removeFirst()] = nil }
        // An answer still queued here lost the race; one from a device may be ours, which its response settles.
        guard resolution.by != .device else { return }
        for item in stored.pending where item.answering == resolution.requestID {
            stored.pending.removeAll { $0.id == item.id }
            record(item.id, .answeredElsewhere(resolution))
            let outbox = outbox
            Task { await outbox.remove(item.id) }
        }
    }

    // MARK: Outbox

    func drain() async {
        guard stored.connection.isLive else { return }
        guard !draining else {
            drainAgain = true
            return
        }
        draining = true
        drainAgain = false
        defer { draining = false }
        // Targets whose oldest item is waiting to be retried: only their later items wait with it.
        var held: Set<String> = []
        var retryIn: Double?
        defer {
            if let retryIn {
                drainRetry?.cancel()
                drainRetry = Task {
                    try? await Task.sleep(for: .seconds(retryIn))
                    if !Task.isCancelled { await self.drain() }
                }
            }
        }
        while stored.connection.isLive {
            // Claimed in one transaction, so another process (a notification action, an intent) never posts it too.
            guard var item = await outbox.claim(for: endpoint.macID, by: owner, now: now(), skipping: held) else {
                await afterEmptyClaim?()
                guard drainAgain else { break }
                drainAgain = false
                continue
            }
            if item.expiresAt <= now() {
                await finish(item, .notDelivered)
                continue
            }
            do {
                var request = try await client.request(item.method, item.path, body: item.body.isEmpty ? nil : item.body, idempotencyKey: item.id)
                if let confirm = item.confirm { request.setValue(confirm, forHTTPHeaderField: ConfirmSignature.header) }
                await finish(item, .delivered(try await client.send(request).0))
                drainAttempt = 0
            } catch let failure as RemoteFailure where failure.status == 401
                        && [.confirmRequired, .confirmInvalid].contains(failure.error.code) {
                // The answer needed a signature it didn't carry (or one that ran out): the device is still paired.
                await finish(item, .failed(failure.error))
            } catch let failure as RemoteFailure where failure.status == 401 {
                await outbox.release(item.id)
                halt()
                set(.unpaired)
                return
            } catch let failure as RemoteFailure where failure.status == 409 && failure.error.code == .alreadyResolved {
                await finish(item, .answeredElsewhere(nil))
            } catch let failure as RemoteFailure where failure.status == 409 && failure.error.code == .outcomeUnknown {
                await finish(item, .unknown)
            } catch let failure as RemoteFailure where !failure.retryable {
                await finish(item, .failed(failure.error))
            } catch {
                item.attempts += 1
                item.lastError = (error as? RemoteFailure)?.error ?? APIError(code: ErrorCode(rawValue: "network"), message: error.localizedDescription, retryable: true)
                await outbox.update(item)
                await outbox.release(item.id)
                await reloadPending()
                held.insert(item.target)
                if retryIn == nil {
                    retryIn = (error as? RemoteFailure)?.retryAfter ?? timing.backoff(drainAttempt)
                    drainAttempt += 1
                }
            }
        }
    }

    func setAfterEmptyClaim(_ hook: (@Sendable () async -> Void)?) { afterEmptyClaim = hook }

    private func finish(_ item: Outbox.Item, _ outcome: OutboxOutcome) async {
        // Taken, or already settled: the Mac no longer has it open, whichever of the response and its event comes first.
        switch outcome {
        case .delivered, .answeredElsewhere: if let request = item.answering { open[request] = nil }
        default: break
        }
        await outbox.remove(item.id)
        settled[item.id] = item
        record(item.id, outcome)
        await reloadPending()
    }

    private func record(_ id: String, _ outcome: OutboxOutcome) {
        stored.outcomes[id] = outcome
        outcomeOrder.append(id)
        while outcomeOrder.count > 50 {
            let old = outcomeOrder.removeFirst()
            stored.outcomes[old] = nil
            settled[old] = nil
        }
    }

    private func reloadPending() async {
        stored.pending = await outbox.items(for: endpoint.macID)
        publish()
    }

    // MARK: Plumbing

    private func sendPresence() async {
        guard stored.connection.isLive else { return }
        await send(.presence(foreground: foreground, viewing: viewing))
    }

    private func send(_ message: ClientMessage) async {
        try? await socket?.send(.text(Self.text(message)))
    }

    static func text(_ message: ClientMessage) -> String {
        String(decoding: (try? RemoteClient.encoder.encode(message)) ?? Data(), as: UTF8.self)
    }

    private func set(_ connection: Connection) {
        guard stored.connection != connection else { return }
        stored.connection = connection
        publish()
    }

    /// Sends the state at most every `coalesce` seconds.
    private func publish() {
        let answering = Set(stored.pending.compactMap(\.answering))
        stored.requests = open.filter { !answering.contains($0.key) }
        guard !flushing else { return }
        flushing = true
        Task {
            if timing.coalesce > 0 { try? await Task.sleep(for: .seconds(timing.coalesce)) }
            flush()
        }
    }

    private func flush() {
        flushing = false
        continuation.yield(stored)
    }
}
