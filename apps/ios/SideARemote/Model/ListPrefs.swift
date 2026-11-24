import Foundation
import SideAProtocol

struct NewSessionPrefs: Codable, Equatable {
    var agent: AgentProvider?
    var modelID: String?
    var effort: Effort?
    var accountID: String?
    var worktree = false

    init(agent: AgentProvider? = nil, modelID: String? = nil, effort: Effort? = nil, accountID: String? = nil, worktree: Bool = false) {
        self.agent = agent; self.modelID = modelID; self.effort = effort; self.accountID = accountID; self.worktree = worktree
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        agent = try? values.decode(AgentProvider.self, forKey: .agent)
        modelID = try? values.decode(String.self, forKey: .modelID)
        effort = try? values.decode(Effort.self, forKey: .effort)
        accountID = try? values.decode(String.self, forKey: .accountID)
        worktree = (try? values.decode(Bool.self, forKey: .worktree)) ?? false
    }
}

struct ListPrefs: Codable, Equatable {
    var groupBy = GroupBy.project
    var sortBy = SortBy.newest
    var idleExpanded = false

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        groupBy = (try? values.decode(GroupBy.self, forKey: .groupBy)) ?? .project
        sortBy = (try? values.decode(SortBy.self, forKey: .sortBy)) ?? .newest
        idleExpanded = (try? values.decode(Bool.self, forKey: .idleExpanded)) ?? false
    }
}

enum SortBy: String, CaseIterable, Identifiable, Codable {
    case newest, name, project
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: "Newest First"
        case .name: "Name"
        case .project: "Project"
        }
    }
}

enum ListPrefsStore {
    static let shownKey = "sessions.shownMac"
    static let legacyGroupBy = "sessions.groupBy", legacyIdle = "sessions.showIdle"

    static func key(mac: String) -> String { "sessions.list.\(mac)" }

    static func load(mac: String, in defaults: UserDefaults = .standard) -> ListPrefs {
        if let data = defaults.data(forKey: key(mac: mac)), let prefs = try? JSONDecoder().decode(ListPrefs.self, from: data) { return prefs }
        var prefs = ListPrefs()
        prefs.groupBy = defaults.string(forKey: legacyGroupBy).flatMap(GroupBy.init) ?? .project
        prefs.idleExpanded = defaults.bool(forKey: legacyIdle)
        return prefs
    }

    static func save(_ prefs: ListPrefs, mac: String, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        defaults.set(data, forKey: key(mac: mac))
    }

    static func shown(in defaults: UserDefaults = .standard) -> String? { defaults.string(forKey: shownKey) }

    static func setShown(_ macID: String?, in defaults: UserDefaults = .standard) { defaults.set(macID, forKey: shownKey) }

    static let openKey = "sessions.splitOpen"

    static func open(in defaults: UserDefaults = .standard) -> (mac: String, session: String)? {
        guard let pair = defaults.stringArray(forKey: openKey), pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }

    static func setOpen(_ open: (mac: String, session: String)?, in defaults: UserDefaults = .standard) {
        if let open { defaults.set([open.mac, open.session], forKey: openKey) } else { defaults.removeObject(forKey: openKey) }
    }

    static func newSessionKey(mac: String) -> String { "newSession.choices.\(mac)" }

    static func newSession(mac: String, in defaults: UserDefaults = .standard) -> NewSessionPrefs? {
        defaults.data(forKey: newSessionKey(mac: mac)).flatMap { try? JSONDecoder().decode(NewSessionPrefs.self, from: $0) }
    }

    static func setNewSession(_ prefs: NewSessionPrefs, mac: String, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        defaults.set(data, forKey: newSessionKey(mac: mac))
    }

    static func forget(mac: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(mac: mac))
        defaults.removeObject(forKey: newSessionKey(mac: mac))
        if shown(in: defaults) == mac { setShown(nil, in: defaults) }
        if open(in: defaults)?.mac == mac { setOpen(nil, in: defaults) }
    }
}
