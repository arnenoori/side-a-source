import AppKit
import SideACore

/// UserDefaults stays where each setting is read and written. This keeps the shared ones in step with
/// `preferences.json`, and, with sync on, with one file per Mac in iCloud Drive.
@MainActor
final class PreferencesMirror {
    struct Spec {
        let kind: PreferenceKind
        let fallback: PreferenceValue
        var valid: (PreferenceValue) -> Bool = { _ in true }
    }

    /// Set values from a preferences domain, and when that domain was last written.
    struct Domain {
        let values: [String: Any]
        let modified: Double
    }

    /// Where every shared setting's default lives: readers and Settings' switches take theirs from here.
    static let shared: [String: Spec] = [
        Island.onKey: Spec(kind: .bool, fallback: .bool(false)),
        Island.eventsKey: Spec(kind: .bool, fallback: .bool(true)),
        Island.waitingKey: Spec(kind: .bool, fallback: .bool(true)),
        Island.finishedKey: Spec(kind: .bool, fallback: .bool(true)),
        Island.finishedClearKey: Spec(kind: .int, fallback: .int(0), valid: { value in
            if case .int(let seconds) = value { return seconds >= 0 }
            return false
        }),
        Island.finishedAutomatedKey: Spec(kind: .bool, fallback: .bool(false)),
        Island.screenKey: Spec(kind: .string, fallback: .string("notch"), valid: { [.string("notch"), .string("active")].contains($0) }),
        KeepAwakeController.enabledKey: Spec(kind: .bool, fallback: .bool(false)),
        Sounds.enabledKey: Spec(kind: .bool, fallback: .bool(true)),
        Sounds.volumeKey: Spec(kind: .double, fallback: .double(0.5), valid: { value in
            if case .double(let volume) = value { return (0...1).contains(volume) }
            return false
        }),
        WaitingNotifier.enabledKey: Spec(kind: .bool, fallback: .bool(true)),
        AccountStore.weeklyAlertKey: Spec(kind: .double, fallback: .double(AccountStore.weeklyAlertDefault), valid: { value in
            if case .double(let percent) = value { return (0...100).contains(percent) }
            return false
        }),
        MenuPlayer.enabledKey: Spec(kind: .bool, fallback: .bool(false)),
        SessionStore.resumeTerminalKey: Spec(kind: .string, fallback: .string(""), valid: { value in
            if case .string(let name) = value { return name.isEmpty || TerminalApp(rawValue: name) != nil }
            return false
        })
    ]
    /// What a shared setting reads as until someone sets it.
    static func fallback<Value>(_ key: String) -> Value {
        guard let value = shared[key]?.fallback.raw as? Value else { preconditionFailure("\(key) isn't a shared \(Value.self) setting") }
        return value
    }
    /// A shared setting as set here, else its fallback.
    static func value<Value>(_ key: String, in defaults: UserDefaults = .standard) -> Value {
        defaults.object(forKey: key) as? Value ?? fallback(key)
    }
    static let pendingKey = "sharedPreferencesPendingEffects"
    private nonisolated static let largestFile = 256 * 1024

    private let fileURL: URL
    private let defaults: UserDefaults
    private let domains: () -> [Domain]
    private let syncFolder: () -> URL?
    private let machineID: () -> String?
    private let effects: (Set<String>) async -> Void

    private var file = SharedPreferences()
    private var lastKnown: [String: PreferenceValue] = [:]
    private var pending: Set<String> = []
    /// The file came from a newer format; this copy leaves it and its settings alone.
    private var frozen = false
    private var stopped = false
    private var effectsAllowed = false
    private var runningEffects = false
    private var exported: Data?
    private var observers: [any NSObjectProtocol] = []
    private var watcher: FolderWatcher?
    private var saving: Task<Void, Never>?
    private var syncing: Task<Void, Never>?
    private(set) var effectRun: Task<Void, Never>?

    init(root: URL, defaults: UserDefaults = .standard, domains: @escaping () -> [Domain] = PreferencesMirror.installedDomains,
         syncFolder: @escaping () -> URL?, effects: @escaping (Set<String>) async -> Void) {
        fileURL = root.appendingPathComponent("preferences.json")
        self.defaults = defaults
        self.domains = domains
        self.syncFolder = syncFolder
        self.effects = effects
        let machine = root.appendingPathComponent("machine-id")
        machineID = {
            guard let id = try? String(contentsOf: machine, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
            return id
        }
    }

    /// Runs before anything reads a shared setting, and never touches iCloud Drive: a file there may have to
    /// download first, so `sync()` reads those off the main thread.
    func load() {
        switch (try? Data(contentsOf: fileURL)).map(SharedPreferences.decode) {
        case .file(let stored): file = stored
        case .newer: frozen = true; return
        case .corrupt, nil: break
        }
        pending = Set(defaults.stringArray(forKey: Self.pendingKey) ?? [])
        adoptSetValues()
        applyStored()
        writeLocal()
    }

    /// Only values someone set count, and the most recently written domain wins between them.
    private func adoptSetValues() {
        let machine = machineID()
        for domain in domains().sorted(by: { $0.modified > $1.modified }) {
            for (key, spec) in Self.shared {
                guard let value = PreferenceValue(domain.values[key], as: spec.kind), spec.valid(value) else { continue }
                file.adopt(key, value, at: domain.modified, by: machine)
            }
        }
    }

    private func applyStored() {
        for (key, spec) in Self.shared {
            let current = PreferenceValue(defaults.object(forKey: key), as: spec.kind)
            guard let raw = file.entry(key)?.value, let value = PreferenceValue(raw, as: spec.kind), spec.valid(value) else {
                lastKnown[key] = current
                continue
            }
            lastKnown[key] = value
            guard value != current else { continue }
            if (current ?? spec.fallback) != value { pending.insert(key) }
            defaults.set(value.raw, forKey: key)
        }
        savePending()
        if effectsAllowed, !pending.isEmpty { effectRun = Task { await runEffects() } }
    }

    private func savePending() {
        let saved = Set(defaults.stringArray(forKey: Self.pendingKey) ?? [])
        guard saved != pending else { return }
        if pending.isEmpty { defaults.removeObject(forKey: Self.pendingKey) } else { defaults.set(pending.sorted(), forKey: Self.pendingKey) }
    }

    func start() {
        guard !frozen else { return }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noticeChanges() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        })
        syncChanged()
    }

    func stop() {
        stopped = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        watcher = nil
        saving?.cancel()
        syncing?.cancel()
    }

    /// Sync was turned on or off, or the app started.
    func syncChanged() {
        guard !frozen, !stopped else { return }
        guard let folder = syncFolder() else { watcher = nil; return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        watcher = FolderWatcher(folders: [folder], latency: 1) { [weak self] _ in self?.scheduleSync() }
        scheduleSync()
    }

    private func scheduleSync() {
        syncing?.cancel()
        syncing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync() async {
        guard !frozen, !stopped, let folder = syncFolder() else { return }
        let own = machineID().map { $0 + ".json" }
        let found = await Task.detached(priority: .utility) { Self.read(folder) }.value
        guard !stopped else { return }
        if let own, let data = found.first(where: { $0.name == own })?.data { exported = data }
        receive(found.map(\.data))
        export()
    }

    private nonisolated static func read(_ folder: URL) -> [FoundFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= largestFile,
                  let data = try? Data(contentsOf: url) else { return nil }
            return FoundFile(name: name, data: data)
        }
    }

    private struct FoundFile: Sendable {
        let name: String
        let data: Data
    }

    /// Files from other Macs are untrusted: a broken one is skipped, and a value only reaches a setting
    /// when its key is shared and its type and range fit.
    func receive(_ files: [Data]) {
        guard !frozen, !stopped else { return }
        let before = file.encoded()
        for data in files {
            if case .file(let theirs) = SharedPreferences.decode(data) { file.merge(theirs) }
        }
        guard file.encoded() != before else { return }
        applyStored()
        flush()
    }

    /// A setting changed here. Values this mirror applied itself match `lastKnown`, so they are not changes.
    func noticeChanges() {
        guard !frozen, !stopped else { return }
        let machine = machineID()
        var changed = false
        for (key, spec) in Self.shared {
            let value = PreferenceValue(defaults.object(forKey: key), as: spec.kind)
            guard value != lastKnown[key] else { continue }
            lastKnown[key] = value
            if let value { file.stamp(key, value, by: machine); changed = true }
        }
        guard changed else { return }
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        guard !frozen, !stopped else { return }
        writeLocal()
        if !frozen { export() }
    }

    private func writeLocal() {
        let disk = try? Data(contentsOf: fileURL)
        if let disk {
            switch SharedPreferences.decode(disk) {
            case .file(let stored): file.merge(stored); file.keepUnknownFields(of: stored)
            case .newer: frozen = true; return
            case .corrupt: break
            }
        }
        let data = file.encoded()
        if data != disk { try? PrivateFile.write(data: data, to: fileURL) }
    }

    /// Only shared keys go to iCloud Drive, in this Mac's own file. Nothing is rewritten unless it changed.
    private func export() {
        guard let folder = syncFolder(), let machine = machineID() else { return }
        let data = file.exported(Self.shared.keys).encoded()
        guard data != exported else { return }
        if (try? PrivateFile.write(data: data, to: folder.appendingPathComponent(machine + ".json"))) != nil { exported = data }
    }

    /// Everything a change needs is ready: the bridge has run once and Remote knows its phones.
    func effectsReady() async {
        effectsAllowed = true
        await runEffects()
    }

    private func runEffects() async {
        guard effectsAllowed, !runningEffects, !stopped else { return }
        runningEffects = true
        defer { runningEffects = false }
        while !pending.isEmpty {
            let batch = pending
            pending = []
            await effects(batch)
        }
        savePending()
    }

    /// Remove Side A. This Mac's file leaves iCloud Drive with it; other Macs keep their own.
    func deleteFiles() {
        let folder = syncFolder(), machine = machineID()
        stop()
        try? FileManager.default.removeItem(at: fileURL)
        if let folder, let machine { try? FileManager.default.removeItem(at: folder.appendingPathComponent(machine + ".json")) }
        defaults.removeObject(forKey: Self.pendingKey)
    }

    /// What Dynamic Island's toggle would do. Remote keeps the hooks when the notch goes; turning on leaves Codex's as it is.
    static func islandChange(on: Bool, claudeInstalled: Bool, remoteActive: Bool) -> (agent: IslandAgent?, state: String)? {
        if on { return claudeInstalled ? nil : (.claude, "on") }
        return remoteActive ? nil : (nil, "off")
    }

    /// Read-only, through this copy's own defaults. Side A isn't sandboxed, so each copy can see the other's.
    nonisolated static func installedDomains() -> [Domain] {
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        var ids = [AppCopies.releaseID, AppCopies.releaseID + ".dev"]
        if let own = Bundle.main.bundleIdentifier, !ids.contains(own) { ids.append(own) }
        return ids.compactMap { id in
            guard let values = UserDefaults.standard.persistentDomain(forName: id) else { return nil }
            let date = (try? FileManager.default.attributesOfItem(atPath: preferences.appendingPathComponent(id + ".plist").path))?[.modificationDate] as? Date
            return Domain(values: values, modified: date?.timeIntervalSince1970 ?? 1)
        }
    }
}
