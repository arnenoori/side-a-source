import Foundation
@testable import SideACore
import Testing

private func request(_ object: [String: Any], agent: String = "claude") throws -> IslandRequest {
    let data = try JSONSerialization.data(withJSONObject: ["v": 1, "agent": agent, "pid": 42, "slot": "mac", "request": object])
    return try #require(IslandRequest(message: data))
}

nonisolated(unsafe) private let rule: [String: Any] = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]], "behavior": "allow", "destination": "localSettings"]

@Test func eachKindOfRequestTakesItsOwnAnswers() throws {
    let bash = try request(["tool_name": "Bash", "cwd": "/r/app", "tool_input": ["command": "npm test"], "permission_suggestions": [rule]])
    #expect(RemoteAnswers.accepted(bash) == [.allow, .always, .deny, .terminal])
    let rm = try request(["tool_name": "Bash", "cwd": "/r/app", "tool_input": ["command": "rm -rf build"], "permission_suggestions": [rule]])
    #expect(RemoteAnswers.accepted(rm) == [.allow, .deny, .terminal])
    let plan = try request(["tool_name": "ExitPlanMode", "tool_input": ["plan": "Do it"]])
    #expect(RemoteAnswers.accepted(plan) == [.approvePlan, .deny, .terminal])
}

@Test func allowAndAlwaysFollowTheRequestNotThePhone() throws {
    let bash = try request(["tool_name": "Bash", "cwd": "/r/app", "tool_input": ["command": "npm test"], "permission_suggestions": [rule]])
    let id = RemoteAnswers.suggestionID(bash.suggestions[0])
    #expect(id.count == 16)
    #expect(try RemoteAnswers.resolve(bash, .always(suggestionID: id), gate: .unlock, proven: .unlock).get().answer == .always(bash.suggestions[0]))
    #expect(throws: RemoteAnswers.Refusal.unknownSuggestion) { try RemoteAnswers.resolve(bash, .always(suggestionID: "0000000000000000"), gate: .unlock, proven: .unlock).get() }
    #expect(try RemoteAnswers.resolve(bash, .allow(confirmDestructive: false), gate: .unlock, proven: .unlock).get() == (.allow, false))

    // A destructive Allow needs the phone's confirmation, which becomes the island's `confirmed`; Always is never one.
    let rm = try request(["tool_name": "Bash", "cwd": "/r/app", "tool_input": ["command": "rm -rf build"], "permission_suggestions": [rule]])
    #expect(throws: RemoteAnswers.Refusal.needsConfirm) { try RemoteAnswers.resolve(rm, .allow(confirmDestructive: false), gate: .biometric, proven: .unlock).get() }
    #expect(try RemoteAnswers.resolve(rm, .allow(confirmDestructive: true), gate: .biometric, proven: .biometric).get() == (.allow, true))
    #expect(throws: RemoteAnswers.Refusal.notAllowed) { try RemoteAnswers.resolve(rm, .always(suggestionID: id), gate: .biometric, proven: .biometric).get() }

    let long = String(repeating: "x", count: 3_000)
    #expect(try RemoteAnswers.resolve(bash, .deny(message: "  " + long), gate: .unlock, proven: .unlock).get().answer == .deny(String(repeating: "x", count: 2_000)))
    #expect(try RemoteAnswers.resolve(bash, .deny(message: " "), gate: .unlock, proven: .unlock).get().answer == .deny(nil))
}

@Test func questionAnswersAreCheckedAgainstTheRequestsOwnOptions() throws {
    let input: [String: Any] = ["questions": [
        ["question": "Which database?", "header": "DB", "multiSelect": false, "options": [["label": "Postgres (Recommended)"], ["label": "SQLite"]]],
        ["question": "Which extras?", "header": "Extras", "multiSelect": true, "options": [["label": "Auth"], ["label": "Billing"]]],
    ]]
    let ask = try request(["tool_name": "AskUserQuestion", "tool_input": input])
    let good: [QuestionAnswer] = [.init(question: "Which database?", picked: ["Postgres (Recommended)"]),
                                  .init(question: "Which extras?", picked: ["Auth", "Billing"], other: "Search")]
    guard case .answers(let text, let sent) = try RemoteAnswers.resolve(ask, .answers(good), gate: .unlock, proven: .unlock).get().answer else { Issue.record("no answers"); return }
    #expect(text == ["Which database?": "Postgres (Recommended)", "Which extras?": "Auth, Billing, Search"])
    // The input sent back is the request's, never the phone's.
    #expect(sent == ask.input)
    func refusal(_ answers: [QuestionAnswer]) -> RemoteAnswers.Refusal? {
        if case .failure(let refusal) = RemoteAnswers.resolve(ask, .answers(answers), gate: .unlock, proven: .unlock) { return refusal }
        return nil
    }
    #expect(refusal([good[0]]) == .incomplete)
    #expect(refusal([good[0], .init(question: "Which extras?", picked: [])]) == .incomplete)
    #expect(refusal([.init(question: "Which database?", picked: ["Postgres (Recommended)", "SQLite"]), good[1]]) == .unknownOption)
    #expect(refusal([.init(question: "Which database?", picked: ["MySQL"]), good[1]]) == .unknownOption)
    #expect(refusal(good + [.init(question: "Which colour?", picked: [])]) == .unknownOption)
    #expect(refusal([good[0], .init(question: "Which extras?", picked: [], other: String(repeating: "x", count: 2_001))]) == .tooLong)
    #expect(throws: RemoteAnswers.Refusal.notAllowed) { try RemoteAnswers.resolve(ask, .allow(confirmDestructive: true), gate: .unlock, proven: .unlock).get() }
}

private let home = FileManager.default.homeDirectoryForCurrentUser.path
private let gateRows: [(tool: String, cwd: String, input: [String: String], projects: [String], gate: AllowGate)] = [
    ("Read", "/r/app/src", ["file_path": "/r/app/src/main.swift"], ["/r/app"], .lockScreen),
    // Secrets and agent settings are destructive by the island's own rules, so they need Face ID.
    ("Read", "/r/app/src", ["file_path": "/r/app/.env.local"], ["/r/app"], .biometric),
    ("Read", "/r/app/src", ["file_path": "/Users/you/.ssh/config"], ["/r/app"], .biometric),
    ("Read", "/r/app/src", ["file_path": "/r/app/certs/server.pem"], ["/r/app"], .unlock),
    ("Read", "/r/app/src", ["file_path": "/r/app/../other/x"], ["/r/app"], .unlock),
    ("Edit", "/r/app/src", ["file_path": "/r/app/src/a.ts", "old_string": "a", "new_string": "b"], ["/r/app"], .unlock),
    ("Edit", "/r/app/src", ["file_path": "/r/app/docs/a.md", "old_string": "a", "new_string": "b"], ["/r/app"], .unlock),
    ("Write", "/r/app/src", ["file_path": "/r/app/.claude/settings.json", "content": "{}"], ["/r/app"], .biometric),
    ("Write", "/r/app/src", ["file_path": "/r/app/CLAUDE.md", "content": "{}"], ["/r/app"], .unlock),
    ("Write", "/r/app/src", ["file_path": "/r/app/.git/hooks/pre-commit", "content": "x"], ["/r/app"], .biometric),
    ("Write", "/r/app/src", ["file_path": "/tmp/x", "content": "x"], ["/r/app"], .unlock),
    ("Bash", "/r/app/src", ["command": "ls"], ["/r/app"], .unlock),
    ("Bash", "/r/app/src", ["command": "rm -rf /r/app"], ["/r/app"], .biometric),
    ("WebFetch", "/r/app/src", ["url": "https://example.com"], ["/r/app"], .unlock),
    ("Grep", "/r/app/src", ["pattern": "TODO"], ["/r/app"], .lockScreen),
    ("Grep", "/r/app/src", ["pattern": "TODO", "path": "/r/app/lib"], ["/r/app"], .lockScreen),
    ("Grep", "/r/app/src", ["pattern": "TODO", "path": "/etc"], ["/r/app"], .unlock),
    ("Grep", "/r/app/src", ["pattern": "TODO", "path": "../../other"], ["/r/app"], .unlock),
    ("Glob", "/r/app/src", ["pattern": "**/*.swift"], ["/r/app"], .lockScreen),
    ("Glob", "/r/app/src", ["pattern": "/Users/you/**/*.pem"], ["/r/app"], .unlock),
    ("Grep", "/r/app/src", ["pattern": "aws_secret", "path": "/Users/you/.aws"], ["/r/app"], .biometric),
    ("WebSearch", "/r/app/src", ["query": "swift regex"], ["/r/app"], .unlock),
    ("Write", home, ["file_path": home + "/Library/LaunchAgents/x.plist", "content": "x"], [home], .biometric),
    ("Write", home, ["file_path": home + "/notes.md", "content": "x"], [home, "/"], .unlock),
] + ["/r/app/.venv/bin/python", "/r/app/node_modules/.bin/jest", "/r/app/conftest.py", "/r/app/build.rs",
     "/r/app/.pre-commit-config.yaml", "/r/app/pyproject.toml", "/r/app/sub/setup.py"].map {
    ("Write", "/r/app", ["file_path": $0, "content": "x"], ["/r/app"], .unlock)
} + [("Write", "/r/app", ["file_path": "/r/app/src/main.rs", "content": "x"], ["/r/app"], .unlock)]

@Test(arguments: gateRows)
func onlyReadsSearchesAndProjectEditsAreAllowedFromALockedPhone(row: (tool: String, cwd: String, input: [String: String], projects: [String], gate: AllowGate)) throws {
    let asked = try request(["tool_name": row.tool, "cwd": row.cwd, "tool_input": row.input])
    #expect(AllowGate.of(asked, projects: row.projects) == row.gate)
}

@Test func aLinkInTheProjectIsGatedByWhereItLeads() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
    let project = base.appendingPathComponent("app"), outside = base.appendingPathComponent("elsewhere")
    for folder in [project.appendingPathComponent(".git"), outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("notes.md").path, withDestinationPath: "CLAUDE.md")
    try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("vendor").path, withDestinationPath: ".git")
    try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("out").path, withDestinationPath: outside.path)
    func gate(_ path: String) throws -> AllowGate {
        AllowGate.of(try request(["tool_name": "Write", "cwd": project.path, "tool_input": ["file_path": project.path + "/" + path, "content": "x"]]),
                     projects: [project.path])
    }
    #expect(try gate("README.md") == .unlock)
    // Neither target exists yet; each still counts as the file it would write.
    #expect(try gate("notes.md") == .unlock)
    #expect(try gate("vendor/config") == .biometric)
    #expect(try gate("out/new.txt") == .unlock)
}

@Test func whatLetsTheAgentGoOnNeedsTheGatesProofAndDenyingNeedsNone() throws {
    let bash = try request(["tool_name": "Bash", "cwd": "/r/app", "tool_input": ["command": "npm test"], "permission_suggestions": [rule]])
    let id = RemoteAnswers.suggestionID(bash.suggestions[0])
    // The phone's own confirmDestructive is ignored either way.
    #expect(throws: RemoteAnswers.Refusal.needsConfirm) { try RemoteAnswers.resolve(bash, .allow(confirmDestructive: true), gate: .unlock, proven: .none).get() }
    #expect(throws: RemoteAnswers.Refusal.needsConfirm) { try RemoteAnswers.resolve(bash, .always(suggestionID: id), gate: .unlock, proven: .none).get() }
    #expect(try RemoteAnswers.resolve(bash, .allow(confirmDestructive: false), gate: .unlock, proven: .biometric).get() == (.allow, true))
    #expect(try RemoteAnswers.resolve(bash, .allow(confirmDestructive: false), gate: .lockScreen, proven: .none).get() == (.allow, false))
    #expect(try RemoteAnswers.resolve(bash, .deny(message: nil), gate: .biometric, proven: .none).get().answer == .deny(nil))
    #expect(try RemoteAnswers.resolve(bash, .terminal, gate: .biometric, proven: .none).get().answer == .terminal)
    // Always would skip Face ID next time, so a biometric gate never takes it, signed or not.
    #expect(throws: RemoteAnswers.Refusal.notAllowed) { try RemoteAnswers.resolve(bash, .always(suggestionID: id), gate: .biometric, proven: .biometric).get() }
    let plan = try request(["tool_name": "ExitPlanMode", "tool_input": ["plan": "Do it"]])
    #expect(throws: RemoteAnswers.Refusal.needsConfirm) { try RemoteAnswers.resolve(plan, .approvePlan(acceptEdits: true), gate: .unlock, proven: .none).get() }
}

@Test func aLinkMadeAfterTheRequestArrivedRaisesItsGate() throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    let write = try request(["tool_name": "Write", "cwd": project.path, "tool_input": ["file_path": project.path + "/notes.md", "content": "x"]])
    #expect(write.risk == .normal && AllowGate.of(write, projects: [project.path]) == .unlock)
    try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("notes.md").path, withDestinationPath: ".claude/settings.json")
    #expect(AllowGate.of(write, projects: [project.path]) == .biometric)
}

/// Allow and switch mode: only Claude's edits that aren't destructive offer it, only with Allow and a listed mode,
/// and it goes to the hook as an allow that names the mode.
@Test func allowAndSwitchModeOnlyWhereTheRequestOffersIt() throws {
    let edit = try request(["tool_name": "Edit", "cwd": "/r/app", "tool_input": ["file_path": "/r/app/README.md", "old_string": "a", "new_string": "b"]])
    #expect(RemoteAnswers.modes(edit) == [.acceptEdits] && RemoteAnswers.accepted(edit).contains(.allowMode))
    let resolved = try RemoteAnswers.resolve(edit, .allow(confirmDestructive: false), mode: .acceptEdits, gate: .unlock, proven: .unlock).get()
    #expect(resolved == (.allowMode("acceptEdits"), false))
    let line = try #require(try JSONSerialization.jsonObject(with: resolved.answer.line) as? [String: String])
    #expect(line == ["behavior": "allow", "mode": "acceptEdits"])

    #expect(throws: RemoteAnswers.Refusal.notAllowed) {
        try RemoteAnswers.resolve(edit, .allow(confirmDestructive: false), mode: .bypassPermissions, gate: .unlock, proven: .biometric).get()
    }
    #expect(throws: RemoteAnswers.Refusal.notAllowed) { try RemoteAnswers.resolve(edit, .deny(message: nil), mode: .acceptEdits, gate: .unlock, proven: .unlock).get() }
    #expect(throws: RemoteAnswers.Refusal.needsConfirm) {
        try RemoteAnswers.resolve(edit, .allow(confirmDestructive: false), mode: .acceptEdits, gate: .unlock, proven: .none).get()
    }

    // A destructive request offers no mode, and refuses one sent anyway, with or without Face ID.
    let rm = try request(["tool_name": "Bash", "cwd": "/r/app", "tool_input": ["command": "rm -rf build"]])
    #expect(RemoteAnswers.modes(rm).isEmpty && !RemoteAnswers.accepted(rm).contains(.allowMode))
    #expect(throws: RemoteAnswers.Refusal.notAllowed) {
        try RemoteAnswers.resolve(rm, .allow(confirmDestructive: true), mode: .acceptEdits, gate: .biometric, proven: .biometric).get()
    }
    // Codex, commands, questions and plans offer none.
    let codexEdit = try request(["tool_name": "Edit", "cwd": "/r/app", "tool_input": ["file_path": "/r/app/README.md", "old_string": "a", "new_string": "b"]], agent: "codex")
    let bash = try request(["tool_name": "Bash", "cwd": "/r/app", "tool_input": ["command": "npm test"]])
    let plan = try request(["tool_name": "ExitPlanMode", "tool_input": ["plan": "Do it"]])
    #expect([codexEdit, bash, plan].allSatisfy { RemoteAnswers.modes($0).isEmpty })
}
