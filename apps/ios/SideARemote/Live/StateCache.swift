import Foundation
import SideAProtocol
import SideARemoteShared

/// Open requests are never kept: one answered from a stale copy could be a request that's gone. In the app's own
/// Caches, never the App Group.
struct StateCache: Codable {
    var sessions: [RemoteSession]
    var finished: [SessionKey: FinishedSession]
    var accounts: [RemoteAccount]
    var transcripts: [SessionKey: [TranscriptMessage]]
    var savedAt: Date
    /// What was typed in each session's composer and not sent. Missing in a file written before drafts were kept.
    var drafts: [SessionKey: String]?
    /// New Session's folders, models and commands, so the sheet works while the Mac is out of reach. Missing in older files.
    var projects: [RemoteProject]?
    var options: OptionsList?
    /// Where each kept transcript stood on the Mac, so reopening one asks only for newer rows. Missing in older files.
    var resume: [SessionKey: TranscriptStore.ResumePoint]?

    static let keptTranscripts = 12
    static let keptMessages = 60

    private static let queue = DispatchQueue(label: "com.arnenoori.sidea.remote.cache", qos: .utility)

    static func url(_ macID: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let safe = macID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return caches.appendingPathComponent("state", isDirectory: true).appendingPathComponent("\(safe).json")
    }

    static func load(_ macID: String) -> StateCache? {
        guard let url = url(macID), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StateCache.self, from: data)
    }

    func save(_ macID: String) {
        guard let url = Self.url(macID), let data = try? JSONEncoder().encode(self) else { return }
        Self.queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                RemoteLog.error(.sync, "couldn't save the state cache: \(error.localizedDescription)")
            }
        }
    }

    static func remove(_ macID: String) {
        guard let url = url(macID) else { return }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }
}

extension AppModel {
    func restore(_ cache: StateCache) {
        sessions.replace(cache.sessions, finished: cache.finished)
        accounts.replace(cache.accounts)
        for (session, list) in cache.transcripts {
            transcripts.set(list, hasEarlier: (list.first?.seq ?? 0) > 0, for: session)
            if let point = cache.resume?[session] { transcripts.resume[session] = point }
        }
        for (session, text) in cache.drafts ?? [:] where transcripts.drafts[session, default: ""].isEmpty { transcripts.drafts[session] = text }
        tools.restore(options: cache.options, projects: cache.projects)
        mac.lastSeen = cache.savedAt
    }

    func cache(finished: [SessionKey: FinishedSession]) -> StateCache {
        let recent = sessions.sessions.sorted { ($0.statusAt ?? 0) > ($1.statusAt ?? 0) }.map(\.id)
        var kept: [SessionKey: [TranscriptMessage]] = [:]
        var points: [SessionKey: TranscriptStore.ResumePoint] = [:]
        for id in recent where kept.count < StateCache.keptTranscripts {
            guard let list = transcripts.messages[id], !list.isEmpty else { continue }
            kept[id] = Array(list.suffix(StateCache.keptMessages))
            // Cut at the head, the cursor for the rows before it would point at rows not kept.
            if list.count <= StateCache.keptMessages { points[id] = transcripts.resume[id] }
        }
        let drafts = transcripts.drafts.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return StateCache(sessions: sessions.sessions, finished: finished, accounts: accounts.accounts, transcripts: kept, savedAt: .now,
                          drafts: drafts.isEmpty ? nil : drafts, projects: tools.projects.isEmpty ? nil : tools.projects, options: tools.options,
                          resume: points.isEmpty ? nil : points)
    }
}
