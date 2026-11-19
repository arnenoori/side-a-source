import Foundation

/// Conversations a limit stopped mid-turn, until each has been asked to carry on.
public struct StoppedSessions: Codable, Equatable, Sendable {
    public static let prompt = "Please continue"
    /// The longest a limit lasts. A stop older than that has nothing left to wait for.
    public static let forget = 7 * 86_400.0
    /// A login trade reaches running sessions within a minute.
    public static let settle = 90.0
    /// How long a session that stopped again waits before it is asked again, how often it is asked at most, and
    /// how long after its last ask that count starts over.
    public static let again = 900.0
    public static let attempts = 3
    public static let rest = 6 * 3600.0
    /// A response cut off by sleep or the network can be tried again a minute on, and is the user's after half a day.
    public static let retry = 60.0
    public static let interrupted = 12 * 3600.0

    public struct Refusal: Codable, Equatable, Sendable {
        public let provider: AgentProvider
        public let at: Double
        public init(provider: AgentProvider, at: Double) { self.provider = provider; self.at = at }
    }
    private struct Ask: Codable, Equatable, Sendable {
        var at: Double
        var times: Int
    }

    /// Refused by the pool with every account out: waits for one with room.
    private var refused: [String: Refusal] = [:]
    /// Stopped on a limit when Autopilot traded their login: waits for the trade to reach them.
    private var moved: [String: Double] = [:]
    private var asked: [String: Ask] = [:]

    public init() {}

    public var isEmpty: Bool { refused.isEmpty && moved.isEmpty }

    public mutating func refuse(_ session: String, _ provider: AgentProvider, at: Double) {
        refused[session] = Refusal(provider: provider, at: at)
    }

    /// The pool found the conversation an account, so it went on by itself or the user sent it on.
    public mutating func served(_ session: String) {
        refused[session] = nil
    }

    public mutating func move(_ sessions: [String], at: Double) {
        for session in sessions { moved[session] = at }
    }

    /// The message reached the session, so its stop is settled; one it didn't reach is tried again.
    public mutating func delivered(_ session: String) {
        refused[session] = nil
        moved[session] = nil
    }

    /// The sessions to ask now, each counted as asked. `idle` are the running conversations with nothing under way,
    /// `working` those mid-turn, and `lifted` those whose last reply is an error they can get past now, by when
    /// they stopped.
    public mutating func due(now: Double, idle: Set<String>, working: Set<String> = [], lifted: [String: Double] = [:],
                             room: (AgentProvider) -> Bool) -> [String] {
        refused = refused.filter { now - $0.value.at < Self.forget }
        // A traded session mid-turn was sent on by the user.
        moved = moved.filter { now - $0.value < Self.forget && !working.contains($0.key) }
        asked = asked.filter { now - $0.value.at < Self.rest }
        var due = Set(refused.filter { room($0.value.provider) }.keys)
        due.formUnion(moved.filter { now - $0.value >= Self.settle }.keys)
        due.formUnion(lifted.filter { now - $0.value < Self.forget }.keys)
        due.formIntersection(idle)
        due = due.filter { session in
            guard let last = asked[session] else { return true }
            return last.times < Self.attempts && now - last.at >= Self.again
        }
        for session in due {
            asked[session] = Ask(at: now, times: (asked[session]?.times ?? 0) + 1)
        }
        return due.sorted()
    }
}

/// `runtime/pool-stopped.json`: the conversations the helper refused while the app was closed, for the app to ask
/// once it runs again. The helper rewrites it whole; the app takes it and removes it.
public struct HelperRefusals: Sendable {
    public let url: URL
    public init(root: URL) { url = root.appendingPathComponent("runtime/pool-stopped.json") }

    public func read() -> [String: StoppedSessions.Refusal] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: StoppedSessions.Refusal].self, from: data)) ?? [:]
    }

    public func refuse(_ session: String, _ provider: AgentProvider, at: Double) throws {
        var all = read().filter { at - $0.value.at < StoppedSessions.forget }
        all[session] = StoppedSessions.Refusal(provider: provider, at: at)
        try PrivateFile.write(all, to: url)
    }

    public func served(_ session: String) throws {
        // Nearly every request: nothing was refused, so there is no file to read.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var all = read()
        guard all.removeValue(forKey: session) != nil else { return }
        try PrivateFile.write(all, to: url)
    }

    /// Everything the helper left, which is then the caller's.
    public func take() -> [String: StoppedSessions.Refusal] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let all = read()
        try? FileManager.default.removeItem(at: url)
        return all
    }
}
