import AppKit
import Foundation
import Observation
import os
import SideACore
import ServiceManagement
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

struct AuthStatus: Decodable, Sendable {
    let loggedIn: Bool
    let email: String
    let authMethod: String
}

private let integrationLog = Logger(subsystem: "com.arnenoori.sidea", category: "integrations")

@MainActor @Observable
final class AccountStore {
    var config = Configuration() {
        didSet {
            if config.accounts != oldValue.accounts || config.swapAt != oldValue.swapAt || config.followFable != oldValue.followFable { remoteUsageChanged() }
            if config.accounts != oldValue.accounts || config.moveAt != oldValue.moveAt { writePoolPlan() }
            // Pool mode is the default from the first signed-in account on; an empty pool would refuse every command,
            // and installs that loaded with accounts keep what they had.
            if config.pool == nil, !isDemo, !oldValue.accounts.isEmpty, !oldValue.accounts.contains(where: \.ready),
               config.accounts.contains(where: \.ready) {
                Task { await setPool(true) }
            }
            if config.smartMode != oldValue.smartMode || config.swapAt != oldValue.swapAt || config.followFable != oldValue.followFable { remote.events?.autopilotChanged() }
        }
    }
    var dependencies = DependencyReport()
    var checkingDependencies = false
    let analytics: AppAnalytics
    var error: String?
    /// Accounts that own the Mac-wide Claude and Codex logins, when they are in the library.
    var activeIDs: [AgentProvider: String] = [:] { didSet { remoteUsageChanged() } }
    /// Mac-wide login emails that are not in the library yet.
    var unknownLogins: [AgentProvider: String] = [:]
    /// Mac logins being added to the library, by provider.
    var adopting: Set<AgentProvider> = []
    /// When adding a Mac login on its own last failed, by "provider:email"; it waits ten minutes to try again.
    @ObservationIgnored private var adoptFailedAt: [String: Date] = [:]
    /// When an unready account holding the Mac's login was last checked, so it's checked at most every ten minutes.
    @ObservationIgnored private var recheckedAt: [String: Date] = [:]
    /// Accounts added without a name, which take their email's once sign-in confirms it.
    @ObservationIgnored private var unnamed: [String: String] = [:]
    /// Tests answer bridge calls here instead of running Python.
    @ObservationIgnored var testBridge: (@MainActor ([String]) async throws -> Data)?
    var report: UsageReport?
    /// An incident on status.claude.com reaching Claude Code or the API, while it lasts.
    var outage: Outage? {
        didSet { if outage != oldValue { remote.events?.incidentsChanged() } }
    }
    /// Moves Autopilot is holding until a slot's sessions pause, by slot; Move Now runs one at once.
    var heldMoves: [String: HeldMove] = [:] { didSet { if heldMoves != oldValue { remote.events?.autopilotChanged() } } }
    struct HeldMove: Equatable, Sendable {
        let slot: String, from: String, to: String, share: Bool, reason: String, since: Date
    }
    @ObservationIgnored private var statusCheckedAt = Date.distantPast
    /// Shown in the menu while sessions hold a lot of memory and macOS reports memory pressure.
    var memoryWarning: String?
    @ObservationIgnored private var memoryCheckedAt = Date.distantPast
    @ObservationIgnored private var memoryNotifiedAt: Date?
    @ObservationIgnored private var pricesCheckedAt = Date.distantPast
    /// When the API price list was last fetched, for the Usage footer; nil while Side A's own table is used.
    var pricesUpdated: Date?
    @ObservationIgnored private var outageNotified = UserDefaults.standard.string(forKey: "outageNotified")
    /// Model of the newest Claude Code response in the last half hour.
    var claudeModel: String?
    var limitHook = false
    /// The `claude` shell function that makes new commands use the chosen account.
    var shellSwitching = false
    /// The ~/.zshrc wrappers that start interactive claude and codex in Side A's tmux server.
    var hostTerminal = false
    var liveLimits = false
    /// When a Claude Code session last reported each account's limits.
    private var liveAt: [String: Double] = [:]
    private var liveSeen = Date.distantPast
    /// Keychain slots running claude processes read, with the account whose login is in each;
    /// nil when processes can't be listed.
    var busyLogins: [String: String]?
    /// Per running slot, the model each of its sessions last answered with.
    @ObservationIgnored var slotModels: [String: [String?]] = [:]
    /// Per running slot, seconds since its sessions last wrote, so trades it can wait on land in a pause.
    @ObservationIgnored private var slotQuiet: [String: Double] = [:]
    /// Per account, the newest limit a running session reported hitting, when, and every session whose last reply says so.
    @ObservationIgnored var limitHits: [String: (limit: String, at: Double, sessions: [String])] = [:]
    @ObservationIgnored private var reportAt = Date.distantPast
    @ObservationIgnored private var sessionsIndexedAt = Date.distantPast
    @ObservationIgnored private var limitMarkerDate: Date?
    var usage: [String: AccountUsage] = [:] { didSet { remoteUsageChanged(); writePoolPlan() } }
    var signingIn: Set<String> = []
    /// Bridge commands under way that change logins or files; an update waits for them rather than cut one off.
    @ObservationIgnored var bridgeChanges = 0
    /// Why an account's numbers are not current, or its login can't be used. Only accounts with something wrong have an entry.
    var health: [String: LoginHealth] = [:] { didSet { remoteUsageChanged(); writePoolPlan() } }
    var waking: Set<String> = []
    @ObservationIgnored private var primedAt: [String: Date] = [:]
    @ObservationIgnored private var usageAt: [String: Date] = [:]
    @ObservationIgnored private var backoffUntil: [String: Date] = [:]
    /// Accounts whose latest read failed for a reason other than being idle. They keep their
    /// last bars on screen but are left out of Autopilot until a read succeeds.
    @ObservationIgnored private var failing: Set<String> = []
    @ObservationIgnored lazy var rotationRecords = RotationRecords(url: isDemo ? nil : root.appendingPathComponent("runtime/rotation.json"))
    @ObservationIgnored lazy var autopilotLog = AutopilotLog(url: root.appendingPathComponent("runtime/autopilot.log"))
    /// Failed moves already notified, by slot and target, so a retry every tick doesn't notify again.
    @ObservationIgnored private var swapFailures: Set<String> = []
    @ObservationIgnored private var reading: Set<String> = []
    /// Bumped by every switch, so an "active" answer that started earlier cannot overwrite it.
    @ObservationIgnored private var selectionGeneration = 0
    /// Recent (time, 5-hour percent) samples per account for the burn-rate forecast.
    @ObservationIgnored private var samples: [String: [(Double, Double)]] = [:]
    @ObservationIgnored private var exhaustedNotified = false
    /// Per account: the window reset already warned about, so each limit warns once.
    @ObservationIgnored private var paidWarned: [String: Double] = [:]
    @ObservationIgnored private var loginStamps: [String: Double] = [:]
    @ObservationIgnored private var endWarned: [String: Double] = [:]
    @ObservationIgnored private var renewedAt: [String: Date] = [:]
    /// When each Claude sign-in stops renewing; about a month after signing in.
    var loginEnds: [String: Double] = [:]
    /// When each account was last read successfully, for marking old readings.
    var readAt: [String: Date] = [:] { didSet { remoteUsageChanged() } }
    var lidOpen = false
    /// The player only stays open when asked for; macOS would otherwise restore it at launch.
    var playerRequested = false
    /// Settings reopens on the tab last used.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settingsTab") ?? "") ?? .accounts {
        didSet { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settingsTab") }
    }
    var addingAccount = false
    var held = false
    /// Each account's login check under way.
    @ObservationIgnored private var verifying: [String: Task<Result<Bool, Error>, Never>] = [:]
    /// Tests: a demo store's sign-in, login checks and pool take the real paths, on its temporary root.
    @ObservationIgnored var checksLogins = false
    var startupError = false
    let root: URL
    let isDemo: Bool
    private var pollTask: Task<Void, Never>?
    /// Lives as long as the app, so reopening Sessions shows the list and recent conversations at once.
    @ObservationIgnored private(set) lazy var sessions = SessionStore(store: self)
    @ObservationIgnored private(set) lazy var waitingNotifier = WaitingNotifier(store: self)
    @ObservationIgnored private(set) lazy var island = Island(store: self)
    /// The harness puts its own in place, so the store's changes reach the controller it serves.
    @ObservationIgnored lazy var remote = RemoteController(store: self, keychain: isDemo ? .inMemory() : .forApp())
    /// Tests put one on a private tmux socket in its place.
    @ObservationIgnored lazy var hosted = HostedSessions(root: root, bridge: { [unowned self] in try await self.bridgeOutput($0) },
                                                                      live: { [unowned self] in await self.sessions.freshLive() },
                                                                      changed: { [unowned self] in await self.sessions.refreshLive() })
    enum PoolRun {
        case off, starting
        case running(PoolProxy, port: UInt16)
        case failed(String)
    }
    var poolRun: PoolRun = .off
    var pool: PoolProxy? { if case .running(let proxy, _) = poolRun { proxy } else { nil } }
    var poolPort: UInt16? { if case .running(_, let port) = poolRun { port } else { nil } }
    var poolConversations: [String: Int] = [:]
    @ObservationIgnored var poolRouter = PoolRouter()
    @ObservationIgnored let poolTokens = PoolTokenCache()
    var poolShareState: PoolShareState = .off
    var poolShareCommand: String? { if case .shared(let command) = poolShareState { command } else { nil } }
    var poolShareProblem: String? { if case .problem(let problem) = poolShareState { problem } else { nil } }
    /// Counts what the share setting was last asked to do; work begun under an older count stands down.
    @ObservationIgnored var poolShareGeneration = 0
    @ObservationIgnored var poolShareRunning = false
    /// Tests take any free port, whatever else on this Mac holds the real one.
    @ObservationIgnored var poolPreferredPort = PoolProxy.preferredPort
    /// Tests stand in for tailscaled.
    @ObservationIgnored var tailscaleStatus: @Sendable () async -> TailscaleStatus = { await TailscaleCLI.shared.status() }
    @ObservationIgnored var poolQuitObserver: (any NSObjectProtocol)?
    @ObservationIgnored var lastPoolPlan: PoolPlan?
    /// What the pool last did for each service, for Settings and a joined Mac's health check.
    var poolHealth: [AgentProvider: PoolActivity] = [:]
    /// Results of Test Pool: each member's login, checked without spending quota.
    var poolTest: [String: String]?
    var poolTesting = false
    /// Another Mac's pool this one joined with `sidea pool join`, and whether it answered last time.
    var remotePool: (url: String, answered: Bool?, codexAccounts: Int, detail: String)?
    @ObservationIgnored var stuckNotified: Set<String> = []
    @ObservationIgnored var slotMovedAt: [String: Double] = [:]
    @ObservationIgnored var codexPoolHomes: [Bool: String] = [:]
    @ObservationIgnored var poolBlocked: [String: Double] = [:]
    @ObservationIgnored var signInWarned: Set<String> = []
    /// Accounts already named in "is full; sign in to X", once per lapse.
    @ObservationIgnored var signInAsked: Set<String> = []
    /// Why the last read of the logins in use failed; nil when it worked or was only overtaken by a new selection.
    @ObservationIgnored var activeProblem: String?
    /// Why running sessions couldn't be listed, from the bridge.
    @ObservationIgnored var busyProblem: String?
    @ObservationIgnored private(set) lazy var keepAwake = KeepAwakeController(system: isDemo ? nil : MacSleepSystem(root: root.path))
    @ObservationIgnored private(set) var preferences: PreferencesMirror?
    @ObservationIgnored private var notificationRouter: NotificationRouter?
    /// UNUserNotificationCenter traps outside an app bundle, as in `swift run`.
    func startNotifications() {
        guard Bundle.main.bundleURL.pathExtension == "app", !isDemo else { return }
        if notificationRouter == nil { notificationRouter = NotificationRouter(store: self) }
        if WaitingNotifier.enabled { WaitingNotifier.requestPermission() }
        waitingNotifier.update()
    }

    /// Tests pass `demo: true`: a demo store reads and writes only its temp folder.
    /// `root`: tests give a demo store a folder of its own.
    init(demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo"), root folder: URL? = nil) {
        isDemo = demo
        analytics = AppAnalytics(allowed: !isDemo)
        root = folder ?? (isDemo
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SideA-preview-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SideA"))
        if isDemo {
            config.accounts = [Account(name: "Personal", email: "you@example.com", ready: true, allowAuto: true),
                               Account(name: "Studio", email: "studio@example.com", ready: true, allowAuto: true),
                               Account(name: "Weekend", email: "weekend@example.com", ready: true, allowAuto: true),
                               Account(name: "Work", email: "work@example.com", ready: true, allowAuto: true, provider: .codex),
                               Account(name: "Side project", email: "side@example.com", ready: true, allowAuto: true, provider: .codex)]
            config.selectedID = config.accounts.first?.id
            config.smartMode = true
            shellSwitching = true
            activeIDs = [.claude: config.accounts[0].id, .codex: config.accounts[3].id]
            let now = Date().timeIntervalSince1970
            func window(_ id: String, _ percent: Double, _ reset: Double) -> UsageWindow {
                UsageWindow(id: id, label: UsageWindow.label(of: id), percent: percent, resetsAt: now + reset)
            }
            let ids = config.accounts.map(\.id)
            usage = [ids[0]: AccountUsage(windows: [window("five_hour", 62, 7_400), window("seven_day", 41, 260_000)], capacity: 20),
                     ids[1]: AccountUsage(windows: [window("five_hour", 8, 15_800), window("seven_day", 18, 520_000)], capacity: 5),
                     ids[2]: AccountUsage(windows: [window("five_hour", 100, 2_900), window("seven_day", 100, 90_000)], capacity: 1),
                     ids[3]: AccountUsage(windows: [window("five_hour", 34, 9_600), window("seven_day", 57, 330_000)]),
                     ids[4]: AccountUsage(windows: [window("seven_day", 12, 480_000)])]
            let calendar = Calendar.current
            let days: [TokenRow] = (0..<30).map { offset in
                let date = calendar.date(byAdding: .day, value: offset - 29, to: Date())!
                let weekday = calendar.component(.weekday, from: date)
                let base = weekday == 1 || weekday == 7 ? 0.35 : 1.0
                let total = Int((900 + Double((offset * 37) % 11) * 140) * base) * 1_000_000
                return TokenRow(date: ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate]),
                                input: total / 200, output: total / 60, cacheWrite: total / 12, cacheRead: total - total / 200 - total / 60 - total / 12)
            }
            func row(_ name: String, project: Bool, _ total: Int) -> TokenRow {
                TokenRow(project: project ? name : nil, model: project ? nil : name, input: total / 200, output: total / 60, cacheWrite: total / 12, cacheRead: total - total / 200 - total / 60 - total / 12)
            }
            report = UsageReport(days: days,
                                 projects: [row("/Users/you/code/web-app", project: true, 9_400_000_000), row("/Users/you/code/api", project: true, 6_100_000_000),
                                            row("/Users/you/code/mobile", project: true, 3_800_000_000), row("/Users/you/code/docs", project: true, 900_000_000)],
                                 models: [row("claude-opus-5-5", project: false, 14_200_000_000), row("claude-sonnet-5-5", project: false, 5_300_000_000),
                                          row("claude-haiku-4-5", project: false, 700_000_000)],
                                 activity: (0..<14).map { ActivitySpan(date: "d\($0)", hours: (0..<24).map { (9...18).contains($0) ? 40 : 1 }) },
                                 dayModels: days.flatMap { day in
                                     [("claude-opus-5-5", 0.7), ("claude-sonnet-5-5", 0.26), ("claude-haiku-4-5", 0.04)].map { model, share in
                                         var split = day; split.model = model
                                         split.input = Int(Double(day.input) * share); split.output = Int(Double(day.output) * share)
                                         split.cacheWrite = Int(Double(day.cacheWrite) * share); split.cacheRead = Int(Double(day.cacheRead) * share)
                                         return split
                                     }
                                 })
        } else if FileManager.default.fileExists(atPath: configURL.path) {
            do { config = try PrivateFile.read(Configuration.self, from: configURL).validated() }
            catch { self.error = error.localizedDescription; startupError = true }
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            // First launch: Autopilot only helps while running, so start with the Mac.
            try? SMAppService.mainApp.register()
        }
        if !isDemo {
            let mirror = PreferencesMirror(root: root, syncFolder: { [weak self] in self?.preferencesSyncFolder },
                                           effects: { [weak self] in await self?.applyPreferences($0) })
            mirror.load()
            mirror.start()
            preferences = mirror
        }
        if !isDemo, let cache = try? PrivateFile.read(UsageCache.self, from: usageCacheURL) {
            // Show the last numbers at once and keep each account on its normal polling schedule.
            usage = cache.usage; usageAt = cache.at
            backoffUntil = cache.backoff ?? [:]; primedAt = cache.primed ?? [:]; failing = Set(cache.failing ?? []).intersection(config.accounts.map(\.id))
            health = (cache.issues ?? [:]).reduce(into: [:]) { kept, entry in
                if config.accounts.contains(where: { $0.id == entry.key }) { kept[entry.key] = LoginHealth(saved: entry.value) }
            }
            // Caches from before readAt existed only know when a read was last attempted.
            readAt = cache.readAt ?? cache.at
            activeIDs = (cache.active ?? [:]).reduce(into: [:]) { ids, item in AgentProvider(rawValue: item.key).map { ids[$0] = item.value } }
        }
        if !isDemo {
            report = try? PrivateFile.read(UsageReport.self, from: reportURL)
            // Files from the 0.4 session runner; nothing reads them any more.
            let runtime = root.appendingPathComponent("runtime")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: runtime.path)) ?? []
            where ["active.json", "session.lock", "keychain.lock", "claude-account"].contains(name) || name.hasSuffix(".hooks.json") {
                try? FileManager.default.removeItem(at: runtime.appendingPathComponent(name))
            }
        }
        // The lid stays open while Settings is on screen, as the old account panel did.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard window?.identifier?.rawValue.contains("Settings") == true else { return }
                self?.lidOpen = false
            }
        }
        analytics.capture(.launched)
        pollTask = Task { [weak self] in
            // Every bridge call needs Python, so nothing runs until the tool scan has found it.
            await self?.refreshDependencies()
            await self?.loadIntegrations()
            while !Task.isCancelled {
                await self?.tick()
                for _ in 0..<30 {
                    if self?.limitHit() == true || self?.liveChanged() == true { break }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func loadIntegrations() async {
        // "live on" rewrites ~/.claude/settings.json to point at this root; a demo's root is a temporary folder.
        guard !isDemo else { return }
        async let hook = loadIntegration("hook", "status")
        async let shell = loadIntegration("shell", "status")
        async let live = loadIntegration("live", config.liveLimits == false ? "status" : "on")
        if let installed = await hook { limitHook = installed }
        if let installed = await shell { shellSwitching = installed }
        if let installed = await live { liveLimits = installed }
        if let installed = await loadIntegration("host-terminal", "status") { hostTerminal = installed }
        await syncHosting()
        await setIsland(nil, "sync")
        await syncPool()
    }
    /// nil when the bridge couldn't say, which is logged; the switch keeps what it showed.
    private func loadIntegration(_ command: String, _ state: String) async -> Bool? {
        do { return try await integration(command, state) } catch {
            integrationLog.error("\(command, privacy: .public) \(state, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    func accountID(inSlot slot: String) -> String? { busyLogins?[slot] }
    /// Only Remote's recorder listens; without a paired phone this costs a static check.
    private func remoteUsageChanged() { remote.events?.usageChanged() }
    /// Codex logins are never traded, so a profile's home is its account; its own home is the Mac's.
    func accountID(codexHome home: ProcessEnvironment.CodexHome) -> String? {
        switch home {
        case .mac: activeIDs[.codex]
        case .profile(let id): config.accounts.first { $0.id == id && $0.provider == .codex }?.id
        case .other: nil
        }
    }
    /// The permission hook for one CLI, or with `agent` nil, "sync" or "off" for both.
    func setIsland(_ agent: IslandAgent?, _ state: String) async {
        // The demo's hooks would point Claude Code and Codex at its temporary folder.
        guard !isDemo else {
            if state != "sync" { self.error = "The demo doesn't install hooks." }
            return
        }
        do {
            let data = try await bridgeOutput(["island", state] + (agent.map { ["--agent", $0.rawValue] } ?? []))
            let states = try JSONDecoder().decode([String: Bool].self, from: data)
            island.installed = Dictionary(uniqueKeysWithValues: states.compactMap { key, value in IslandAgent(rawValue: key).map { ($0, value) } })
        } catch { if state != "sync" { self.error = error.localizedDescription } }
        await readCodexMailTrust()
    }

    /// A shared setting arrived from another copy or Mac: what its toggle does beyond storing the value.
    /// The rest, sounds included, are read each time they're used, so storing them is enough.
    private func applyPreferences(_ keys: Set<String>) async {
        if keys.contains(Island.onKey), let change = PreferencesMirror.islandChange(on: Island.on, claudeInstalled: island.installed[.claude] == true,
                                                                                     remoteActive: RemoteController.active) {
            await setIsland(change.agent, change.state)
        }
        if keys.contains(KeepAwakeController.enabledKey) {
            let enabled = UserDefaults.standard.bool(forKey: KeepAwakeController.enabledKey)
            if keepAwake.settings.enabled != enabled { keepAwake.setEnabled(enabled) }
        }
        if keys.contains(WaitingNotifier.enabledKey), WaitingNotifier.enabled, Bundle.main.bundleURL.pathExtension == "app" { WaitingNotifier.requestPermission() }
        if !keys.isDisjoint(with: [Island.onKey, Island.waitingKey, WaitingNotifier.enabledKey]) { startNotifications() }
    }

    /// Codex asks the user to trust each new hook; until the mail hooks are, its notes wait. Read after every change
    /// to the island and every two minutes while Codex still asks.
    @ObservationIgnored private var codexMailCheck: Task<Void, Never>?
    func readCodexMailTrust() async {
        guard island.installed[.codex] == true else { island.codexMail = nil; return }
        let trust = (try? await bridgeOutput(["island", "trust"])).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["codexMail"]
        island.codexMail = trust
        codexMailCheck?.cancel()
        guard trust == "review" else { return }
        codexMailCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            await self?.readCodexMailTrust()
        }
    }
    /// Reads accounts three at a time: each Codex read starts its own app-server, so serial reads add
    /// up, but reading every account at once (say after a restart) draws 429s from the usage endpoint.
    private func refresh(_ ids: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                if index >= 3 { await group.next() }
                group.addTask { await self.refreshUsage(id) }
            }
        }
    }
    var configURL: URL { root.appendingPathComponent("config.json") }
    var selected: Account? { config.selected }
    /// The Mac-wide Claude account (shown in the menu bar title).
    var active: Account? { config.accounts.first { $0.id == activeIDs[.claude] } }
    func isActive(_ account: Account) -> Bool { activeIDs[account.provider] == account.id }
    var schedule: WorkSchedule? { report.flatMap { WorkSchedule($0.activity) } }
    var trackNumber: Int { (config.accounts.firstIndex { $0.id == config.selectedID } ?? 0) + 1 }
    var python: String? { dependencies.python.path }
    func isInstalled(_ provider: AgentProvider) -> Bool { dependencies.agent(provider).state == .ready }
    func refreshDependencies() async {
        guard !checkingDependencies else { return }
        checkingDependencies = true
        let hadPython = python != nil
        dependencies = DependencyCheck.keepingWorking(dependencies, await DependencyCheck.scan())
        checkingDependencies = false
        // Readings that failed only because Python was gone retry now, not after their five-minute back-off.
        if !hadPython, python != nil {
            for (id, state) in health where state == .offline { backoffUntil[id] = nil }
        }
    }
    var bridgeURL: URL? { AppResources.bridge("sidea_bridge.py") }

    @discardableResult func persist() -> Bool {
        guard !startupError else { return false }
        guard !isDemo else { return true }
        do { try PrivateFile.write(try config.validated(), to: configURL); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func step(_ offset: Int) {
        guard !held else { return }
        config.step(offset); persist()
        Sounds.play(.tick)
    }
    func toggleSmart() { setAutopilot(!config.smartMode) }
    /// Autopilot on or off, from the Mac's toggles or the phone.
    func setAutopilot(_ enabled: Bool) {
        guard config.smartMode != enabled else { return }
        config.smartMode = enabled; persist()
        // Autopilot moves Terminal's account, which needs the shell line; turning it on is the consent.
        if config.smartMode && !shellSwitching && !isDemo { Task { await setShellSwitching(true) } }
    }
    /// Answering with the recommended choice on or off, from Settings or the phone.
    func setAnswerRecommended(_ enabled: Bool) {
        guard (config.answerRecommended == true) != enabled else { return }
        config.answerRecommended = enabled ? true : nil; persist()
        island.autoAnswerChanged()
    }
    /// Each answer Side A gave by itself goes in autopilot.log, which the phone's Autopilot list reads back.
    func autoAnswered(_ item: Island.Pending, _ answer: IslandAnswer) {
        guard !isDemo else { return }
        guard case (.question(let questions), .answers(let answers, _)) = (item.request.action, answer) else { return }
        let reason = questions.compactMap { question in
            answers[question.question].map { "\(question.question) \($0.replacingOccurrences(of: IslandRequest.autoAnswerNote, with: ""))" }
        }.joined(separator: "; ")
        let title = item.title.replacingOccurrences(of: ": ", with: " - ")
        autopilotLog.write(Autopilot.answeredPrefix + "\(title): \(reason)".replacingOccurrences(of: "\n", with: " "))
    }
    /// Opens a Terminal window that stays on this account, whatever Autopilot does elsewhere.
    func openTerminal(_ id: String) async {
        guard let account = config.accounts.first(where: { $0.id == id }), !isDemo else { return }
        if !shellSwitching { await setShellSwitching(true) }
        await refreshActive()  // writes the per-account pins
        let pin = Self.pinName(account.name)
        let url = root.appendingPathComponent("runtime/open-\(pin).command")
        let script = "#!/bin/zsh\nexport SIDE_A_PIN=\(Shell.quote(pin))\nclear\necho \(Shell.quote("This terminal stays on \(account.name). Run claude as usual; sidea auto follows Side A again."))\nexec zsh -l\n"
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch { self.error = "Terminal could not be opened: \(error.localizedDescription)" }
    }
    /// Matches the bridge's pin_name: case-folded, each run of anything but a-z and 0-9 becomes one dash.
    static func pinName(_ name: String) -> String {
        let slug = name.folding(options: .caseInsensitive, locale: nil).unicodeScalars
            .map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "account" : slug
    }
    func setAuto(_ id: String, _ allowed: Bool) {
        guard let index = config.accounts.firstIndex(where: { $0.id == id }) else { return }
        config.accounts[index].allowAuto = allowed; persist()
        remote.events?.autopilotChanged()
    }
    /// Opens Settings on the Accounts tab; the player's lid opens while it is shown.
    func openLibrary() {
        settingsTab = .accounts
        addingAccount = true
        lidOpen = true
        Task { await refreshDependencies() }
        openSettings()
    }
    /// SwiftUI's openSettings action, registered by whichever scene appears first.
    @ObservationIgnored var showSettings: (() -> Void)?
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        showSettings?()
    }
    /// SwiftUI's openWindow for the Sessions window, registered the same way as showSettings.
    @ObservationIgnored var showSessions: (() -> Void)?
    /// Set before the Sessions window opens, so one macOS restores at launch closes again, as the player does.
    @ObservationIgnored var sessionsRequested = false
    @ObservationIgnored var sessionsOpen = false
    /// Opens the Sessions window, on one conversation when given.
    func openSessions(_ id: String? = nil) {
        sessionsRequested = true
        sessions.warm()
        NSApp.activate(ignoringOtherApps: true)
        showSessions?()
        if let id { sessions.open(id) }
    }
    @discardableResult func rename(_ id: String, _ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = config.accounts.firstIndex(where: { $0.id == id }) else { return false }
        guard config.accounts[index].name != name else { return true }
        let previous = config.accounts[index].name
        config.accounts[index].name = name
        guard persist() else { config.accounts[index].name = previous; return false }
        return true
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do { enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { self.error = "Open at login could not be changed: \(error.localizedDescription)" }
    }
    /// A name is optional: without one the account is named after its email, once sign-in says what that is.
    func addAccount(name: String, email: String, provider: AgentProvider = .claude) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = Account(name: name.isEmpty ? Self.name(from: email) ?? provider.title : name, email: email, allowAuto: true, provider: provider)
        config.accounts.append(account)
        if config.selectedID == nil { config.selectedID = account.id }
        guard persist() else { config.accounts.removeAll { $0.id == account.id }; return nil }
        if name.isEmpty { unnamed[account.id] = account.name }
        return account.id
    }
    /// Names an account added without one after the email sign-in confirmed; a rename in the meantime stands.
    private func takeName(_ index: Int) {
        let account = config.accounts[index]
        guard let given = unnamed.removeValue(forKey: account.id), account.name == given, let name = Self.name(from: account.email) else { return }
        config.accounts[index].name = name
    }
    /// An email's local part, as an account's name.
    static func name(from email: String) -> String? {
        email.split(separator: "@").first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }
    /// Runs the CLI's own browser sign-in in the background and verifies when it returns.
    @discardableResult func signIn(_ id: String) async -> Bool {
        guard !isDemo || checksLogins else { return await verify(id) }
        guard let account = config.accounts.first(where: { $0.id == id }), !isActive(account) else {
            error = "Switch to another account before signing in to this one again."; return false
        }
        guard !signingIn.contains(id) else { return false }
        signingIn.insert(id); defer { signingIn.remove(id) }
        do { _ = try await bridgeOutput(["login", id], timeout: 600) }
        catch { self.error = "Sign-in did not finish. Try again."; return false }
        let ok = await verify(id)
        // The login just changed, so what a read of the old one backed off from no longer applies.
        if ok { backoffUntil[id] = nil; await refreshUsage(id) }
        return ok
    }
    func signOut(_ id: String) {
        guard !config.accounts.contains(where: { $0.id == id && isActive($0) }) else { error = "Switch to another account before signing out of this one."; return }
        Task { _ = try? await bridgeOutput(["logout", id]) }
        if let index = config.accounts.firstIndex(where: { $0.id == id }) {
            config.accounts[index].ready = false; persist()
        }
        usage[id] = nil
    }
    func remove(_ id: String) {
        guard !config.accounts.contains(where: { $0.id == id && isActive($0) }) else { error = "Switch to another account before removing this one."; return }
        // Removal is metadata-only. Claude owns its Keychain item; sign out first
        // if credentials should be revoked. Keep conversation files intact.
        if let account = config.accounts.first(where: { $0.id == id }) {
            config.noteRemoved(account)
            if account.provider == .claude { Task { _ = try? await bridgeOutput(["forget", id]) } }
        }
        config.accounts.removeAll { $0.id == id }
        if config.selectedID == id { config.selectedID = config.accounts.first?.id }
        persist()
        forgetState(id)
    }
    /// What Side A kept about a removed account, so none of it lingers in the menu, the pool or the usage cache.
    private func forgetState(_ id: String) {
        usage[id] = nil; health[id] = nil; readAt[id] = nil; loginEnds[id] = nil
        usageAt[id] = nil; backoffUntil[id] = nil; primedAt[id] = nil; failing.remove(id)
        liveAt[id] = nil; limitHits[id] = nil; samples[id] = nil; paidWarned[id] = nil
        loginStamps[id] = nil; endWarned[id] = nil; renewedAt[id] = nil; recheckedAt[id] = nil; unnamed[id] = nil
        poolBlocked[id] = nil; signInWarned.remove(id); signInAsked.remove(id)
        poolTokens.forget(id)
        saveUsageCache()
    }
    func verify(_ id: String, reportError: Bool = true) async -> Bool {
        if isDemo && !checksLogins {
            guard let index = config.accounts.firstIndex(where: { $0.id == id }) else { return false }
            config.accounts[index].ready = true
            if config.accounts[index].email.isEmpty { config.accounts[index].email = "you@example.com" }
            config.forgetRemoval(config.accounts[index].email, config.accounts[index].provider)
            takeName(index)
            return true
        }
        guard config.accounts.contains(where: { $0.id == id }) else { return false }
        // One check per account: a second caller gets the same answer, and each says why if it asked to.
        let check = verifying[id] ?? Task { [weak self] in
            defer { self?.verifying[id] = nil }
            return await self?.checkLogin(id) ?? .failure(BridgeFailure(message: ""))
        }
        verifying[id] = check
        switch await check.value {
        case .success(let saved): return saved
        case .failure(let failure):
            if reportError { self.error = failure.localizedDescription }
            return false
        }
    }
    private func checkLogin(_ id: String) async -> Result<Bool, Error> {
        do {
            let result = try await bridgeOutput(["status", id])
            let status = try JSONDecoder().decode(AuthStatus.self, from: result)
            guard let index = config.accounts.firstIndex(where: { $0.id == id }) else { return .success(false) }
            guard status.loggedIn else {
                config.accounts[index].ready = false; persist()
                throw BridgeFailure(message: "Finish signing in, then return to Side A.")
            }
            guard !config.accounts.contains(where: { $0.id != id && $0.provider == config.accounts[index].provider && $0.ready && $0.email.caseInsensitiveCompare(status.email) == .orderedSame }) else {
                config.accounts[index].ready = false; persist()
                throw BridgeFailure(message: "That account is already in your library. Sign in with a different email in the browser.")
            }
            let wasReady = config.accounts[index].ready
            config.accounts[index].email = status.email
            config.accounts[index].ready = true
            config.forgetRemoval(status.email, config.accounts[index].provider)
            takeName(index)
            let saved = persist()
            if saved && !wasReady { analytics.capture(.accountConnected, provider: config.accounts[index].provider) }
            return .success(saved)
        } catch {
            // A timeout or unavailable CLI does not prove a previously verified login expired.
            return .failure(error)
        }
    }
    func saveDiagnostics(updateError: Int? = nil) {
        let panel = NSSavePanel()
        panel.title = "Save diagnostic summary"
        panel.message = "App and tool versions, session state, and why the last update failed. No accounts, paths, conversations, or credentials."
        panel.nameFieldStringValue = "Side-A-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let summary = DiagnosticSummary(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture,
            python: dependencies.python, claude: dependencies.claude, codex: dependencies.codex,
            libraryReadable: !startupError,
            inApplications: Bundle.main.bundlePath.hasPrefix("/Applications/") || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/"),
            updateError: updateError)
        do { try PrivateFile.write(summary, to: url) }
        catch { self.error = "The diagnostic summary could not be saved. Choose another location." }
    }
    /// Makes the selected account the Mac-wide login (PLAY on the player).
    func play() {
        guard !held, let account = selected else { return }
        guard account.ready else { openLibrary(); return }
        Task { await activate(account.id) }
    }
    func activate(_ id: String) async {
        do { try await use(id) } catch { self.error = error.localizedDescription }
    }
    /// Makes an account its provider's Mac-wide login, for PLAY and the phone alike; already active, nothing happens.
    /// Throws what the bridge said.
    func use(_ id: String) async throws {
        guard let account = config.accounts.first(where: { $0.id == id }), !isActive(account) else { return }
        guard !isDemo else { activeIDs[account.provider] = id; return }
        // Use means "run claude as this account", which only the shell line makes true.
        if account.provider == .claude && !shellSwitching { await setShellSwitching(true) }
        _ = try await bridgeOutput(["activate", id])
        selectionGeneration += 1
        activeIDs[account.provider] = id
        Sounds.play(.trackChange)
        analytics.capture(.handoffReady, provider: account.provider)
    }
    /// Move Now: runs the move Autopilot has held longest, without waiting for the pause. Nil when none is held.
    func moveNow() async throws -> HeldMove? {
        guard let move = heldMoves.values.min(by: { $0.since < $1.since }) else { return nil }
        let name = { (id: String) in self.config.accounts.first { $0.id == id }?.name ?? id }
        guard isDemo || busyLogins?[move.slot] == move.from else {
            heldMoves[move.slot] = nil
            throw BridgeFailure(message: "\(name(move.from)) isn't in that slot any more, so nothing moved.")
        }
        let moved = rotationSessions(on: move.from)
        let reason = move.share ? "Fable share" : "Moved now from the phone"
        if !isDemo { try await swap(move.slot, move.to, share: move.share) }
        heldMoves[move.slot] = nil
        autopilotLog.write("\(name(move.from)) → \(name(move.to)): moved now from the phone.")
        recordRotation(RotationRecord(at: Date().timeIntervalSince1970, kind: .moved, from: name(move.from), to: name(move.to), reason: reason, sessions: moved))
        pushMoved(to: name(move.to), reason: reason)
        return move
    }

    /// Trades the login in `slot` with `to`'s, so every session reading it continues as `to`; see bridge swap().
    private func swap(_ slot: String, _ to: String, share: Bool = false) async throws {
        _ = try await bridgeOutput(["swap", slot, to] + (share ? ["--share"] : []), timeout: 90)
        selectionGeneration += 1
        Sounds.play(.trackChange)
        _ = await refreshActive()
    }
    /// Keeps the Mac's existing login as a library account so switching never loses it. Side A does this on its own
    /// when it finds a new login (`quietly`); the Add button does it for a login the user removed or one that failed.
    @discardableResult func adoptMacLogin(_ provider: AgentProvider, quietly: Bool = false) async -> Bool {
        guard let email = unknownLogins[provider], !isDemo || testBridge != nil, !adopting.contains(provider),
              !config.accounts.contains(where: { $0.provider == provider && $0.email.caseInsensitiveCompare(email) == .orderedSame }) else { return false }
        adopting.insert(provider); defer { adopting.remove(provider) }
        let account = Account(name: Self.name(from: email) ?? "This Mac", email: email, allowAuto: true, provider: provider)
        config.accounts.append(account)
        guard persist() else { config.accounts.removeAll { $0.id == account.id }; return false }
        // Its row shows progress, not a Sign in button, while it's checked.
        signingIn.insert(account.id); defer { signingIn.remove(account.id) }
        let key = Self.loginKey(provider, email)
        do {
            _ = try await bridgeOutput(["adopt", account.id])
            guard await verify(account.id, reportError: !quietly) else { throw BridgeFailure(message: "") }
            adoptFailedAt[key] = nil
            unknownLogins[provider] = nil; activeIDs[provider] = account.id
            await refreshUsage(account.id)
            return true
        } catch {
            // A failed check already said why; a quiet try waits ten minutes and leaves the Add button meanwhile.
            if !quietly, !error.localizedDescription.isEmpty { self.error = error.localizedDescription }
            if quietly { adoptFailedAt[key] = Date() }
            config.accounts.removeAll { $0.id == account.id }; persist()
            return false
        }
    }
    private static func loginKey(_ provider: AgentProvider, _ email: String) -> String { "\(provider.rawValue):\(email.lowercased())" }
    /// Mac logins that get an Add button: ones the user removed, and ones Side A couldn't add on its own.
    var loginsToAdd: [AgentProvider: String] {
        unknownLogins.filter { provider, email in !adopting.contains(provider) && !addsOnItsOwn(provider, email) }
    }
    private func addsOnItsOwn(_ provider: AgentProvider, _ email: String) -> Bool {
        !config.wasRemoved(email, provider) && Date().timeIntervalSince(adoptFailedAt[Self.loginKey(provider, email)] ?? .distantPast) > 600
    }
    /// Adds each new Mac login, and confirms an unready account that already holds the Mac's login: Side A knows
    /// both already, so neither waits for a click.
    private func takeMacLogins() {
        for (provider, email) in unknownLogins where addsOnItsOwn(provider, email) && !adopting.contains(provider) {
            Task { await adoptMacLogin(provider, quietly: true) }
        }
        let now = Date()
        for id in activeIDs.values {
            guard let account = config.accounts.first(where: { $0.id == id }), !account.ready, !account.email.isEmpty,
                  !signingIn.contains(id), now.timeIntervalSince(recheckedAt[id] ?? .distantPast) > 600 else { continue }
            recheckedAt[id] = now
            Task { if await verify(id, reportError: false) { await refreshUsage(id) } }
        }
    }
    /// Reads one account's limits. A failed read keeps the last known numbers; only an
    /// expired login (stale) takes an account out of Autopilot, so a hiccup never causes a switch.
    func refreshUsage(_ id: String) async {
        guard Date() >= (backoffUntil[id] ?? .distantPast), !reading.contains(id) else { return }
        reading.insert(id); defer { reading.remove(id) }
        let started = Date()
        usageAt[id] = started
        do {
            var value = try JSONDecoder().decode(AccountUsage.self, from: try await bridgeOutput(["usage", id]))
            // A session reply that landed while this read was in flight is newer than its answer.
            if (liveAt[id] ?? 0) > started.timeIntervalSince1970, let current = usage[id] {
                for window in current.windows where ["five_hour", "seven_day"].contains(window.id) {
                    if let index = value.windows.firstIndex(where: { $0.id == window.id }) { value.windows[index] = window }
                }
            }
            if let hit = limitHits[id], hit.at > started.timeIntervalSince1970 { value = value.hitting(hit.limit, at: hit.at) }
            warnAboutPaidUsage(id, before: usage[id], after: value)
            usage[id] = value
            readAt[id] = max(started, readAt[id] ?? started)
            failing.remove(id)
            health[id] = nil
            signInWarned.remove(id)
            signInAsked.remove(id)
            autopilotLog.note("read \(id)", nil)
            sample(id, value.fiveHour, at: started.timeIntervalSince1970)
        } catch {
            let message = error.localizedDescription
            let kind = BridgeErrorKind(error)
            autopilotLog.note("read \(id)", "\(config.accounts.first { $0.id == id }?.name ?? id): usage read failed: \(message)")
            // Idle: nobody has used the login since it expired, so the last reading still holds.
            if kind == .idle {
                backoffUntil[id] = Date().addingTimeInterval(1800)
                health[id] = .idle
                // Free: Claude Code renews the login without running a model, then it is read again.
                if Date().timeIntervalSince(renewedAt[id] ?? .distantPast) > 600 { Task { await renew(id) } }
            } else {
                // The usage endpoint rate-limits frequent reads; back off rather than retry.
                let signIn = kind == .signIn
                let limited = kind == .rateLimited
                if limited {
                    // A rate limit is not a fault, and it shows the endpoint is reachable again: the last reading stays,
                    // marked with its time once it ages. Health and `failing` clear together, or Autopilot would skip
                    // an account the menu shows as fine.
                    if health[id] == .offline || health[id] == .idle { health[id] = nil; failing.remove(id) }
                } else {
                    if !signIn { health[id] = kind == .unconfirmed ? .verify : .offline }
                    failing.insert(id)
                }
                backoffUntil[id] = Date().addingTimeInterval(signIn ? 1800 : limited ? 600 : 300)
                if signIn { signedOut(id, message) }
            }
        }
        saveUsageCache()
    }
    /// Limits a running session saw (a Claude reply's headers, Codex's app server), kept when newer than the last
    /// reading. Returns whether they were.
    @discardableResult
    func takeLive(_ windows: [UsageWindow], for id: String, at: Double) -> Bool {
        guard !windows.isEmpty, at > (readAt[id]?.timeIntervalSince1970 ?? 0) else { return false }
        // A reply that began before a trade reports the previous login's limits; its weekly reset gives it away.
        if Planner.belongsElsewhere(windows, known: usage[id], now: Date().timeIntervalSince1970) { return false }
        var merged = usage[id] ?? AccountUsage(windows: [])
        for window in windows {
            if let index = merged.windows.firstIndex(where: { $0.id == window.id }) { merged.windows[index] = window } else { merged.windows.append(window) }
        }
        merged.stale = false
        usage[id] = merged
        readAt[id] = Date(timeIntervalSince1970: at)
        // A session's own reading is current even when the endpoint wants a sign-in, so the account can still move.
        failing.remove(id)
        if health[id] == .offline || health[id] == .idle { health[id] = nil }
        sample(id, windows.first { $0.id == "five_hour" }, at: at)
        return true
    }

    private func sample(_ id: String, _ five: UsageWindow?, at now: Double) {
        guard let five else { return }
        // A drop means the window reset; the old pace no longer applies.
        if let last = samples[id]?.last, five.percent < last.1 { samples[id] = [] }
        samples[id, default: []].append((now, five.percent))
        samples[id]?.removeAll { now - $0.0 > 1200 }
    }
    /// Refreshes what is due (menu open). The refresh button passes `force` but still
    /// respects backoff and never re-reads an account checked in the last minute.
    func refreshAll(force: Bool = false) async {
        await refreshActive()
        Task { await refreshReport() }
        await refresh(config.accounts.filter { $0.ready
            && (dueForRead($0) || (force && Date().timeIntervalSince(usageAt[$0.id] ?? .distantPast) > 60)) }.map(\.id))
    }
    /// Paid usage starts silently once a plan limit is hit. Warns when this month's spend grows,
    /// and once per limit when the account in use nears a limit with nowhere to move.
    private func warnAboutPaidUsage(_ id: String, before: AccountUsage?, after: AccountUsage) {
        guard let extra = after.extra, let name = config.accounts.first(where: { $0.id == id })?.name else { return }
        if let previous = before?.extra?.used, extra.used > previous + 0.004 {
            notify("\(name) is using paid credits", "\(extra.money(extra.used - previous)) more since the last check; \(extra.summary).")
            return
        }
        guard extra.enabled, activeIDs[.claude] == id else { return }
        let now = Date().timeIntervalSince1970
        guard let near = [after.fiveHour, after.weekly].compactMap({ $0 }).first(where: { $0.percent >= 90 && ($0.resetsAt ?? 0) > now }),
              paidWarned[id] != near.resetsAt else { return }
        let others = config.accounts.filter { $0.provider == .claude && $0.id != id }
        guard Planner.best(others, usage: planning(usage), health: health, active: nil, full: config.moveAt, now: now) == nil else { return }
        paidWarned[id] = near.resetsAt
        notify("\(name) will start charging soon", "It is at \(near.text(at: now)) of its \(near.label.lowercased()) limit and no other account has room. Past the limit, Claude bills paid credits (\(extra.summary)).")
    }
    /// Why an account shows no current numbers, in words; nil when its reading is current.
    func issueText(_ id: String) -> String? {
        switch health[id] {
        case .signIn(let other): other.map { "Login replaced by \($0)'s · sign in" } ?? "Sign in again"
        case .idle: usage[id] == nil ? "Renewing its login…"
            : "As of \((readAt[id] ?? Date()).formatted(date: .omitted, time: .shortened)) · renewing"
        case nil where (loginEnds[id] ?? .infinity) - Date().timeIntervalSince1970 < Self.signInWarning:
            "Sign-in ends \(UsageBar.format(loginEnds[id]!)) · sign in again"
        case .verify: "Checking whose login this is · retrying \(UsageBar.format((backoffUntil[id] ?? Date()).timeIntervalSince1970))"
        case nil where usage[id] != nil && Date().timeIntervalSince(readAt[id] ?? .distantPast) > 900:
            "As of \((readAt[id] ?? Date()).formatted(date: .omitted, time: .shortened))"
        case .offline: "Couldn't connect · retrying \(UsageBar.format((backoffUntil[id] ?? Date()).timeIntervalSince1970))"
        case nil: nil
        }
    }
    enum RowAction: Equatable { case busy, signIn, renew, use, inUse, none }
    /// The one button an account's row offers, in the menu and in Settings.
    func rowAction(for account: Account) -> RowAction {
        let isActive = isActive(account)
        if signingIn.contains(account.id) { return .busy }
        if !account.ready || (health[account.id]?.takesWork == false && !isActive) { return .signIn }
        if health[account.id] == .idle && usage[account.id] == nil && account.provider == .claude { return .renew }
        if isActive { return .inUse }
        return account.provider == .claude ? .use : .none
    }
    /// Has Claude Code renew an idle login (no model runs, no quota), then reads it again.
    func renew(_ id: String) async {
        guard !waking.contains(id) else { return }
        waking.insert(id); defer { waking.remove(id) }
        renewedAt[id] = Date()
        do {
            _ = try await bridgeOutput(["renew", id], timeout: 120)
            backoffUntil[id] = nil
            await refreshUsage(id)
        } catch {
            let message = error.localizedDescription
            autopilotLog.note("renew \(id)", "\(config.accounts.first { $0.id == id }?.name ?? id): renewing its login failed: \(message)")
            if BridgeErrorKind(error) == .signIn { signedOut(id, message); saveUsageCache() }
        }
    }
    /// Once per lapse, whichever path finds it: the usage read, a renewal or the pool. A replaced login says so itself.
    func warnSignIn(_ id: String, _ message: String) {
        guard !message.contains("login is now"), signInWarned.insert(id).inserted,
              let name = config.accounts.first(where: { $0.id == id })?.name else { return }
        notify("Sign in to \(name) again", "Its login ended, so Autopilot and the pool use your other accounts until you do.", signIn: id)
    }
    /// A read or renewal found the login refused. Records whose login now sits in the account's slot ("…its saved login
    /// is now someone@example.com's."), and says so once, since the menu row alone is easy to miss.
    func signedOut(_ id: String, _ message: String) {
        let other = message.firstMatch(of: /login is now (.+)'s\./).map { match in
            config.accounts.first { $0.email.caseInsensitiveCompare(String(match.1)) == .orderedSame }?.name ?? String(match.1)
        }
        if let other, health[id] != .signIn(replacedBy: other), let name = config.accounts.first(where: { $0.id == id })?.name {
            notify("Sign in to \(name) again", "Its saved login was replaced by \(other)'s.", signIn: id)
        }
        health[id] = .signIn(replacedBy: other)
        usage[id]?.stale = true
        warnSignIn(id, message)
    }
    func wake(_ id: String) async {
        renewedAt[id] = nil
        await renew(id)
        if health[id] == .idle { self.error = "\(config.accounts.first { $0.id == id }?.name ?? "This account") could not be renewed. Sign in to it again." }
    }
    /// What Autopilot may act on: accounts with a trustworthy latest reading.
    var plannable: [String: AccountUsage] { usage.filter { !failing.contains($0.key) } }
    /// Read in the last hour and not failing: a pace worked out from anything older would be a guess.
    func isFresh(_ id: String, now: Double) -> Bool {
        !failing.contains(id) && now - (readAt[id]?.timeIntervalSince1970 ?? 0) < 3600
    }
    /// True while Claude Code is running Fable and Autopilot follows it.
    var fableMode: Bool { config.followFable != false && claudeModel?.localizedCaseInsensitiveContains("fable") == true }
    /// Usage as Autopilot ranks Claude accounts: through the Fable cap while Fable is in use.
    func planning(_ values: [String: AccountUsage]) -> [String: AccountUsage] { fableMode ? values.compactMapValues(\.forFable) : values }
    func setPriority(_ id: String, _ priority: AccountPriority) {
        guard let index = config.accounts.firstIndex(where: { $0.id == id }) else { return }
        config.accounts[index].priority = priority == .normal ? nil : priority
        persist()
        remote.events?.autopilotChanged()
    }
    func setFollowFable(_ value: Bool) { config.followFable = value; persist() }
    func setSwapAt(_ value: Double) { config.swapAt = value; persist() }
    func setSync(_ value: Bool) {
        config.sync = value; persist(); reportAt = .distantPast
        preferences?.syncChanged()
        Task { await refreshReport() }
    }
    /// iCloud Drive's Side A folder, when iCloud Drive is on.
    var syncFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: drive.path) ? drive.appendingPathComponent("Side A") : nil
    }
    private var preferencesSyncFolder: URL? { config.sync == true ? syncFolder?.appendingPathComponent("preferences") : nil }
    private struct UsageCache: Codable {
        var usage: [String: AccountUsage]; var at: [String: Date]
        var backoff: [String: Date]?; var primed: [String: Date]?
        var active: [String: String]?; var failing: [String]?; var issues: [String: String]?; var readAt: [String: Date]?
    }
    private var reportURL: URL { root.appendingPathComponent("runtime/report.json") }
    private var usageCacheURL: URL { root.appendingPathComponent("runtime/usage-cache.json") }
    private func saveUsageCache() {
        try? PrivateFile.write(UsageCache(usage: usage, at: usageAt, backoff: backoffUntil, primed: primedAt,
                                          active: Dictionary(uniqueKeysWithValues: activeIDs.map { ($0.key.rawValue, $0.value) }),
                                          failing: Array(failing), issues: health.mapValues(\.saved), readAt: readAt),
                               to: usageCacheURL)
    }
    /// Active accounts, and any a running session uses, change fastest. An idle account at a limit
    /// can only change if its limit resets early, so it is read hourly until the reset.
    private func dueForRead(_ account: Account) -> Bool {
        let now = Date().timeIntervalSince1970
        let used = isActive(account) || busyLogins?.values.contains(account.id) == true
        if !used, let value = usage[account.id], !value.stale,
           let reset = [value.fiveHour, value.weekly].compactMap({ $0 }).filter({ $0.percent >= Planner.limited }).compactMap(\.resetsAt).max(),
           reset > now {
            return Date().timeIntervalSince(usageAt[account.id] ?? .distantPast) >= 3600
        }
        // The usage endpoint rate-limits a login read every minute or two; three minutes stays clear.
        // While sessions report live limits, the endpoint is only needed for what they can't see
        // (Fable, paid usage, use on other devices).
        let live = now - (liveAt[account.id] ?? 0) < 600
        let interval: TimeInterval = live ? 900 : used ? (nearLimit(account.id) ? 90 : 180) : 600
        return Date().timeIntervalSince(usageAt[account.id] ?? .distantPast) >= interval - 1
    }
    /// Minutes until the account's 5-hour limit at its recent pace.
    func minutesToLimit(_ id: String) -> Double? { Planner.minutesToLimit(samples[id] ?? [], full: config.moveAt, now: Date().timeIntervalSince1970) }
    private func nearLimit(_ id: String) -> Bool {
        (usage[id]?.fiveHour?.percent ?? 0) >= 85 || (minutesToLimit(id) ?? .infinity) < 15
    }
    static let statusPage = URL(string: "https://status.claude.com")!

    /// Errors during an incident are Anthropic's, not the account's: say so once, and show it in the menu while it lasts.
    private func checkStatus() async {
        var request = URLRequest(url: Self.statusPage.appendingPathComponent("api/v2/summary.json"), timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let found = Outage.parse(data)
        if found != outage { outage = found }
        guard let found, outageNotified != found.id else { return }
        outageNotified = found.id
        UserDefaults.standard.set(found.id, forKey: "outageNotified")
        notify("Claude is having trouble", "\(found.name). Errors in your sessions may be Anthropic's, not your accounts'.")
        island.show(.limit, "Claude is having trouble", found.name)
    }

    static let priceList = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private var pricesURL: URL { root.appendingPathComponent("runtime/prices.json") }

    /// API list prices change with each model; the public list is fetched daily and kept for offline use.
    private func refreshPrices() async {
        if APIPrice.published.isEmpty, let saved = try? Data(contentsOf: pricesURL) {
            let prices = APIPrice.parsePublished(saved)
            if !prices.isEmpty {
                APIPrice.published = prices
                pricesUpdated = (try? pricesURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
        }
        var request = URLRequest(url: Self.priceList, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let prices = APIPrice.parsePublished(data)
        // A list without Claude prices is a broken download, not a price change.
        guard prices.count >= 5 else { return }
        APIPrice.published = prices
        pricesUpdated = Date()
        try? data.write(to: pricesURL, options: .atomic)
    }

    static let weeklyAlertKey = "weeklyAlert"
    /// How long before a sign-in ends the menu, the notification and Autopilot start saying so.
    static let signInWarning: TimeInterval = 3 * 86_400
    static let weeklyAlertDefault = 80.0

    /// The user's own line: one notification per account and week when weekly use passes it.
    private func alertWeekly() {
        let threshold: Double = PreferencesMirror.value(Self.weeklyAlertKey)
        guard threshold > 0 else { return }
        let before = UserDefaults.standard.dictionary(forKey: "weeklyAlerted") as? [String: Double] ?? [:]
        var sent = before
        let now = Date().timeIntervalSince1970
        for account in config.accounts where account.ready {
            guard let weekly = usage[account.id]?.weekly, weekly.percent >= threshold, let reset = weekly.resetsAt,
                  reset > now, sent[account.id] != reset else { continue }
            sent[account.id] = reset
            notify("\(account.name) passed \(Int(threshold))% of its week", "\(weekly.text(at: now)) used; it resets \(UsageBar.format(reset)).")
        }
        if sent != before { UserDefaults.standard.set(sent, forKey: "weeklyAlerted") }
    }

    /// One sysctl most of the time; Python only runs to total the sessions once macOS reports memory pressure.
    private func checkMemory() async {
        guard let level = MemoryPressure.currentLevel(), MemoryPressure.levelTight(level) else { memoryWarning = nil; return }
        struct Live: Decodable { struct Session: Decodable { let memory: Int? }; let sessions: [Session] }
        guard let data = try? await bridgeOutput(["sessions", "live"], timeout: 30, priority: .utility),
              let live = try? JSONDecoder().decode(Live.self, from: data) else { return }
        let pressure = MemoryPressure(sessionsMB: live.sessions.compactMap(\.memory).reduce(0, +), level: level)
        memoryWarning = pressure.tight ? pressure.line : nil
        guard pressure.tight, MemoryPressure.shouldNotify(now: Date(), last: memoryNotifiedAt) else { return }
        memoryNotifiedAt = Date()
        notify("Memory is tight", pressure.notification)
    }

    /// `signIn`: the account the notification's Sign In button signs in to.
    func notify(_ title: String, _ body: String, signIn: String? = nil) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        Self.post(title, body, signIn: signIn)
    }
    /// Nonisolated: the authorization callback runs on a background queue, and a closure formed in
    /// this main-actor class traps there under Swift 6's isolation checks (found by brandedDaniel).
    private nonisolated static func post(_ title: String, _ body: String, signIn: String?) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            if let signIn {
                content.categoryIdentifier = NotificationRouter.signInCategory
                content.userInfo = [NotificationRouter.signInKey: signIn]
            }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
    @discardableResult func refreshActive() async -> Bool {
        let generation = selectionGeneration
        struct Active: Decodable { let busyProblem: String?; let healed: [String]?; let accountID: String?; let email: String; let codexAccountID: String?; let codexEmail: String; let claudeModel: String?; let logins: [String: Double]?; let loginEnds: [String: Double]?; let live: [String: Live]?; let busy: [Busy]?; let limits: [String: Hit]?; let models: [String: [String?]]?; let quiet: [String: Double]? }
        struct Hit: Decodable { let limit: String; let at: Double; let sessions: [String]? }
        struct Busy: Decodable { let slot: String; let account: String? }
        struct Live: Decodable { let at: Double; let windows: [UsageWindow] }
        activeProblem = nil
        let data: Data
        do { data = try await bridgeOutput(["active"]) } catch {
            activeProblem = (error as? BridgeFailure)?.message ?? error.localizedDescription
            return false
        }
        guard let value = try? JSONDecoder().decode(Active.self, from: data) else {
            activeProblem = "its answer couldn't be read"
            return false
        }
        busyProblem = value.busyProblem
        for line in value.healed ?? [] {
            autopilotLog.write(line)
            notify("Side A fixed a login", line)
        }
        guard generation == selectionGeneration else { return false }
        activeIDs = [.claude: value.accountID, .codex: value.codexAccountID].compactMapValues { $0 }
        claudeModel = value.claudeModel
        // A login that changed (signed in again, or refreshed by Claude Code) is read now:
        // the back-off and any old reading belonged to the previous login.
        for (id, stamp) in value.logins ?? [:] {
            if let seen = loginStamps[id], seen != stamp {
                backoffUntil[id] = nil; usageAt[id] = nil; health[id] = nil; failing.remove(id)
            }
            loginStamps[id] = stamp
        }
        let ends = (value.loginEnds ?? [:]).mapValues { $0 / 1000 }
        if ends != loginEnds { loginEnds = ends; remoteUsageChanged() }
        slotModels = value.models ?? [:]
        slotQuiet = value.quiet ?? [:]
        busyLogins = value.busy.map { Dictionary($0.compactMap { busy in busy.account.map { (busy.slot, $0) } }, uniquingKeysWith: { a, _ in a }) }
        // Each reply's limits, as a session saw them: newer than the last endpoint read wins.
        var changed = false
        for (id, live) in value.live ?? [:] { liveAt[id] = live.at }
        for (id, live) in value.live ?? [:] where takeLive(live.windows, for: id, at: live.at) { changed = true }
        // A running session's own limit error is proof the account is out, even while the usage
        // endpoint answers 429 for it: that limit counts as full until a newer reading.
        let stopped = limitHits.mapValues(\.sessions)
        limitHits = (value.limits ?? [:]).mapValues { ($0.limit, $0.at, $0.sessions ?? []) }
        if limitHits.mapValues(\.sessions) != stopped { remote.events?.liveChanged() }
        for (id, hit) in value.limits ?? [:] where hit.at > (readAt[id]?.timeIntervalSince1970 ?? 0) {
            if let account = config.accounts.first(where: { $0.id == id }), Date().timeIntervalSince1970 - hit.at < 300 {
                let limit = hit.limit == "seven_day" ? "weekly" : UsageWindow.label(of: hit.limit).replacingOccurrences(of: "Weekly ", with: "")
                island.show(.limit, "\(account.name) hit its \(limit) limit",
                            config.smartMode && account.allowAuto ? "Autopilot is moving its sessions to another account." : "Its sessions wait until the limit resets.")
            }
            usage[id] = (usage[id] ?? AccountUsage(windows: [])).hitting(hit.limit, at: hit.at)
            readAt[id] = Date(timeIntervalSince1970: hit.at)
            if health[id] == .offline || health[id] == .idle { health[id] = nil; failing.remove(id) }
            changed = true
        }
        if changed { saveUsageCache() }
        for (id, end) in loginEnds where end - Date().timeIntervalSince1970 < Self.signInWarning && endWarned[id] != end {
            endWarned[id] = end
            if let name = config.accounts.first(where: { $0.id == id })?.name {
                notify("Sign in to \(name) again soon", "Its sign-in ends \(UsageBar.format(end)). Signing in again keeps its limits readable and Autopilot using it.")
            }
        }
        unknownLogins = [.claude: value.accountID == nil ? value.email : "", .codex: value.codexAccountID == nil ? value.codexEmail : ""]
            .filter { !$0.value.isEmpty }
        takeMacLogins()
        return true
    }
    /// Ten minutes old is fresh enough on screen; in the background only the schedule needs it, hourly.
    func refreshReport(maxAge: TimeInterval = 600) async {
        guard !isDemo, Date().timeIntervalSince(reportAt) > maxAge else { return }
        reportAt = Date()
        // The first scan reads every transcript from the last 30 days; later scans use a cache.
        if let data = try? await bridgeOutput(["report"] + (config.sync == true ? syncFolder.map { ["--sync", $0.path] } ?? [] : []), timeout: 900), let value = try? JSONDecoder().decode(UsageReport.self, from: data) {
            if value != report { report = value; try? PrivateFile.write(value, to: reportURL) }
        }
        // The report is what creates machine-id, and an hourly look covers a change the watcher missed.
        await preferences?.sync()
    }
    /// True when a session reported new limits, at most every 15 s, so a trade happens
    /// between replies rather than up to a minute later.
    private func liveChanged() -> Bool {
        let url = root.appendingPathComponent("runtime/live")
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              date > liveSeen, Date().timeIntervalSince(liveSeen) > 15 else { return false }
        liveSeen = Date()
        return true
    }
    /// True once per touch of the marker the opt-in StopFailure hook writes on a rate limit.
    private func limitHit() -> Bool {
        let url = root.appendingPathComponent("runtime/limit-hit")
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        defer { limitMarkerDate = date }
        guard let seen = limitMarkerDate, date > seen else { return false }
        // Re-read the active account now instead of waiting for its next poll.
        // Throttled so many sessions hitting a limit cannot hammer the usage endpoint.
        if let id = activeIDs[.claude], Date().timeIntervalSince(usageAt[id] ?? .distantPast) > 30 { usageAt[id] = nil }
        return true
    }
    /// One autopilot step: refresh usage, move each provider's Mac-wide login, start idle windows.
    private func tick() async {
        guard !isDemo, !startupError else { return }
        defer { remote.events?.autopilotChanged() }
        if python == nil { await refreshDependencies() }
        guard python != nil else { return }
        await preferences?.effectsReady()
        if Date().timeIntervalSince(memoryCheckedAt) > 120 {
            memoryCheckedAt = Date()
            Task { await checkMemory() }
            Task { await syncCodexPoolHomes() }
            // "Turn on Tailscale" clears by itself once it's on.
            if poolShareProblem != nil { Task { await syncPoolShare() } }
        }
        // Without knowing who is active, a "switch" could only re-pick the current account.
        guard await refreshActive() else {
            if let activeProblem { autopilotLog.note("active", "Couldn't read which logins are in use (\(activeProblem)); Autopilot waits.") }
            return
        }
        autopilotLog.note("active", nil)
        await refresh(config.accounts.filter { $0.ready && dueForRead($0) }.map(\.id))
        Task { await refreshReport(maxAge: 3600) }
        if Date().timeIntervalSince(pricesCheckedAt) > 86400 {
            pricesCheckedAt = Date()
            Task { await refreshPrices() }
        }
        if Date().timeIntervalSince(statusCheckedAt) > 300 {
            statusCheckedAt = Date()
            Task { await checkStatus() }
        }
        alertWeekly()
        // Keeps session search close to current, so opening Sessions shows results at once.
        if Date().timeIntervalSince(sessionsIndexedAt) > 1800 {
            sessionsIndexedAt = Date()
            Task { _ = try? await bridgeOutput(["sessions", "index", "--seconds", "20"], priority: .background) }
        }
        guard config.smartMode else { heldMoves = [:]; autopilotLog.note("mode", "Autopilot is off."); return }
        autopilotLog.note("mode", nil)
        let now = Date().timeIntervalSince1970
        if let email = unknownLogins[.claude] { autopilotLog.note("unknown", "The Mac's Claude login (\(email)) isn't in the library; nothing moves until it's added.") } else { autopilotLog.note("unknown", nil) }
        // Codex: the desktop app keeps its own copy of the login, and OpenAI revokes a login
        // whose refresh token is used twice, so Codex is never switched automatically.
        for provider in [AgentProvider.claude] where unknownLogins[provider] == nil {
            let accounts = config.accounts.filter { $0.provider == provider }
            let current = activeIDs[provider]
            let plannable = planning(self.plannable)
            let fable = self.plannable.compactMapValues(\.forFable)
            // Each running login is planned by what its own sessions use; unknown models follow the newest session.
            let planned = { (slot: String) in
                switch Planner.needsFable(self.slotModels[slot]) { case true?: fable; case false?: self.plannable; case nil: plannable }
            }
            let name = { (id: String) in self.config.accounts.first { $0.id == id }?.name ?? "" }
            // Logins running sessions read, by slot. Unknown (processes can't be listed) means no
            // trades; only new commands move.
            var slots = busyLogins ?? [:]
            var held: [String: HeldMove] = [:]
            defer { if heldMoves != held { heldMoves = held } }
            autopilotLog.note("busy", busyLogins == nil ? "Running sessions couldn't be listed (\(busyProblem ?? "unknown")); only new commands move." : nil)
            let busy = { Set(slots.values).union([current].compactMap { $0 }) }
            for slot in slots.keys.sorted(by: { slots[$0] == current && slots[$1] != current }) {
                // Settings may have changed during the last trade.
                guard config.smartMode, let id = slots[slot], let account = config.accounts.first(where: { $0.id == id }) else { continue }
                let key = "slot \(slot)"
                // A failed read is not evidence of a limit; only a signed-out account moves.
                if failing.contains(id), usage[id]?.stale != true {
                    autopilotLog.note(key, "\(account.name): its last usage read failed (\(health[id]?.saved ?? "unknown")), so it isn't moved on that reading.")
                    continue
                }
                // An account with Autopilot off, or mid sign-in, is never moved automatically.
                if !account.allowAuto || signingIn.contains(id) {
                    autopilotLog.note(key, "\(account.name): \(account.allowAuto ? "signing in" : "Autopilot is off for this account"); not moved.")
                    continue
                }
                // Trade only with an account no session is using, so no session lands on the full one.
                let free = config.accounts.filter { $0.provider == provider && ($0.id == id || (!busy().contains($0.id) && !signingIn.contains($0.id))) }
                var target = Planner.best(free, usage: planned(slot), health: health, active: id, full: config.moveAt, now: now)
                var partner: String?
                if target == nil, let share = Planner.fableShare(for: slot, slots: slots, models: slotModels, accounts: accounts, usage: self.plannable, health: health,
                                                                 excluded: Set([current].compactMap { $0 }).union(signingIn).union(failing), full: config.moveAt, now: now) {
                    target = share.account; partner = share.slot
                }
                guard let best = target, best != id else {
                    let full = usage[id].map { !Planner.hasHeadroom($0, full: config.moveAt, now: now) } ?? false
                    if autopilotLog.note(key, full ? "\(account.name) is full and no free account has room." : nil), full, let value = planned(slot)[id] {
                        recordRotation(RotationRecord(at: now, kind: .stuck, from: account.name, reason: Planner.tightest(value, now: now).map { "\($0.label) \($0.text(at: now))" } ?? ""))
                    }
                    if full { noteStuck(account, slot: slot, others: accounts, now: now) } else { stuckNotified.remove(slot) }
                    continue
                }
                if let target = config.accounts.first(where: { $0.id == best }),
                   Planner.priorityMoveWaits(from: account, to: target, usage: planned(slot)[id], movedAt: slotMovedAt[slot], full: config.moveAt, now: now) {
                    if autopilotLog.note(key, "\(account.name) → \(target.name): this login moved recently, so a move only for priority waits.") {
                        recordRotation(RotationRecord(at: now, kind: .priorityWait, from: account.name, to: target.name, reason: "Moved recently"))
                    }
                    continue
                }
                let hold = { (reason: String) in
                    held[slot] = HeldMove(slot: slot, from: id, to: best, share: partner != nil, reason: reason,
                                          since: self.heldMoves[slot].flatMap { $0.from == id && $0.to == best ? $0.since : nil } ?? Date())
                }
                if Planner.waitsForPause(planned(slot)[id], quiet: slotQuiet[slot], full: config.moveAt, now: now) {
                    autopilotLog.note(key, "\(account.name) → \(name(best)): waiting for its sessions to pause (quiet \(Int(slotQuiet[slot] ?? 0))s of \(Int(Planner.pause))s).")
                    hold("Waiting for its sessions to pause, so they keep their cache.")
                    continue
                }
                // A share moves the partner's sessions too; they keep their cache unless they've paused as well.
                if let partner, (slotQuiet[partner] ?? .infinity) < Planner.pause {
                    autopilotLog.note(key, "\(account.name) → \(name(best)): waiting for \(name(best))'s sessions to pause before a Fable share.")
                    hold("Waiting for \(name(best))'s sessions to pause before a Fable share.")
                    continue
                }
                let attempt = "\(slot) \(best)"
                // Before the trade: afterwards these sessions read as the new account's, and its numbers are the old login's.
                let moved = rotationSessions(on: id)
                let reason = partner != nil ? "Fable share" : config.accounts.first { $0.id == best }.map { MoveReason.text(from: account, to: $0, usage: planned(slot)[id], now: now, full: config.moveAt) } ?? ""
                do {
                    try await swap(slot, best, share: partner != nil)
                } catch {
                    autopilotLog.note(key, "\(account.name) → \(name(best)): move failed: \(error.localizedDescription)")
                    if !swapFailures.contains(attempt) {
                        swapFailures.insert(attempt)
                        notify("Couldn't move off \(account.name)", "\(name(best)) has room, but moving \(account.name)'s sessions failed: \(error.localizedDescription) Switch in the menu, or see autopilot.log.")
                    }
                    continue
                }
                swapFailures.remove(attempt)
                stuckNotified.remove(slot)
                slotMovedAt[slot] = now
                autopilotLog.note(key, nil)
                autopilotLog.write("\(account.name) → \(name(best)): moved\(partner.map { " (Fable share with \(name($0)))" } ?? "").")
                recordRotation(RotationRecord(at: now, kind: .moved, from: account.name, to: name(best), reason: reason, sessions: moved))
                pushMoved(to: name(best), reason: reason)
                slots[slot] = best
                if let partner {
                    slots[partner] = id
                    notify("Fable continues on \(name(best))", "\(name(id)) spent its Fable share. Its Fable sessions continue as \(name(best)), and \(name(best))'s other sessions continue as \(name(id)).")
                    island.show(.track, "Fable continues on \(name(best))", "\(name(best))'s other sessions now run on \(name(id)), which still has room.")
                } else {
                    notify("Now playing: \(name(best))", "\(name(id)) is near its limit. Its running sessions continue as \(name(best)) within a minute, nothing to restart.")
                    island.show(.track, "Now playing: \(name(best))", "\(name(id)) is near its limit; its sessions continue as \(name(best)).")
                }
            }
            // New commands: if the account they use is still full (no trade, or no sessions on it), point them elsewhere.
            if config.smartMode, shellSwitching, let current = activeIDs[provider], !signingIn.contains(current),
               config.accounts.first(where: { $0.id == current })?.allowAuto != false,
               !(failing.contains(current) && usage[current]?.stale != true),
               let best = Planner.best(config.accounts.filter { $0.provider == provider && ($0.id == current || !busy().contains($0.id)) },
                                       usage: plannable, health: health, active: current, full: config.moveAt, now: now), best != current {
                let from = config.accounts.first { $0.id == current }, to = config.accounts.first { $0.id == best }
                let reason = from.flatMap { from in to.map { MoveReason.text(from: from, to: $0, usage: plannable[current], now: now, full: config.moveAt) } } ?? ""
                await activate(best)
                autopilotLog.write("New commands: \(name(current)) → \(name(best))\(activeIDs[provider] == best ? "" : " failed\(error.map { ": \($0)" } ?? "")").")
                if activeIDs[provider] == best {
                    recordRotation(RotationRecord(at: now, kind: .newCommands, from: name(current), to: name(best), reason: reason))
                    pushMoved(to: name(best), reason: reason)
                    notify("Now playing: \(name(best))", "\(name(current)) is near its limit. New claude commands use \(name(best)).")
                    island.show(.track, "Now playing: \(name(best))", "New claude commands use \(name(best)).")
                }
            }
            if config.smartMode, activeIDs[provider] == nil, shellSwitching, let best = Planner.best(accounts, usage: plannable, health: health, active: nil, full: config.moveAt, now: now) {
                await activate(best)
            }
            // No listed session named it, or none could be listed: it can still be full with only a signed-out account free.
            if let current = activeIDs[provider], !slots.values.contains(current), let account = accounts.first(where: { $0.id == current }), account.allowAuto {
                let full = usage[current].map { !Planner.hasHeadroom($0, full: config.moveAt, now: now) } ?? false
                if full, (Planner.best(accounts, usage: plannable, health: health, active: current, full: config.moveAt, now: now) ?? current) == current {
                    noteStuck(account, slot: "new commands", others: accounts, now: now)
                } else { stuckNotified.remove("new commands") }
            }
            if provider == .claude, let next = Planner.nextAvailable(accounts, usage: plannable, full: config.moveAt, now: now), Planner.best(accounts, usage: plannable, health: health, active: current, full: config.moveAt, now: now) == nil {
                if !exhaustedNotified {
                    exhaustedNotified = true
                    pushAllOut(fable: fableMode, back: next.0.name, at: next.1)
                    notify(fableMode ? "Fable is used up" : "All tracks played",
                           fableMode ? "Every account has spent its Fable share. Switch to another model, or wait until \(UsageBar.format(next.1))."
                                     : "\(next.0.name) is back \(UsageBar.format(next.1)).")
                    island.show(.limit, fableMode ? "Fable is used up" : "All tracks played",
                                fableMode ? "Every account has spent its Fable share until \(UsageBar.format(next.1))." : "\(next.0.name) is back \(UsageBar.format(next.1)).")
                }
            } else if provider == .claude { exhaustedNotified = false }
        }
        let minute = Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())
        // Until the report has loaded, the schedule is unknown, not absent: wait for it.
        guard let report, WorkSchedule(report.activity)?.allowsPriming(atMinute: minute) ?? true else { return }
        for account in config.accounts where Planner.shouldPrime(account, usage: plannable[account.id], full: config.moveAt, now: now)
            && Date().timeIntervalSince(primedAt[account.id] ?? .distantPast) > 1800 {
            primedAt[account.id] = Date()
            saveUsageCache()
            autopilotLog.write("\(account.name): primed its 5-hour window.")
            let primed = (try? await bridgeOutput(["prime", account.id], timeout: 200)) != nil
            backoffUntil[account.id] = nil
            await refreshUsage(account.id)
            // Listed but not started by a message: a verified Ultra account has no such limit, so ask again tomorrow, not every half hour.
            if primed, (usage[account.id]?.capacity ?? 1) >= 20, usage[account.id]?.fiveHour?.resetsAt == nil { primedAt[account.id] = Date().addingTimeInterval(86_400); saveUsageCache() }
        }
    }
    /// Sessions at a limit with nowhere to go are otherwise silent: says once what would free them.
    private func noteStuck(_ account: Account, slot: String, others: [Account], now: Double) {
        guard stuckNotified.insert(slot).inserted else { return }
        let signedOut = Planner.signedOut(others, except: account.id, health: health)
        let inUse = others.first { other in
            other.id != account.id && other.ready && other.allowAuto && health[other.id]?.takesWork != false && (busyLogins ?? [:]).values.contains(other.id)
                && plannable[other.id].map { Planner.hasHeadroom($0, full: config.moveAt, now: now) } == true
        }
        var fixes: [String] = []
        if !signedOut.isEmpty { fixes.append("sign in to \(signedOut.map(\.name).joined(separator: ", "))") }
        if let inUse, config.pool != true { fixes.append("turn on Pool mode so these sessions can share \(inUse.name) next time") }
        let reset = usage[account.id].flatMap { value in [value.fiveHour, value.weekly].compactMap { $0 }.filter { $0.percent >= config.moveAt }.compactMap(\.resetsAt).max() }
        let wait = reset.map { "\(account.name) is back \(UsageBar.format($0))." } ?? ""
        pushStuck(account, reset: reset)
        let advice = fixes.isEmpty ? "" : " To keep going, " + fixes.joined(separator: ", or ") + "."
        let body = (wait + advice).trimmingCharacters(in: .whitespaces)
        guard let free = signedOut.first else { notify("\(account.name) is full, with no account free", body); return }
        guard signInAsked.insert(free.id).inserted else { return }
        notify("\(account.name) is full; \(free.name) needs a sign-in", body, signIn: free.id)
    }
    func setMenuBarOnly(_ value: Bool) {
        config.menuBarOnly = value; persist()
        NSApp.setActivationPolicy(value ? .accessory : .regular)
    }
}
