import Foundation
import SideAProtocol

public struct TranscriptWindow: Sendable, Equatable {
    public var generation: String
    /// Contiguous by seq.
    public var messages: [TranscriptMessage]
    public var hasEarlier: Bool
    public var repairing: Bool
    /// Where the rows before the window start and where the Mac's view of the session stood at its last row: what a phone
    /// keeps with the rows it saves, so the next open asks only for what came after.
    public var before: Cursor?
    public var after: Cursor?
    public init(generation: String = "", messages: [TranscriptMessage] = [], hasEarlier: Bool = false, repairing: Bool = false,
                before: Cursor? = nil, after: Cursor? = nil) {
        self.generation = generation; self.messages = messages; self.hasEarlier = hasEarlier; self.repairing = repairing
        self.before = before; self.after = after
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
    private var watchers: [UUID: AsyncStream<TranscriptWindow>.Continuation] = [:]
    private var before: Cursor?
    /// The latest `after` cursor from a page or a delta; sent back unchanged, never built here.
    public private(set) var cursor: Cursor?
    private var buffered: [ServerEvent] = []
    private var repair: Task<Void, Never>?
    private var closed = false
    /// A reset dropped the cursor and the newest page hasn't arrived: the window held is the old generation's, shown
    /// until it does, and nothing streams into it.
    private var reloading = false
    /// The cursor a reset dropped: the rows held are still the Mac's unless it says otherwise, so a reload asks from here.
    private var stale: Cursor?
    private var reload: Task<Void, Never>?
    private let reloadWait: Duration

    init(sessionID: SessionKey, reloadWait: Duration = .milliseconds(500), fetch: @escaping Fetch,
         subscribe: @escaping @Sendable (SessionKey, Cursor?) async -> Void, unsubscribe: @escaping @Sendable (SessionKey) async -> Void) {
        self.sessionID = sessionID; self.reloadWait = reloadWait; self.fetch = fetch; self.subscribe = subscribe; self.unsubscribe = unsubscribe
    }

    /// The highest contiguous seq held; -1 before anything is.
    public var last: Int { window.messages.last?.seq ?? -1 }
    var loaded: Bool { !window.generation.isEmpty && !reloading }

    /// Rows saved from an earlier open, shown at once and brought up to date by `loadLatest` from their cursor. Nothing
    /// happens once the feed holds rows of its own.
    public func seed(_ saved: TranscriptWindow) {
        guard window.messages.isEmpty, !saved.messages.isEmpty, let after = saved.after, !saved.generation.isEmpty else { return }
        window = saved
        window.repairing = false
        before = saved.before
        cursor = after
    }

    /// The newest page, or, when rows are already held, only what came after them: the rows on screen are kept as they are
    /// (same ids, same order) and the new ones join their end, so a reconnect or a reopen never rebuilds what is shown.
    public func loadLatest() async throws {
        let resumed = try await resume()
        if let page = resumed.page { return await install(page) }
        if !resumed.done { await install(try await fetch(.latest)) }
    }

    static let resumePages = 40

    /// Catches the window up from its cursor. `done` when it did; otherwise `page` is the newest page the Mac gave instead
    /// (another generation), if it gave one, and the held rows are not the Mac's any more.
    private func resume() async throws -> (done: Bool, page: TranscriptPage?) {
        guard !window.messages.isEmpty, let start = cursor ?? stale else { return (false, nil) }
        var from = start
        for _ in 0..<Self.resumePages {
            let page = try await fetch(.after(from))
            if page.reset || page.generation != window.generation { return (false, page) }
            merge(page.messages)
            replaceHeld(page.replaced)
            cursor = page.after
            from = page.after
            if !page.hasMoreAfter {
                stale = nil
                reloading = false
                publish()
                await subscribe(sessionID, cursor)
                return (true, nil)
            }
        }
        return (false, nil)
    }

    private func install(_ page: TranscriptPage) async {
        window = TranscriptWindow(generation: page.generation, messages: page.messages, hasEarlier: page.before != nil)
        before = page.before
        cursor = page.after
        stale = nil
        reloading = false
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
        reload?.cancel()
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

    /// Starts again from the newest page. The old window stays on screen until it arrives, and a page that can't be had
    /// is asked for again until it can: nothing else would, as every append is dropped meanwhile.
    func reset() async {
        repair = nil
        buffered = []
        reloading = true
        window.repairing = false
        stale = cursor ?? stale
        cursor = nil
        publish()
        do { try await loadLatest() } catch { startReload() }
    }

    /// The Mac is reachable again: ask for the page now rather than when the wait ends.
    func reloadNow() {
        guard reloading, !closed else { return }
        startReload()
    }

    private func startReload() {
        reload?.cancel()
        reload = Task {
            var wait = reloadWait
            while reloading, !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard reloading, !Task.isCancelled else { return }
                do { try await loadLatest() } catch { wait = min(wait * 2, .seconds(8)) }
            }
        }
    }

    private func startRepair() {
        window.repairing = true
        publish()
        repair = Task { await self.repairNow() }
    }

    private func repairNow() async {
        defer { if !Task.isCancelled { repair = nil } }
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

    private func publish() {
        window.before = before
        window.after = cursor ?? stale
        for watcher in watchers.values { watcher.yield(window) }
    }
}
