import Foundation
import SideACore
import SideAProtocol

/// Live transcripts for the sessions phones have open (protocol's Transcript subscriptions). Each socket's cursor lives
/// in the hub; on a subscribe, and whenever a session's transcript file changes (at most every 250 ms), the bridge is
/// asked for what's past each cursor, and the rows go out as `transcript.append` and `.replace` with the new cursor,
/// or as `transcript.reset` when there's too much or the view was rebuilt.
@MainActor
final class TranscriptStream {
    static let maxCatchUp = 200
    /// Rows per event, encoded; one big row travels alone.
    static let packBytes = 900 * 1024

    private weak var store: AccountStore?
    private let hub: EventHub
    private var watcher: FolderWatcher?
    private var pending: Set<SessionKey> = []
    private var flushing: Task<Void, Never>?
    private var running: Set<SessionKey> = []
    private var again: Set<SessionKey> = []

    init(store: AccountStore, hub: EventHub) {
        self.store = store; self.hub = hub
        hub.subscribed = { [weak self] _, sessions in
            Task { @MainActor in for session in sessions.keys { self?.update(session) } }
        }
        // The demo watches only the harness's transcripts, never the real ones.
        let home = store.sessions.transcriptSource?.home ?? (store.isDemo ? nil : FileManager.default.homeDirectoryForCurrentUser)
        if let home {
            watcher = FolderWatcher(folders: [".claude/projects", ".codex/sessions"].map { home.appendingPathComponent($0) }) { [weak self] paths in
                self?.changed(paths.filter { $0.hasSuffix(".jsonl") })
            }
        }
    }

    func stop() {
        watcher = nil
        flushing?.cancel()
        hub.subscribed = nil
    }

    /// Transcript files that changed: the subscribed sessions they belong to update together, 250 ms later.
    func changed(_ paths: [String]) {
        guard !paths.isEmpty, let store else { return }
        for session in hub.subscriptions {
            guard let id = RemoteRoutes.conversation(session, store: store), paths.contains(where: { $0.contains(id) }) else { continue }
            pending.insert(session)
        }
        guard !pending.isEmpty, flushing == nil else { return }
        flushing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            flushing = nil
            let sessions = pending
            pending = []
            for session in sessions { update(session) }
        }
    }

    /// One round per session at a time; a change during one runs another after.
    func update(_ session: SessionKey) {
        guard !running.contains(session) else { again.insert(session); return }
        running.insert(session)
        Task {
            await deliver(session)
            running.remove(session)
            if again.remove(session) != nil { update(session) }
        }
    }

    private func deliver(_ session: SessionKey) async {
        guard let store, let id = RemoteRoutes.conversation(session, store: store) else { return }
        let groups = Dictionary(grouping: hub.cursors(session)) { $0.value }.mapValues { $0.map(\.key) }
        for (cursor, clients) in groups {
            guard let cursor else {
                // Nothing held: start from the newest row, and send only what comes after it.
                if let page = try? await page(store, id, ["--limit", "1"]) { hub.advance(clients, session: session, from: nil, to: page.after) }
                continue
            }
            guard let options = Self.catchUp(after: cursor), let page = try? await page(store, id, options) else { continue }
            if page.reset || page.hasMoreAfter || page.messages.count + page.replaced.count > Self.maxCatchUp {
                hub.transcript([.transcriptReset(sessionID: session, generation: page.generation)], to: clients)
                continue
            }
            guard !page.messages.isEmpty || !page.replaced.isEmpty else { continue }
            hub.transcript(Self.events(page, session: session, from: cursor), to: clients)
            hub.advance(clients, session: session, from: cursor, to: page.after)
        }
    }

    /// What the bridge is asked past a phone's cursor; nil for one this Mac never gave out, which the REST route refuses too.
    static func catchUp(after cursor: Cursor) -> [String]? {
        guard IDs.safe(cursor.raw) else { return nil }
        return ["--after", cursor.raw, "--limit", String(maxCatchUp)]
    }

    private func page(_ store: AccountStore, _ id: String, _ options: [String]) async throws -> TranscriptPage {
        try RemoteTranscript.page(try await store.sessions.remoteReply(["show", "--format", "remote"] + options + ["--", id]))
    }

    /// A page as events under `packBytes` each. Only the last carries the page's cursor; the others keep `from`, so a
    /// phone cut off part way resumes from before the page (rows merge by seq) instead of past rows it never got.
    static func events(_ page: TranscriptPage, session: SessionKey, from: Cursor) -> [ServerEvent] {
        let parts = pack(page.messages).map { (append: true, messages: $0) } + pack(page.replaced).map { (append: false, messages: $0) }
        return parts.enumerated().map { index, part in
            let delta = TranscriptDelta(sessionID: session, generation: page.generation, messages: part.messages,
                                        cursor: index == parts.count - 1 ? page.after : from)
            return part.append ? .transcriptAppend(delta) : .transcriptReplace(delta)
        }
    }

    /// Rows in order, split so each event stays under `packBytes`.
    static func pack(_ messages: [TranscriptMessage]) -> [[TranscriptMessage]] {
        var groups: [[TranscriptMessage]] = []
        var current: [TranscriptMessage] = []
        var size = 0
        for message in messages {
            let bytes = (try? RemoteRoutes.encoder.encode(message).count) ?? 0
            if !current.isEmpty, size + bytes > packBytes {
                groups.append(current)
                current = []
                size = 0
            }
            current.append(message)
            size += bytes
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
