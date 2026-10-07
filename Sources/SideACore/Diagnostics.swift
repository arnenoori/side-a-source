import Foundation

public enum DependencyState: String, Sendable { case checking, ready, missing, incompatible }
public struct Dependency: Sendable {
    public let name: String
    public let path: String?
    public let version: String?
    public let state: DependencyState
    public init(name: String, path: String? = nil, version: String? = nil, state: DependencyState = .checking) {
        self.name = name; self.path = path; self.version = version; self.state = state
    }
    public static func version(in output: String) -> String? {
        guard let range = output.range(of: #"\b[0-9]+\.[0-9]+(?:\.[0-9]+)?\b"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }
    public static func supportsPython(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return parts.count >= 2 && (parts[0] > 3 || (parts[0] == 3 && parts[1] >= 9))
    }
}

public enum AppMetric: String, Sendable {
    case launched = "app_launched", accountConnected = "account_connected"
    case handoffReady = "account_handoff_ready"
}

/// A deliberately small export schema. Never serialize configuration or raw runtime data.
public struct DiagnosticSummary: Encodable, Sendable {
    public struct Tool: Encodable, Sendable {
        let state: String
        let version: String?
        public init(_ dependency: Dependency) {
            state = dependency.state.rawValue
            version = dependency.version.flatMap(Dependency.version(in:))
        }
    }
    let schemaVersion = 1
    let appVersion: String?
    let macOSVersion: String?
    let architecture: String
    let python: Tool
    let claude: Tool
    let codex: Tool
    let libraryReadable: Bool
    public init(appVersion: String, macOSVersion: String, architecture: String,
                python: Dependency, claude: Dependency, codex: Dependency,
                libraryReadable: Bool) {
        self.appVersion = Dependency.version(in: appVersion)
        self.macOSVersion = Dependency.version(in: macOSVersion)
        self.architecture = ["arm64", "x86_64"].contains(architecture) ? architecture : "unknown"
        self.python = Tool(python); self.claude = Tool(claude); self.codex = Tool(codex)
        self.libraryReadable = libraryReadable
    }
}

/// Only structured, non-identifying values can cross the telemetry boundary.
public struct MetricEnvelope: Encodable, Sendable {
    public let api_key: String
    public let distinct_id: String
    public let event: String
    public let properties: Properties
    public struct Properties: Encodable, Sendable {
        let surface = "mac_app"
        let schema_version = 1
        let app_version: String
        let provider: String?
        let personProfile = false
        let identified = false
        let geoIP = true
        enum CodingKeys: String, CodingKey {
            case surface, schema_version, app_version, provider
            case personProfile = "$process_person_profile", identified = "$is_identified", geoIP = "$geoip_disable"
        }
    }
    public init(token: String, visit: UUID, event: AppMetric, version: String, provider: AgentProvider? = nil) {
        api_key = token; distinct_id = visit.uuidString; self.event = event.rawValue
        properties = Properties(app_version: version, provider: provider?.rawValue)
    }
}
