import Foundation
import SideACore
import SideAProtocol

/// The new conversation's id is known only once its agent registers, so until then a link waits here and on its tmux
/// session (`@sidea_handoff`, which outlives a restart of Side A), then goes to the bridge's index for good.
@MainActor
final class HandoffLinks {
    struct Record: Codable, Sendable, Equatable {
        let id: String
        let fromConversation: String
        var toConversation: String?
        let fromAgent: String
        let toAgent: String
        let fromModel: String?
        let toModel: String?
        let at: Double
        let mode: String?
        var hosted: String?
        /// Going back resumes the earlier conversation; indexing that link would make each the other's parent.
        // swiftlint:disable:next discouraged_optional_boolean -- records saved before going back existed have no such key
        var resumed: Bool?
    }

    static let keepDays: Double = 30
    private static var all: [String: HandoffLinks] = [:]

    static func of(_ store: AccountStore) -> HandoffLinks {
        if let known = all[store.root.path] { return known }
        let made = HandoffLinks(folder: store.root.appendingPathComponent("handoffs"))
        all[store.root.path] = made
        return made
    }

    let folder: URL
    private(set) var recorded: [String: Record] = [:]
    private(set) var pending: [String: Record] = [:]
    private var loaded = false
    private var loadTask: Task<Void, Never>?

    init(folder: URL) { self.folder = folder }

    nonisolated static func valid(_ id: String) -> Bool {
        id.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }

    func fullFile(_ id: String) -> URL { folder.appendingPathComponent("\(id).md") }
    private func sentFile(_ id: String) -> URL { folder.appendingPathComponent("\(id).sent.md") }
    private func recordFile(_ id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    func save(_ record: Record, full: String, sent: String) throws {
        try PrivateFile.writeText(full, to: fullFile(record.id))
        try PrivateFile.writeText(sent, to: sentFile(record.id))
        try PrivateFile.write(record, to: recordFile(record.id))
        prune()
    }

    /// A handoff that never started: its files go and nothing links to it.
    func remove(_ id: String) {
        guard Self.valid(id) else { return }
        for file in [fullFile(id), sentFile(id), recordFile(id)] { try? FileManager.default.removeItem(at: file) }
        pending = pending.filter { $0.value.id != id }
        recorded = recorded.filter { $0.value.id != id }
    }

    func prune(now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(changed) > Self.keepDays * 86400 { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// The phone names an id, never a path, and only one this Mac recorded is read.
    func sentPrompt(_ id: String) -> String? {
        guard Self.valid(id), recorded.values.contains(where: { $0.id == id }) || pending.values.contains(where: { $0.id == id }) else { return nil }
        // Pruning runs only at launch and on a save, so a Mac left running keeps files past their days.
        let changed = (try? sentFile(id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        guard Date().timeIntervalSince(changed) <= Self.keepDays * 86400 else { return nil }
        return try? String(contentsOf: sentFile(id), encoding: .utf8)
    }

    func link(_ record: Record) -> HandoffLink {
        HandoffLink(id: record.id, conversationID: record.fromConversation, agent: record.fromAgent == "codex" ? .codex : .claude,
                    model: record.fromModel, at: record.at, prompt: FileManager.default.fileExists(atPath: sentFile(record.id).path),
                    permissionMode: record.mode.map(PermissionMode.init(rawValue:)), resumed: record.resumed)
    }

    func link(conversation: String?, hosted: String?) -> HandoffLink? {
        if let conversation, let record = recorded[conversation] { return link(record) }
        if let hosted, let record = pending[hosted] { return link(record) }
        return nil
    }

    /// The conversation of `agent` this one was handed off from, for going back to it instead of starting a third.
    func earlier(_ conversation: String, agent: AgentProvider) -> String? {
        guard let record = recorded[conversation], record.fromAgent == agent.rawValue else { return nil }
        return record.fromConversation
    }

    func wait(_ record: Record, hosted name: String, on store: AccountStore) {
        var record = record
        record.hosted = name
        pending[name] = record
        persist(record)
        Task { _ = await store.hosted.command(["set-option", "-t", "=\(name):", "@sidea_handoff", record.id]) }
        follow(name, store: store)
    }

    /// Up to three minutes for the new agent to register its conversation, which is when the link can be kept for good.
    private func follow(_ name: String, store: AccountStore) {
        Task { [weak self, weak store] in
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let store else { return }
                if await self.settle(name, store: store) { return }
            }
        }
    }

    private func settle(_ name: String, store: AccountStore) async -> Bool {
        guard var record = pending[name] else { return true }
        guard let conversation = store.sessions.live.first(where: { $0.hosted == name })?.sessionID, IDs.safe(conversation) else {
            return !store.hosted.sessions.contains { $0.name == name }
        }
        record.toConversation = conversation
        if record.resumed == true {
            recorded[conversation] = record
            pending[name] = nil
            persist(record)
            return true
        }
        let row: [String: Any?] = ["id": record.id, "from_conversation": record.fromConversation, "to_conversation": conversation,
                                   "from_agent": record.fromAgent, "to_agent": record.toAgent, "from_model": record.fromModel,
                                   "to_model": record.toModel, "at": record.at, "prompt_path": fullFile(record.id).path, "mode": record.mode]
        guard let data = try? JSONSerialization.data(withJSONObject: row.mapValues { $0 ?? NSNull() }),
              (try? await store.sessions.remoteReply(["handoff-link", String(decoding: data, as: UTF8.self)])) != nil else { return false }
        recorded[conversation] = record
        pending[name] = nil
        persist(record)
        return true
    }

    private func persist(_ record: Record) {
        do { try PrivateFile.write(record, to: recordFile(record.id)) } catch {
            RemoteLog.shared("couldn't save a handoff's link: \(error.localizedDescription)")
        }
    }

    /// Rows built before it finishes lack their links, so they are rebuilt once it has.
    func load(_ store: AccountStore) { _ = loading(store) }

    func loaded(_ store: AccountStore) async { await loading(store)?.value }

    private func loading(_ store: AccountStore) -> Task<Void, Never>? {
        guard !loaded else { return nil }
        if let loadTask { return loadTask }
        let task = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer { self.loadTask = nil }
            self.prune()
            struct Listing: Decodable { let handoffs: [Record] }
            guard let data = try? await store.sessions.remoteReply(["handoffs"]),
                  let listing = try? SessionBridge.decode(data, as: Listing.self) else { return }
            var found = false
            for record in listing.handoffs + self.handedBack() {
                guard let to = record.toConversation, (self.recorded[to]?.at ?? 0) <= record.at else { continue }
                self.recorded[to] = record
                found = true
            }
            self.loaded = true
            if found { store.remote.events?.liveChanged() }
            await self.adoptWaiting(store)
        }
        loadTask = task
        return task
    }

    /// Hand-backs stay out of the index (each would be the other's parent), so their record files are what keeps them.
    private func handedBack() -> [Record] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.resumed == true, record.toConversation != nil else { return nil }
            return record
        }
    }

    private func adoptWaiting(_ store: AccountStore) async {
        for session in store.hosted.sessions where pending[session.name] == nil {
            let shown = await store.hosted.command(["show-options", "-v", "-t", "=\(session.name):", "@sidea_handoff"])
            let id = shown.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard shown.status == 0, Self.valid(id), !recorded.values.contains(where: { $0.id == id }),
                  let data = try? Data(contentsOf: recordFile(id)), let record = try? JSONDecoder().decode(Record.self, from: data) else { continue }
            pending[session.name] = record
            follow(session.name, store: store)
        }
    }
}
