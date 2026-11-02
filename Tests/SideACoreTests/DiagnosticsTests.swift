import Foundation
import Testing
@testable import SideACore

@Test func diagnosticExportExcludesRawInputsAndIdentifyingFields() throws {
    let canary = "private-token@example.com"
    let dependency = Dependency(name: canary, path: "/Users/\(canary)/project", version: "CLI 1.2.3 \(canary)", state: .ready)
    let summary = DiagnosticSummary(appVersion: "0.4.1 \(canary)", macOSVersion: "26.0 \(canary)",
        architecture: canary, python: dependency, claude: dependency,
        codex: Dependency(name: canary, path: canary, version: canary, state: .missing),
        libraryReadable: false, inApplications: false, updateError: 4005)
    let data = try JSONEncoder().encode(summary)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == Set(["schemaVersion", "appVersion", "macOSVersion", "architecture", "python", "claude", "codex", "libraryReadable", "inApplications", "updateError"]))
    let tool = try #require(object["claude"] as? [String: Any])
    #expect(Set(tool.keys) == Set(["state", "version"]))
    #expect(tool["version"] as? String == "1.2.3")
    #expect(object["architecture"] as? String == "unknown")
    #expect(object["libraryReadable"] as? Bool == false)
    #expect(!String(decoding: data, as: UTF8.self).contains(canary))
}

@Test func python39RunsTheBridgeButElevenOrLaterIsPreferred() {
    #expect(Dependency.supportsPython("3.9.6") && !Dependency.prefersPython("3.9.6"))
    #expect(Dependency.prefersPython("3.11.0") && Dependency.prefersPython("3.15.0") && Dependency.prefersPython("4.0"))
    #expect(!Dependency.supportsPython("3.8.10") && !Dependency.supportsPython("2.7"))
}
