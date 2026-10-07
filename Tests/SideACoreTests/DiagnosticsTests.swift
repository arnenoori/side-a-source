import Foundation
import Testing
@testable import SideACore

@Test func diagnosticExportExcludesRawInputsAndIdentifyingFields() throws {
    let canary = "private-token@example.com"
    let dependency = Dependency(name: canary, path: "/Users/\(canary)/project", version: "CLI 1.2.3 \(canary)", state: .ready)
    let summary = DiagnosticSummary(appVersion: "0.4.1 \(canary)", macOSVersion: "26.0 \(canary)",
        architecture: canary, python: dependency, claude: dependency,
        codex: Dependency(name: canary, path: canary, version: canary, state: .missing),
        libraryReadable: false)
    let data = try JSONEncoder().encode(summary)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == Set(["schemaVersion", "appVersion", "macOSVersion", "architecture", "python", "claude", "codex", "libraryReadable"]))
    let tool = try #require(object["claude"] as? [String: Any])
    #expect(Set(tool.keys) == Set(["state", "version"]))
    #expect(tool["version"] as? String == "1.2.3")
    #expect(object["architecture"] as? String == "unknown")
    #expect(object["libraryReadable"] as? Bool == false)
    #expect(!String(decoding: data, as: UTF8.self).contains(canary))
}

@Test func telemetryPayloadContainsOnlyDeclaredNonIdentifyingProperties() throws {
    let payload = MetricEnvelope(token: "public-ingestion", visit: UUID(), event: .handoffReady, version: "0.4.0", provider: .claude)
    let data = try JSONEncoder().encode(payload)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let properties = try #require(object["properties"] as? [String: Any])
    #expect(Set(properties.keys) == Set(["surface", "schema_version", "app_version", "provider", "$process_person_profile", "$is_identified", "$geoip_disable"]))
    #expect(properties["$process_person_profile"] as? Bool == false)
    #expect(properties["$geoip_disable"] as? Bool == true)
    #expect(properties["surface"] as? String == "mac_app")
    #expect(object["event"] as? String == "account_handoff_ready")
}
