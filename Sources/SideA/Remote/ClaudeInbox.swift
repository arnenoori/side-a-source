import Darwin
import Foundation
import Observation
import SideACore
import SideAProtocol

/// Phone messages for Claude sessions started in a terminal (opt-in). The bridge's `inbox on` adds SessionStart and
/// Stop hooks that wait in the background for `runtime/inbox/<pid>.json` and wake the session with it (island_hook's
/// `inbox`). The newest of a session's hooks writes its pid to `<pid>.watcher`; that it's alive, and the session's
/// child, is what makes a session reachable. Claude Code tells the model such text is not user input, so it reaches
/// Claude as a note and never counts as approval.
@MainActor @Observable
final class ClaudeInbox {
    static let pickup: Duration = .seconds(5)

    private(set) var installed = false
    @ObservationIgnored private weak var store: AccountStore?
    /// A message no hook took within `pickup`, by session pid, for the session's flag until one goes through.
    @ObservationIgnored private var unsent: [Int: String] = [:]


    init(store: AccountStore?) { self.store = store }

    private var folder: URL? { store?.root.appendingPathComponent("runtime/inbox") }

    func refresh() async { await run("status") }

    func set(_ on: Bool) async { await run(on ? "on" : "off") }

    private func run(_ state: String) async {
        guard let store, !store.isDemo else { return }
        do {
            let data = try await store.bridgeOutput(["inbox", state])
            installed = (try JSONDecoder().decode([String: Bool].self, from: data))["inbox"] == true
        } catch {
            if state != "status" { store.error = error.localizedDescription }
        }
    }

    #if DEBUG
    /// The harness's inbox rows: these pids count as watched, and a message left for one is taken at once.
    var staged: Set<Int>? { didSet { if staged != nil { installed = true } } }
    #endif

    /// A hook of this session is waiting for a message now.
    func watching(_ live: LiveSession) -> Bool {
        #if DEBUG
        if let staged { return live.provider == .claude && live.hosted == nil && staged.contains(live.pid) }
        #endif
        guard live.provider == .claude, live.hosted == nil, let folder,
              let text = try? String(contentsOf: folder.appendingPathComponent("\(live.pid).watcher"), encoding: .utf8),
              let watcher = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), watcher > 0 else { return false }
        return Self.parent(of: watcher) == pid_t(live.pid)
    }

    /// Leaves the message for the session's hook. Within `pickup` the hook takes it; one still there then is taken
    /// back and flagged on the session, so the phone never believes a message that sat unread.
    func leave(_ text: String, to live: LiveSession) -> Bool {
        #if DEBUG
        if staged != nil { return true }
        #endif
        guard let folder else { return false }
        let id = UUID().uuidString.lowercased()
        let url = folder.appendingPathComponent("\(live.pid).json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: ["text": text, "id": id])
            let staged = folder.appendingPathComponent(".\(live.pid).\(id)")
            guard FileManager.default.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
            guard rename(staged.path, url.path) == 0 else { try? FileManager.default.removeItem(at: staged); return false }
        } catch {
            return false
        }
        let pid = live.pid
        if unsent.removeValue(forKey: pid) != nil { store?.remote.events?.liveChanged() }
        Task { [weak self] in
            try? await Task.sleep(for: Self.pickup)
            guard let self else { return }
            let left = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if left?["id"] as? String == id {
                try? FileManager.default.removeItem(at: url)
                self.unsent[pid] = text
                RemoteLog.shared("inbox: no hook took a message for pid \(pid) within \(Self.pickup)")
                self.store?.remote.events?.liveChanged()
            } else if Island.on {
                self.store?.island.show(.track, "From iPhone", String(text.prefix(120)), pid: pid, cwd: live.cwd)
            }
        }
        return true
    }

    func unsent(_ live: LiveSession) -> String? { unsent[live.pid] }

    /// Drops what's kept for sessions that ended.
    func prune(_ live: [LiveSession]) {
        let pids = Set(live.map(\.pid))
        unsent = unsent.filter { pids.contains($0.key) }
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
