import AppKit
import SideACore
import UserNotifications

/// Reads Claude Code's registry directly, so nothing runs in Python while Side A's windows are closed.
@MainActor
final class WaitingNotifier {
    static let enabledKey = "notifyWaiting"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private let store: AccountStore
    private var watcher: FolderWatcher?
    private var waiting: Set<String> = []
    private var pending: Task<Void, Never>?
    private var sweep: Task<Void, Never>?
    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")

    init(store: AccountStore) { self.store = store }

    func update() {
        // Remote needs `sync` too, or a request answered in the terminal would stay open on the phone.
        guard Self.enabled || Island.on || RemoteController.active, Bundle.main.bundleURL.pathExtension == "app" else {
            watcher = nil
            sweep?.cancel(); sweep = nil
            return
        }
        guard watcher == nil else { return }
        waiting = Set(scan(read()).map(\.id))
        watcher = FolderWatcher(folders: [folder]) { [weak self] _ in self?.changed() }
        // A session that crashed leaves its registry file behind, so what the island holds is checked now and then too.
        sweep = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if self.store.island.holdsSessions { self.changed(after: .zero) }
            }
        }
    }

    private func changed(after delay: Duration = .milliseconds(200)) {
        pending?.cancel()
        // A status flip rewrites the file more than once; read it after the writes settle.
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let entries = self.read()
            let now = self.scan(entries)
            let sessions = entries.map { entry in
                IslandSession(pid: entry.pid, sessionID: entry.sessionId, status: entry.status ?? "idle",
                              since: Date(timeIntervalSince1970: (entry.statusUpdatedAt ?? 0) / 1000))
            }
            if self.store.island.sync(sessions) {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(IslandSession.settle))
                    self?.changed(after: .zero)
                }
            }
            for session in now where !self.waiting.contains(session.id) { self.post(session) }
            let moved = self.waiting.subtracting(now.map(\.id))
            if Self.enabled, !moved.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: moved.map { "waiting-" + $0 })
            }
            self.waiting = Set(now.map(\.id))
        }
    }

    private struct Entry: Decodable {
        let pid: Int
        let sessionId: String?
        let cwd: String?
        let status: String?
        let statusUpdatedAt: Double?
        let waitingFor: String?
        let name: String?
        let nameSource: String?
    }

    private struct Waiting {
        let id: String
        let pid: Int
        let cwd: String?
        let reason: String?
        let name: String?
    }

    private func read() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        }
    }

    private func scan(_ entries: [Entry]) -> [Waiting] {
        entries.compactMap { entry in
            guard entry.status == "waiting", let id = entry.sessionId, kill(pid_t(entry.pid), 0) == 0,
                  entry.cwd != store.root.path else { return nil }
            return Waiting(id: id, pid: entry.pid, cwd: entry.cwd, reason: entry.waitingFor, name: entry.nameSource == "user" ? entry.name : nil)
        }
    }

    private func post(_ session: Waiting) {
        if NSApp.isActive && store.sessionsOpen { return }
        let folder = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let title = store.sessions.title(of: session.id) ?? session.name ?? folder ?? "Claude Code"
        let body = session.reason.map { "Waiting for \($0)" } ?? "Waiting for you"
        // A permission request already open in the island needs no second alert.
        if store.island.pending.contains(where: { $0.request.sessionID == session.id }) { return }
        store.island.show(.waiting, title, body, pid: session.pid, cwd: session.cwd)
        guard Self.enabled else { return }
        Self.deliver(id: session.id, title: title, subtitle: title == folder ? nil : folder, body: body)
    }

    private nonisolated static func deliver(id: String, title: String, subtitle: String?, body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle { content.subtitle = subtitle }
            content.body = body
            content.userInfo = ["session": id]
            content.threadIdentifier = "waiting"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "waiting-" + id, content: content, trigger: nil))
        }
    }

    static let requestPrefix = "request-"

    /// A permission request answerable from the notification. Destructive ones, questions and plans only open
    /// Sessions: they need a click there, or more than yes or no.
    static func deliver(_ item: Island.Pending) {
        let request = item.request
        let simple: Bool
        switch request.action {
        case .question, .plan: simple = false
        default: simple = request.risk != .destructive
        }
        let id = item.id.uuidString
        let title = item.title
        let subtitle = "\(request.agent.title) asks to \(request.headline.prefix(1).lowercased() + request.headline.dropFirst())"
        let body = String(request.detail.prefix(240))
        let session = request.sessionID
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            content.categoryIdentifier = simple ? NotificationRouter.answerable : NotificationRouter.openOnly
            content.userInfo = ["request": id, "session": session ?? ""]
            content.threadIdentifier = "requests"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: requestPrefix + id, content: content, trigger: nil))
        }
    }

    nonisolated static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private weak var store: AccountStore?

    static let answerable = "answerable-request"
    static let openOnly = "open-request"

    @MainActor init(store: AccountStore) {
        self.store = store
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: "allow", title: "Allow")
        let deny = UNNotificationAction(identifier: "deny", title: "Deny")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.answerable, actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.openOnly, actions: [], intentIdentifiers: []),
        ])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        if let request = (info["request"] as? String).flatMap(UUID.init(uuidString:)), action == "allow" || action == "deny" {
            await MainActor.run {
                // Answered elsewhere meanwhile: the island ignores ids it no longer holds.
                store?.island.answer(action == "allow" ? .allow : .deny(nil), request, by: .notification)
            }
            return
        }
        guard let id = info["session"] as? String, !id.isEmpty else { return }
        await MainActor.run {
            guard let store else { return }
            store.openSessions(id)
        }
    }
}
