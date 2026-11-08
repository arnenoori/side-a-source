import Foundation
import SideAProtocol

public struct TranscriptWindow: Sendable, Equatable {
    public var generation: String
    /// Contiguous by seq.
    public var messages: [TranscriptMessage]
    public var hasEarlier: Bool
    public var repairing: Bool
    public init(generation: String = "", messages: [TranscriptMessage] = [], hasEarlier: Bool = false, repairing: Bool = false) {
        self.generation = generation; self.messages = messages; self.hasEarlier = hasEarlier; self.repairing = repairing
    }
}

/// One session's transcript: a window of messages kept correct against the paged API. The stream
/// is for speed; whenever it skips, the window is repaired from `after` pages.
public actor TranscriptFeed {
    public let sessionID: SessionKey
    public private(set) var window = TranscriptWindow()

    typealias Fetch = @Sendable (RemoteClient.Page) async throws -> TranscriptPage
    private let fetch: Fetch
    private let subscribe: @Sendable (SessionKey, Cursor?) async -> Void
    private let unsubscribe: @Sendable (SessionKey) async -> Void
    /// One per `windows()` stream still open.
    private var watchers: [UUID: AsyncStream<TranscriptWindow>.Continuation] = [:]
    private var before: Cursor?
    /// The latest `after` cursor from a page or a delta; sent back unchanged, never built here.
    public private(set) var cursor: Cursor?
    private var buffered: [ServerEvent] = []
    private var repair: Task<Void, Never>?
    private var closed = false

    init(sessionID: SessionKey, fetch: @escaping Fetch, subscribe: @escaping @Sendable (SessionKey, Cursor?) async -> Void,
         unsubscribe: @escaping @Sendable (SessionKey) async -> Void) {
        self.sessionID = sessionID; self.fetch = fetch; self.subscribe = subscribe; self.unsubscribe = unsubscribe
    }

    /// The highest contiguous seq held; -1 before anything is.
    public var last: Int { window.messages.last?.seq ?? -1 }
    var loaded: Bool { !window.generation.isEmpty }

    public func loadLatest() async throws {
        let page = try await fetch(.latest)
        window = TranscriptWindow(generation: page.generation, messages: page.messages, hasEarlier: page.before != nil)
        before = page.before
        cursor = page.after
        publish()
        await subscribe(sessionID, cursor)
    }

    public func loadEarlier() async throws {
        guard let before, loaded else { return }
        let page: TranscriptPage
        do { page = try await fetch(.before(before)) } catch let failure as RemoteFailure where failure.status == 410 { return await reset() }
        guard page.generation == window.generation, !page.reset else { return await reset() }
        let first = window.messages.first?.seq ?? Int.max
        window.messages.insert(contentsOf: page.messages.filter { $0.seq < first }, at: 0)
        self.before = page.before
        window.hasEarlier = page.before != nil
        publish()
    }

    /// Unsubscribes; the engine forgets this feed.
    public func close() async {
        closed = true
        repair?.cancel()
        for watcher in watchers.values { watcher.finish() }
        watchers = [:]
        await unsubscribe(sessionID)
    }

    /// Each window from now on, until `close`. Every caller gets its own stream: one that ends, as when its task is
    /// cancelled, ends no other's.
    public func windows() -> AsyncStream<TranscriptWindow> {
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptWindow.self, bufferingPolicy: .bufferingNewest(1))
        guard !closed else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        watchers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        return stream
    }

    private func drop(_ watcher: UUID) { watchers[watcher] = nil }

    /// Waits for a repair in progress, for tests and callers that need a settled window.
    public func settled() async { await repair?.value }

    /// A `transcript.*` event for this session.
    func receive(_ event: ServerEvent) async {
        guard !closed else { return }
        if repair != nil, window.repairing {
            if case .transcriptReset = event { repair?.cancel() } else { return buffered.append(event) }
        }
        switch event {
        case .transcriptAppend(let delta):
            guard loaded else { return }
            guard delta.generation == window.generation else { return await reset() }
            guard let first = delta.messages.first else { return }
            if first.seq <= last + 1 {
                merge(delta.messages)
                cursor = delta.cursor
                publish()
            } else {
                buffered = [event]
                startRepair()
            }
        case .transcriptReplace(let delta):
            guard loaded, delta.generation == window.generation else { return }
            replaceHeld(delta.messages)
            cursor = delta.cursor
            publish()
        case .transcriptReset:
            await reset()
        default:
            break
        }
    }

    /// Drops the window and starts again from the newest page.
    func reset() async {
        repair = nil
        buffered = []
        window = TranscriptWindow()
        cursor = nil
        publish()
        try? await loadLatest()
    }

    private func startRepair() {
        window.repairing = true
        publish()
        repair = Task { await self.repairNow() }
    }

    private func repairNow() async {
        defer { if !Task.isCancelled { repair = nil } }
        // Follow `after` until the server has nothing newer, then apply what arrived meanwhile.
        for _ in 0..<50 {
            do {
                while let from = cursor {
                    let page = try await fetch(.after(from))
                    guard !Task.isCancelled else { return }
                    guard page.generation == window.generation, !page.reset else { return await reset() }
                    merge(page.messages)
                    replaceHeld(page.replaced)
                    cursor = page.after
                    if !page.hasMoreAfter { break }
                }
            } catch let failure as RemoteFailure where failure.status == 410 {
                return await reset()
            } catch {
                // Try again on the next delta; what is held stays correct, just behind.
                buffered = []
                window.repairing = false
                publish()
                return
            }
            let pending = buffered
            buffered = []
            var gap = false
            for event in pending {
                switch event {
                case .transcriptAppend(let delta) where delta.generation == window.generation:
                    if let first = delta.messages.first, first.seq > last + 1 {
                        gap = true
                        buffered.append(event)
                    } else if delta.messages.last.map({ $0.seq > last }) ?? false {
                        // Only a delta that reaches past the pages adds anything; its cursor is then the newest.
                        merge(delta.messages)
                        cursor = delta.cursor
                    }
                case .transcriptReplace(let delta) where delta.generation == window.generation:
                    replaceHeld(delta.messages)
                case .transcriptAppend, .transcriptReplace:
                    return await reset()
                default:
                    break
                }
            }
            if !gap { break }
        }
        window.repairing = false
        publish()
    }

    /// Adds messages that continue the window and replaces the ones it already holds.
    private func merge(_ messages: [TranscriptMessage]) {
        for message in messages.sorted(by: { $0.seq < $1.seq }) {
            if message.seq == last + 1 || window.messages.isEmpty {
                window.messages.append(message)
            } else if let first = window.messages.first?.seq, message.seq >= first, message.seq <= last {
                window.messages[message.seq - first] = message
            }
        }
    }

    private func replaceHeld(_ messages: [TranscriptMessage]) {
        guard let first = window.messages.first?.seq else { return }
        for message in messages where message.seq >= first && message.seq <= last { window.messages[message.seq - first] = message }
    }

    private func publish() { for watcher in watchers.values { watcher.yield(window) } }
}
