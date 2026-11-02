import Foundation

/// Anthropic API list prices in dollars per million tokens, to show what the tokens a subscription
/// covered would have cost on the API. Prompt caching: writes are the 5-minute rate.
public struct APIPrice: Equatable, Sendable {
    public let input, output, cacheWrite, cacheRead: Double

    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }

    /// Prices from the public list the app fetches (LiteLLM's, which ccusage reads too), by model id.
    /// Anthropic publishes prices only on its website, not through an API.
    nonisolated(unsafe) public static var published: [String: APIPrice] = [:]

    /// LiteLLM's model_prices_and_context_window.json: dollars per token for each model id.
    public static func parsePublished(_ data: Data) -> [String: APIPrice] {
        guard let table = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var prices: [String: APIPrice] = [:]
        for (id, value) in table where id.hasPrefix("claude-") && !id.contains("/") {
            guard let row = value as? [String: Any], let input = row["input_cost_per_token"] as? Double,
                  let output = row["output_cost_per_token"] as? Double else { continue }
            let write = row["cache_creation_input_token_cost"] as? Double ?? input * 1.25
            let read = row["cache_read_input_token_cost"] as? Double ?? input * 0.1
            prices[id.lowercased()] = APIPrice(input: input * 1e6, output: output * 1e6, cacheWrite: write * 1e6, cacheRead: read * 1e6)
        }
        return prices
    }

    /// "claude-opus-4-5-20251101" and "claude-opus-5-5[1m]" are priced as "claude-opus-4-5" and "claude-opus-5-5".
    static func base(_ model: String) -> String {
        var id = model.lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        return id.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }

    /// A Claude model id's prices: the published list first, else Side A's own table (October 2026); nil for Codex
    /// and models neither knows.
    public static func of(_ model: String?, in list: [String: APIPrice] = published) -> APIPrice? {
        if let model, let price = list[model.lowercased()] ?? list[base(model)] { return price }
        let id = base(model ?? "")
        let version = id.split(separator: "-").compactMap { Int($0) }.filter { $0 < 100 }.prefix(2).map(String.init).joined(separator: ".")
        let major = Double(version) ?? 0
        if id.contains("fable") { return APIPrice(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 0.25) }
        if id.contains("opus") {
            if version == "5.5" { return APIPrice(input: 4, output: 20, cacheWrite: 5, cacheRead: 0.2) }
            return major >= 4.5 ? APIPrice(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5) : APIPrice(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)
        }
        if id.contains("sonnet") {
            return version == "5.5" ? APIPrice(input: 2, output: 10, cacheWrite: 2.5, cacheRead: 0.1) : APIPrice(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)
        }
        if id.contains("haiku") {
            // Haiku 5.5's rate for prompts up to 100k tokens; longer prompts cost more.
            if version == "5.5" { return APIPrice(input: 0.1, output: 0.5, cacheWrite: 0.125, cacheRead: 0.01) }
            return major >= 4.5 ? APIPrice(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1) : APIPrice(input: 0.8, output: 4, cacheWrite: 1, cacheRead: 0.08)
        }
        return nil
    }

    public func dollars(_ row: TokenRow) -> Double {
        (Double(row.input) * input + Double(row.output) * output + Double(row.cacheWrite) * cacheWrite + Double(row.cacheRead) * cacheRead) / 1_000_000
    }

    /// The API value of rows that each name a model; rows of unknown models count nothing.
    public static func dollars(_ rows: [TokenRow]) -> Double {
        rows.reduce(0) { $0 + (of($1.model)?.dollars($1) ?? 0) }
    }
}

/// An incident on status.claude.com that affects Claude Code or the API it runs on.
public struct Outage: Equatable, Sendable {
    public let id: String
    public let name: String
    public let major: Bool
    /// Statuspage's own word for an incident ("investigating", "identified", "monitoring"); nil for a degraded component.
    public var status: String? = nil
    public var startedAt: Double? = nil
    public var url: String? = nil

    public init(id: String, name: String, major: Bool, status: String? = nil, startedAt: Double? = nil, url: String? = nil) {
        self.id = id; self.name = name; self.major = major; self.status = status; self.startedAt = startedAt; self.url = url
    }

    /// Statuspage's ISO 8601 times, with or without milliseconds.
    static func date(_ text: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Reads Statuspage's summary.json; other products' incidents (the Console, claude.ai alone) don't count.
    public static func parse(_ data: Data) -> Outage? {
        struct Component: Decodable { let name: String; let status: String? }
        struct Update: Decodable { let affected_components: [Component]? }
        struct Incident: Decodable {
            let id: String; let name: String; let status: String; let impact: String?; let components: [Component]?; let incident_updates: [Update]?
            let created_at: String?; let shortlink: String?
            /// The incident's components and those its updates name.
            var affected: [Component] { (components ?? []) + (incident_updates ?? []).flatMap { $0.affected_components ?? [] } }
        }
        struct Summary: Decodable { let components: [Component]?; let incidents: [Incident]? }
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return nil }
        let relevant = { (name: String) in name.localizedCaseInsensitiveContains("Claude Code") || name.localizedCaseInsensitiveContains("API") }
        if let incident = (summary.incidents ?? []).first(where: { incident in
            !["resolved", "postmortem", "completed"].contains(incident.status) && incident.affected.contains { relevant($0.name) }
        }) {
            let started = incident.created_at.flatMap(Self.date)?.timeIntervalSince1970
            return Outage(id: incident.id, name: incident.name, major: ["major", "critical"].contains(incident.impact ?? ""),
                          status: incident.status, startedAt: started, url: incident.shortlink)
        }
        if let component = (summary.components ?? []).first(where: { relevant($0.name) && ($0.status ?? "operational") != "operational" }) {
            let status = (component.status ?? "").replacingOccurrences(of: "_", with: " ")
            return Outage(id: "\(component.name)|\(status)", name: "\(component.name): \(status)", major: status.contains("outage"))
        }
        return nil
    }
}
