import Foundation

/// What widgets, the Live Activity and intents read without the app running: `snapshot.json` in the
/// App Group, written by the app and the Notification Service Extension.
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    public struct Waiting: Codable, Hashable, Sendable {
        public var requestID: String
        public var sessionTitle: String
        public var project: String
        public var headline: String
        public var detail: String
        public var destructive: Bool
        public init(requestID: String, sessionTitle: String, project: String, headline: String, detail: String, destructive: Bool) {
            self.requestID = requestID; self.sessionTitle = sessionTitle; self.project = project
            self.headline = headline; self.detail = detail; self.destructive = destructive
        }
    }

    public struct Limit: Codable, Hashable, Sendable {
        public var account: String
        public var window: String
        public var percent: Double
        public var resetsAt: Date?
        public init(account: String, window: String, percent: Double, resetsAt: Date?) {
            self.account = account; self.window = window; self.percent = percent; self.resetsAt = resetsAt
        }
    }

    /// A row in the Sessions widget: needs-you rows first, then working.
    public struct Session: Codable, Hashable, Sendable, Identifiable {
        public enum Phase: String, Codable, Sendable { case needsYou, working }
        public var id: String
        public var title: String
        public var project: String
        public var phase: Phase
        /// The step ("Running swift build") or, for needs-you, what it asks ("Allow Bash · npm test").
        public var line: String?
        public var codex: Bool
        /// The Mac it's on, with several paired; nil means the snapshot's.
        public var mac: String?
        public init(id: String, title: String, project: String, phase: Phase, line: String?, codex: Bool, mac: String? = nil) {
            self.id = id; self.title = title; self.project = project; self.phase = phase; self.line = line; self.codex = codex; self.mac = mac
        }
    }

    /// An account's two windows, for the ring pairs.
    public struct Account: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var fiveHour: Double?
        public var weekly: Double?
        public var active: Bool
        public init(id: String, name: String, fiveHour: Double?, weekly: Double?, active: Bool) {
            self.id = id; self.name = name; self.fiveHour = fiveHour; self.weekly = weekly; self.active = active
        }
    }

    /// The Mac's name, or "2 Macs" with several.
    public var macName: String
    /// For deep links: `sidea-remote://session/<macID>/<id>`; the first Mac's with several.
    public var macID: String
    public var working: Int
    public var waiting: Int
    public var top: Waiting?
    public var tightest: Limit?
    /// Up to 7.
    public var sessions: [Session]
    /// Up to 4, the one in use first.
    public var accounts: [Account]
    public var updatedAt: Date

    public init(macName: String, macID: String, working: Int, waiting: Int, top: Waiting? = nil, tightest: Limit? = nil,
                sessions: [Session] = [], accounts: [Account] = [], updatedAt: Date) {
        self.macName = macName; self.macID = macID; self.working = working; self.waiting = waiting; self.top = top
        self.tightest = tightest; self.sessions = sessions; self.accounts = accounts; self.updatedAt = updatedAt
    }

    public static var appGroup: String { SharedStorage.appGroup }

    public static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("snapshot.json")
    }

    public static func load() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public func save() throws {
        guard let url = Self.url else { return }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Unpaired: the widgets say so instead of showing a Mac that's gone.
    public static func remove() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public func sessionURL(_ id: String) -> URL? {
        URL(string: "sidea-remote://session/\(sessions.first { $0.id == id }?.mac ?? macID)/\(id)")
    }

    /// For widget galleries and previews.
    public static let placeholder = WidgetSnapshot(
        macName: "MacBook Pro", macID: "demo", working: 3, waiting: 1,
        top: Waiting(requestID: "demo", sessionTitle: "Fix the flaky sync test", project: "side-a",
                     headline: "Allow Bash", detail: "swift test --filter SyncEngineTests", destructive: false),
        tightest: Limit(account: "Work", window: "5h", percent: 82, resetsAt: Date(timeIntervalSinceNow: 2 * 3600 + 840)),
        sessions: [
            Session(id: "a", title: "Fix the flaky sync test", project: "side-a", phase: .needsYou, line: "Allow Bash · swift test", codex: false),
            Session(id: "b", title: "Add LAN mode", project: "side-a", phase: .working, line: "Running swift build", codex: true),
            Session(id: "c", title: "Ship 0.5.37", project: "side-a", phase: .working, line: "Editing Island.swift", codex: false),
            Session(id: "d", title: "Move storefront to Postgres 17", project: "storefront", phase: .working, line: "Reading schema.sql", codex: false),
        ],
        accounts: [
            Account(id: "w", name: "Work", fiveHour: 82, weekly: 41, active: true),
            Account(id: "p", name: "Personal", fiveHour: 23, weekly: 64, active: false),
            Account(id: "t", name: "Team", fiveHour: 7, weekly: 18, active: false),
            Account(id: "o", name: "OpenAI", fiveHour: 54, weekly: 97, active: false),
        ],
        updatedAt: .now)
}
