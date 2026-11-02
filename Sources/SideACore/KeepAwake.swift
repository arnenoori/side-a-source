import Darwin
import Foundation

public struct KeepAwake: Equatable, Sendable {
    public struct Settings: Equatable, Sendable {
        public var enabled: Bool
        public var lidClosed: Bool
        public var onBattery: Bool
        public init(enabled: Bool, lidClosed: Bool = false, onBattery: Bool = false) {
            self.enabled = enabled; self.lidClosed = lidClosed; self.onBattery = onBattery
        }
    }

    public struct Power: Equatable, Sendable {
        public var onAC: Bool
        public var battery: Int?
        public init(onAC: Bool, battery: Int?) { self.onAC = onAC; self.battery = battery }
    }

    public static let grace: TimeInterval = 120
    public static let lowBattery = 20

    public private(set) var working = 0
    public private(set) var lastWorking: Double?

    public init() {}

    public mutating func observe(working: Int, now: Double) {
        self.working = max(working, 0)
        if self.working > 0 { lastWorking = now }
    }

    public func inGrace(now: Double) -> Bool {
        working == 0 && lastWorking.map { now - $0 < Self.grace } == true
    }

    public func holdsAssertion(_ settings: Settings, now: Double) -> Bool {
        settings.enabled && (working > 0 || inGrace(now: now))
    }

    /// A low battery always wins: a closed MacBook that never sleeps would run flat in a bag.
    public func disablesSleep(_ settings: Settings, power: Power, now: Double) -> Bool {
        guard settings.lidClosed, holdsAssertion(settings, now: now) else { return false }
        if power.onAC { return true }
        guard settings.onBattery, let battery = power.battery else { return false }
        return battery >= Self.lowBattery
    }

    public var reason: String {
        working > 0 ? "Side A: \(Self.agents(working)) working" : "Side A: agents paused"
    }

    public func line(_ settings: Settings, sleepDisabled: Bool, now: Double) -> String? {
        guard holdsAssertion(settings, now: now) else { return nil }
        let base = working > 0 ? "Keeping awake · \(Self.agents(working)) working" : "Keeping awake · agents paused"
        return sleepDisabled ? base + " · lid closed OK" : base
    }

    public func accessibilityLine(_ settings: Settings, sleepDisabled: Bool, now: Double) -> String? {
        guard holdsAssertion(settings, now: now) else { return nil }
        let base = working > 0 ? "Keeping the Mac awake while \(Self.agents(working)) work" : "Keeping the Mac awake for a short pause between agent steps"
        return sleepDisabled ? base + ", also with the lid closed" : base
    }

    static func agents(_ count: Int) -> String { count == 1 ? "1 agent" : "\(count) agents" }
}

public enum AgentActivity {
    /// A busy session whose transcripts haven't moved in this long is stuck. One long Bash command writes nothing until it ends.
    public static let staleAfter: TimeInterval = 10_800
    /// Codex marks no status; a rollout written this recently is a turn in progress.
    public static let codexRecent: TimeInterval = 90
    /// Codex keeps writing to the dated folder of the day a session started.
    public static let codexDays = 14

    private struct Entry: Decodable {
        let pid: Int
        let sessionId: String?
        let cwd: String?
        let status: String?
    }

    public static func claudeWorking(registry: URL, projects: URL, excluding root: String?, now: Date,
                                     alive: (Int) -> Bool = isAlive) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? []
        var count = 0
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.status == "busy" || entry.status == "shell", entry.pid > 1, entry.cwd != root, alive(entry.pid) else { continue }
            // "shell": the turn ended but a background Bash job still runs, and that job writes no transcript.
            if entry.status == "busy", let id = entry.sessionId,
               let transcript = transcript(projects: projects, cwd: entry.cwd, id: id), let written = lastWrite(transcript),
               now.timeIntervalSince(written) > staleAfter {
                continue
            }
            count += 1
        }
        return count
    }

    /// Claude Code shortens long project folder names with a hash, so a miss falls back to the session id, which is unique.
    public static func transcript(projects: URL, cwd: String?, id: String) -> URL? {
        let files = FileManager.default
        if let cwd {
            let url = projects.appendingPathComponent(projectFolder(cwd)).appendingPathComponent(id + ".jsonl")
            if files.fileExists(atPath: url.path) { return url }
        }
        let folders = (try? files.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appendingPathComponent(id + ".jsonl") }.first { files.fileExists(atPath: $0.path) }
    }

    /// Subagents write to their own transcripts while the main one waits on them.
    public static func lastWrite(_ transcript: URL) -> Date? {
        let subagents = transcript.deletingPathExtension().appendingPathComponent("subagents")
        let files = (try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return ([transcript] + files.filter { $0.pathExtension == "jsonl" }).compactMap(modified).max()
    }

    public static func codexWorking(sessions: URL, now: Date, calendar: Calendar = .current) -> Int {
        let days = (0..<codexDays).compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }.map { date in
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
        }
        return Set(days).reduce(0) { count, folder in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return count + files.filter { file in
                file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl"
                    && modified(file).map { now.timeIntervalSince($0) < codexRecent } == true
            }.count
        }
    }

    public static func projectFolder(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// EPERM still means the process exists.
    public static func isAlive(_ pid: Int) -> Bool {
        guard pid > 1, pid <= Int(Int32.max) else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// A closed MacBook whose sleep comes back on stays awake until the lid opens and closes again.
public enum ClosedLid {
    public static let settle: TimeInterval = 30

    /// Wall time running ahead of awake time means the Mac already slept in between.
    public static func sleepNow(lidClosed: Bool, externalDisplay: Bool, elapsed: TimeInterval, awake: TimeInterval) -> Bool {
        lidClosed && !externalDisplay && awake >= settle - 1 && elapsed - awake < 5
    }
}
