import Foundation

public enum Pool {
    /// Prompt caches belong to one account, so a conversation stays on its account this long after its last request.
    public static let affinity = 3600.0

    public static func session(headers: HTTPHeaders, body: Data) -> String? {
        if let id = headers["X-Claude-Code-Session-Id"], !id.isEmpty { return id }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let user = (json["metadata"] as? [String: Any])?["user_id"] as? String,
              let range = user.range(of: #"session_[0-9A-Za-z-]+"#, options: .regularExpression) else { return nil }
        return String(user[range].dropFirst("session_".count))
    }

    public static func limits(_ headers: HTTPHeaders) -> [UsageWindow] {
        [("5h", "five_hour", "5-hour"), ("7d", "seven_day", "Weekly")].compactMap { key, id, label in
            guard let raw = headers["anthropic-ratelimit-unified-\(key)-utilization"], let fraction = Double(raw) else { return nil }
            let reset = headers["anthropic-ratelimit-unified-\(key)-reset"].flatMap(Double.init)
            return UsageWindow(id: id, label: label, percent: fraction * 100, resetsAt: reset)
        }
    }

    /// Where a request goes: only ever the API host, and only its /v1 routes (Codex's: its /codex routes under
    /// the ChatGPT backend's path). A target such as `//elsewhere.example/x` is a network-path reference that
    /// would carry an account's token off-host.
    public static func upstream(_ target: String, base: URL, prefix: String = "/v1/") -> URL? {
        guard target.hasPrefix(prefix), !target.contains("#"), !target.contains("\\"),
              var components = URLComponents(string: target), components.scheme == nil, components.host == nil,
              !components.percentEncodedPath.split(separator: "/").contains(where: { [".", ".."].contains($0.removingPercentEncoding ?? ".") }),
              let host = base.host else { return nil }
        let root = base.path == "/" ? "" : base.path
        components.scheme = base.scheme
        components.host = host
        components.port = base.port
        components.percentEncodedPath = root + components.percentEncodedPath
        guard let url = components.url, url.host == host, url.path.hasPrefix(root + prefix) else { return nil }
        return url
    }

    /// Claude Code says who it is; anything else that found the key (an SDK script reading the same
    /// variables) is refused, since a subscription is only for Claude Code.
    public static func fromClaudeCode(_ headers: HTTPHeaders) -> Bool {
        headers["User-Agent"]?.lowercased().hasPrefix("claude-cli/") == true
    }

    /// Claude Code caches a subscriber's prompt for an hour but an API-key caller's for five minutes, and
    /// behind the pool it is the latter: a pause over five minutes writes the whole history to cache again.
    /// Its own breakpoints are made hour-long, byte for byte otherwise; text inside messages is escaped, so never matches.
    public static func hourLongCache(_ body: Data) -> Data {
        let plain = Data(#""cache_control":{"type":"ephemeral"}"#.utf8)
        let long = Data(#""cache_control":{"type":"ephemeral","ttl":"1h"}"#.utf8)
        guard body.firstRange(of: plain) != nil else { return body }
        var out = Data(capacity: body.count + 512)
        var rest = body[...]
        while let range = rest.firstRange(of: plain) {
            out += rest[..<range.lowerBound]
            out += long
            rest = rest[range.upperBound...]
        }
        out += rest
        return out
    }

    /// Codex names itself in `originator` (codex_cli_rs, codex_exec, an IDE's codex_vscode).
    public static func fromCodex(_ headers: HTTPHeaders) -> Bool {
        headers["originator"]?.lowercased().hasPrefix("codex") == true
    }

    public static func codexSession(_ headers: HTTPHeaders) -> String? {
        ["session-id", "session_id", "thread-id", "conversation_id"].lazy.compactMap { headers[$0] }.first { !$0.isEmpty }
    }

    /// Codex's limits, as the ChatGPT backend reports them on every reply: a primary and an optional secondary
    /// window, each with its length in minutes, which says whether it is the 5-hour or the weekly one.
    public static func codexLimits(_ headers: HTTPHeaders) -> [UsageWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let used = headers["x-codex-\(key)-used-percent"].flatMap(Double.init),
                  let minutes = headers["x-codex-\(key)-window-minutes"].flatMap(Int.init) else { return nil }
            return UsageWindow.codex(key: key, minutes: minutes, percent: used, resetsAt: headers["x-codex-\(key)-reset-at"].flatMap(Double.init))
        }
    }

    public static func codexRetryAt(_ headers: HTTPHeaders, now: Double) -> Double {
        let full = ["primary", "secondary"].compactMap { key -> Double? in
            guard (headers["x-codex-\(key)-used-percent"].flatMap(Double.init) ?? 0) >= 100 else { return nil }
            return headers["x-codex-\(key)-reset-at"].flatMap(Double.init)
        }.max()
        let reset = full ?? headers["retry-after"].flatMap(Double.init).map { now + $0 }
        return max(reset ?? now + 900, now + 60)
    }

    /// What Tailscale calls every tagged node's owner: the same "user" for all of them, so it proves nothing.
    public static func sharedIdentity(_ login: String) -> Bool { login.isEmpty || login.caseInsensitiveCompare("tagged-devices") == .orderedSame }

    /// Whether a peer is this Mac's own user. A shared identity never counts.
    public static func admits(peer: String?, login: String) -> Bool {
        guard let peer, !sharedIdentity(peer), !sharedIdentity(login) else { return false }
        return peer.caseInsensitiveCompare(login) == .orderedSame
    }

    public static func whoisLogin(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["UserProfile"] as? [String: Any])?["LoginName"] as? String
    }

    /// What another Mac runs to use this one's pool.
    public static func joinCommand(address: String, port: UInt16, key: String) -> String {
        "sidea pool join http://\(address.contains(":") ? "[\(address)]" : address):\(port) \(key)"
    }

    public static func retryAt(_ headers: HTTPHeaders, now: Double) -> Double {
        let reset = headers["anthropic-ratelimit-unified-reset"].flatMap(Double.init)
            ?? headers["retry-after"].flatMap(Double.init).map { now + $0 }
        return max(reset ?? now + 900, now + 60)
    }
}

/// What is left across a pool's accounts, each weighted by its plan size, so a Max 20x account counts as
/// twenty Pro ones. A window not started yet counts as all left.
public struct PoolRoom: Equatable, Sendable {
    public var accounts: Int
    /// Nil when no account has a 5-hour limit, as with verified Ultra accounts.
    public var fiveHourLeft: Double?
    public var weeklyLeft: Double
    /// Accounts out of room now.
    public var limited: Int
    /// When the first of those gets room back, and which one.
    public var refill: (name: String, at: Double)?

    public init?(_ members: [Account], usage: [String: AccountUsage], full: Double, now: Double) {
        let read = members.compactMap { account in usage[account.id].map { (account, $0) } }
        guard !read.isEmpty else { return nil }
        let size = { (value: AccountUsage) in max(value.capacity ?? 1, 0.01) }
        let total = read.reduce(0) { $0 + size($1.1) }
        let left = { (window: (AccountUsage) -> UsageWindow?) in
            read.reduce(0) { sum, item in sum + size(item.1) * (100 - min(max(Planner.live(window(item.1), now)?.percent ?? 0, 0), 100)) } / total
        }
        accounts = read.count
        fiveHourLeft = read.contains { $0.1.fiveHour != nil } ? left(\.fiveHour) : nil
        weeklyLeft = left(\.weekly)
        limited = read.filter { !Planner.hasHeadroom($0.1, full: full, now: now) }.count
        refill = Planner.nextAvailable(read.map(\.0), usage: usage, full: full, now: now).map { ($0.0.name, $0.1) }
    }

    public static func == (a: PoolRoom, b: PoolRoom) -> Bool {
        a.accounts == b.accounts && a.fiveHourLeft == b.fiveHourLeft && a.weeklyLeft == b.weeklyLeft && a.limited == b.limited
            && a.refill?.name == b.refill?.name && a.refill?.at == b.refill?.at
    }
}

/// The pool's last answer and last refusal for one service.
public struct PoolActivity: Equatable, Sendable {
    public var served = 0
    public var servedAt: Double?
    public var servedBy: String?
    public var failedAt: Double?
    public var failure: String?
    public init() {}

    /// A refusal newer than the last answer is what the pool is doing now.
    public var failing: Bool { (failedAt ?? 0) > (servedAt ?? 0) }
}

public struct PoolRouter: Sendable {
    private var sticky: [String: (account: String, at: Double)] = [:]

    public init() {}

    public mutating func route(session: String?, now: Double, usable: (String) -> Bool, pick: () -> String?) -> String? {
        sticky = sticky.filter { now - $0.value.at < Pool.affinity }
        if let session, let held = sticky[session], usable(held.account) {
            sticky[session] = (held.account, now)
            return held.account
        }
        guard let chosen = pick() else { return nil }
        if let session { sticky[session] = (chosen, now) }
        return chosen
    }

    public func account(for session: String) -> String? { sticky[session]?.account }

    public var conversations: [String: Int] {
        sticky.values.reduce(into: [:]) { $0[$1.account, default: 0] += 1 }
    }
}
