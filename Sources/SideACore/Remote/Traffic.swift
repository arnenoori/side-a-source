import Foundation

/// How many bytes Remote moves and for what: a count per route and per socket kind, drained into the log once a minute,
/// and a total on each connection's close line. Sizes and counts only, never a path with an id in it, a body or a token.
public final class Traffic: @unchecked Sendable {
    public struct Tally: Equatable, Sendable {
        public var requests = 0
        public var received = 0
        public var sent = 0
        public init(requests: Int = 0, received: Int = 0, sent: Int = 0) { self.requests = requests; self.received = received; self.sent = sent }
        var total: Int { received + sent }
    }

    public static let shared = Traffic()

    private let lock = NSLock()
    private var tallies: [String: Tally] = [:]

    public init() {}

    public func add(_ key: String, count: Int = 0, received: Int = 0, sent: Int = 0) {
        lock.withLock {
            guard tallies[key] != nil || tallies.count < 64 else { return }
            var tally = tallies[key] ?? Tally()
            tally.requests += count; tally.received += received; tally.sent += sent
            tallies[key] = tally
        }
    }

    /// What was counted since the last call.
    public func drain() -> [String: Tally] {
        lock.withLock {
            defer { tallies = [:] }
            return tallies
        }
    }

    /// A request's route with every id taken out of it: words stay, anything with a digit, a capital or a length that
    /// only an id has becomes `*`. `GET /v1/sessions/*/transcript`.
    public static func key(method: String, path: [String]) -> String {
        let parts = path.map { part in
            part == "v1" || (part.count <= 24 && part.allSatisfy { $0.isLowercase || $0 == "_" || $0 == "." }) ? part : "*"
        }
        return method + " /" + parts.joined(separator: "/")
    }

    public static func size(_ bytes: Int) -> String {
        switch bytes {
        case ..<1_024: "\(bytes) B"
        case ..<(1 << 20): String(format: "%.1f KB", Double(bytes) / 1_024)
        default: String(format: "%.1f MB", Double(bytes) / Double(1 << 20))
        }
    }

    /// "traffic 60 s: 3.1 MB out, 12.0 KB in; GET /v1/sessions/*/transcript 3 req 3.1 MB out; ws /v1/ws/events 40.2 KB out"; the
    /// heaviest `limit` entries, nil when nothing moved.
    public static func summary(_ tallies: [String: Tally], seconds: Int, limit: Int = 6) -> String? {
        let all = tallies.values.reduce(Tally()) { Tally(requests: $0.requests + $1.requests, received: $0.received + $1.received, sent: $0.sent + $1.sent) }
        guard all.total > 0 else { return nil }
        let heaviest = tallies.sorted { ($0.value.total, $1.key) > ($1.value.total, $0.key) }.prefix(limit)
        let rows = heaviest.map { key, tally in
            "\(key)\(tally.requests > 0 ? " \(tally.requests) req" : "") \(size(tally.sent)) out, \(size(tally.received)) in"
        }
        return "traffic \(seconds) s: \(size(all.sent)) out, \(size(all.received)) in; " + rows.joined(separator: "; ")
    }
}
