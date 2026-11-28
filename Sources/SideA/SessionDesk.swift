import Foundation
import Observation
import SideACore
import SideAProtocol

/// What the Sessions window remembers between uses: the sidebar's width, and the New Session sheet's last choices.
struct SessionPrefs {
    static let sidebarWidthKey = "sessionsSidebarWidth"
    static let sidebarHiddenKey = "sessionsSidebarHidden"
    static let startKey = "sessionsLastStart"
    static let sidebarRange: ClosedRange<Double> = 240...520
    static let sidebarDefault: Double = 320

    /// The New Session sheet's choices. Model, effort and mode belong to an agent; the agent and the worktree choice
    /// belong to a folder, since a repository is usually worked with one agent.
    struct Start: Codable, Equatable {
        struct PerAgent: Codable, Equatable {
            var model = ""
            var effort = ""
            var account = ""
            var mode = ""

            init(model: String = "", effort: String = "", account: String = "", mode: String = "") {
                self.model = model; self.effort = effort; self.account = account; self.mode = mode
            }

            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
                effort = try values.decodeIfPresent(String.self, forKey: .effort) ?? ""
                account = try values.decodeIfPresent(String.self, forKey: .account) ?? ""
                mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? ""
            }
        }
        struct PerFolder: Codable, Equatable {
            var agent: String
            var worktree = false
            var used: Double = 0
        }
        var folder = ""
        var agent = ""
        /// Whether a started session also opens in a terminal tab.
        var terminal = true
        var agents: [String: PerAgent] = [:]
        var folders: [String: PerFolder] = [:]

        init() {}

        /// A record written by an earlier build lacks what was added since; it keeps what it has.
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            folder = try values.decodeIfPresent(String.self, forKey: .folder) ?? ""
            agent = try values.decodeIfPresent(String.self, forKey: .agent) ?? ""
            terminal = try values.decodeIfPresent(Bool.self, forKey: .terminal) ?? true
            agents = try values.decodeIfPresent([String: PerAgent].self, forKey: .agents) ?? [:]
            folders = try values.decodeIfPresent([String: PerFolder].self, forKey: .folders) ?? [:]
        }

        /// Where a new session starts: the open conversation's folder, else the last one used, else the most recent.
        static func folder(_ saved: Start, open: String?, among folders: [String]) -> String {
            if let open, folders.contains(open) { return open }
            return folders.contains(saved.folder) ? saved.folder : folders.first ?? ""
        }

        /// Folders are remembered while they are the last few used, so the record doesn't grow with every repository.
        static let foldersKept = 40

        mutating func record(_ start: StartHosted, at now: Double = Date().timeIntervalSince1970) {
            folder = start.cwd
            agent = start.agent.rawValue
            agents[start.agent.rawValue] = PerAgent(model: start.model ?? "", effort: start.effort ?? "", account: start.accountID ?? "",
                                                    mode: start.permissionMode?.rawValue ?? "")
            folders[start.cwd] = PerFolder(agent: start.agent.rawValue, worktree: start.worktree, used: now)
            if folders.count > Self.foldersKept, let oldest = folders.min(by: { $0.value.used < $1.value.used }) { folders[oldest.key] = nil }
        }
    }

    let defaults: UserDefaults

    // swiftlint:disable:next user_defaults_standard -- this is the type that owns these settings; tests pass their own.
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var sidebarWidth: Double {
        get {
            let saved = defaults.double(forKey: Self.sidebarWidthKey)
            return saved == 0 ? Self.sidebarDefault : min(max(saved, Self.sidebarRange.lowerBound), Self.sidebarRange.upperBound)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.sidebarWidthKey) }
    }

    var sidebarHidden: Bool {
        get { defaults.bool(forKey: Self.sidebarHiddenKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.sidebarHiddenKey) }
    }

    var start: Start {
        get { defaults.data(forKey: Self.startKey).flatMap { try? JSONDecoder().decode(Start.self, from: $0) } ?? Start() }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.startKey)
        }
    }
}

/// The Sessions window's own state, apart from the conversations it lists: where focus should go, where the user
/// has been, and how the window is laid out. Kept out of `SessionStore`, which is as long as it may get.
@MainActor @Observable
final class SessionDesk {
    @ObservationIgnored let prefs: SessionPrefs

    /// Raised to hand the keyboard to the composer or the list. A view acts on a change, never on the value.
    var composerFocus = 0
    var listFocus = 0

    /// The Sessions window itself has the keyboard, so the Session menu applies to it.
    var windowKey = false
    /// It, or a sheet or popover it presented, has the keyboard: the player's keys stand down.
    var windowActive = false
    /// ⌘ has been held long enough that the rows show their numbers.
    var numbered = false
    /// The conversation the arrow keys last moved to. Stepping through the list must not move the keyboard out of it.
    @ObservationIgnored var steppedTo: String?
    /// The last focus request the composer acted on.
    @ObservationIgnored var composerTaken = 0

    var sidebarWidth: Double { didSet { prefs.sidebarWidth = sidebarWidth } }
    var sidebarHidden: Bool { didSet { prefs.sidebarHidden = sidebarHidden } }

    /// Sessions being started from this Mac, newest first.
    var launches: [Launch] = []
    /// The launch the window shows, in place of a conversation.
    var selectedLaunch: UUID?
    /// What was typed to a session while it started; it becomes that session's draft.
    var held: [UUID: String] = [:]
    /// A request the New Session sheet opens with: a failed start being edited.
    @ObservationIgnored var seed: StartHosted?
    /// A folder dropped on the window, which the New Session sheet opens in.
    @ObservationIgnored var startFolder: String?
    /// The New Session sheet's prompt, kept when the sheet is closed without starting.
    var prompt = ""

    /// Raised when a session's waiting replies change: the island's queue isn't observed.
    var queueTick = 0
    /// The waiting reply a draft is a rewording of, by conversation.
    var rewording: [String: String] = [:]
    /// Messages sent from this window that the conversation hasn't shown yet, by conversation.
    var outgoing: [String: [Outgoing]] = [:]

    /// Messages set aside with ⌘S, newest first, once read from their file.
    var stash: [Stashed] = []
    @ObservationIgnored var stashRead = false

    /// Each folder's project actions and the folder they run in, read when a conversation there is opened.
    var projectActions: [String: (actions: [ProjectAction], folder: String)] = [:]

    /// Shows a project action's command before its first run. Tests put their own here.
    @ObservationIgnored var approveRun: @MainActor (ProjectAction, String) -> Bool = ProjectActions.ask

    /// ⌘K is up.
    var switching = false
    /// Rows picked with ⌘ or ⇧ click, to act on together. Empty while only the open conversation is chosen.
    var picked: Set<String> = []
    var undo: ListUndo?
    /// Idle sessions whose quit is waiting out its undo, by process.
    @ObservationIgnored var quits: [Int: Task<Void, Never>] = [:]
    /// Quits a session once its undo has run out. Tests put their own here.
    @ObservationIgnored var quitNow: @MainActor (LiveSession, SessionStore) -> Void = { session, store in store.quit(session) }
    /// Raised when a snooze is set, ends or is woken: the snoozes themselves aren't observed.
    var snoozeTick = 0
    @ObservationIgnored var snoozeHeard = false
    /// Raised when a limit-stopped session is held or let go on: that choice isn't observed.
    var limitTick = 0
    var snoozedOpen = false
    var earlierOpen = false

    /// Where unsent messages are kept across a quit, once the window has opened.
    @ObservationIgnored var saved: SessionDrafts?

    /// Conversations as the phone reads them, for the detailed view, by conversation id.
    var wire: [String: WireWindow] = [:]
    var wireLoading: Set<String> = []
    @ObservationIgnored var wireOrder: [String] = []
    /// How many reads of each conversation have been asked for, so an earlier one finishing late is dropped.
    @ObservationIgnored var wireAsked: [String: Int] = [:]

    /// Conversations opened in this window, oldest first, for Back and Forward.
    private(set) var trail = Trail()

    init(prefs: SessionPrefs = SessionPrefs()) {
        self.prefs = prefs
        sidebarWidth = prefs.sidebarWidth
        sidebarHidden = prefs.sidebarHidden
    }

    func visited(_ id: String?) { if let id { trail.visit(id) } }
    func back() -> String? { trail.back() }
    func forward() -> String? { trail.forward() }
    /// The conversation open before this one, for ⌃⇥: pressing it twice comes back.
    var previous: String? { trail.previous }
    var canGoBack: Bool { trail.canGoBack }
    var canGoForward: Bool { trail.canGoForward }
    func forget(_ id: String) { trail.forget(id) }
}

/// Browser-style history over conversation ids.
struct Trail: Equatable {
    static let kept = 50
    private(set) var ids: [String] = []
    private(set) var index = -1
    /// The last conversation left, by any route: Back and Forward change it too, so ⌃⇥ always toggles two.
    private(set) var previous: String?

    var current: String? { ids.indices.contains(index) ? ids[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < ids.count - 1 }

    /// A conversation opened by any means other than Back and Forward: it becomes the newest, and what was ahead goes.
    mutating func visit(_ id: String) {
        guard id != current else { return }
        previous = current
        ids = Array(ids.prefix(index + 1))
        ids.append(id)
        if ids.count > Self.kept { ids.removeFirst(ids.count - Self.kept) }
        index = ids.count - 1
    }

    mutating func back() -> String? { move(-1) }
    mutating func forward() -> String? { move(1) }

    private mutating func move(_ delta: Int) -> String? {
        guard ids.indices.contains(index + delta) else { return nil }
        previous = current
        index += delta
        return current
    }

    /// A conversation that no longer exists leaves the history, so Back never lands on nothing.
    mutating func forget(_ id: String) {
        guard ids.contains(id) else { return }
        let here = current
        ids.removeAll { $0 == id }
        if previous == id { previous = nil }
        index = here.flatMap { ids.lastIndex(of: $0) } ?? ids.count - 1
    }
}
