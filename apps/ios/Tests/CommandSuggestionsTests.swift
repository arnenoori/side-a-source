import Foundation
import SideAProtocol
import XCTest
@testable import SideARemote

@MainActor
final class CommandSuggestionsTests: XCTestCase {
    private let commands = [
        AgentOptions.Option(id: "/compact", label: "Summarize the conversation to free up context"),
        AgentOptions.Option(id: "/review", label: "Review a pull request"),
        AgentOptions.Option(id: "/frontend:review", label: "Review the UI"),
        AgentOptions.Option(id: "/release-notes", label: "Draft the changelog"),
        AgentOptions.Option(id: "$repo-lint", label: "Lint the repository"),
    ]

    /// What the list shows with the caret at `|` (the end when there's none).
    private func ids(_ typed: String, _ agent: AgentProvider = .claude) -> [String] {
        let caret = typed.firstIndex(of: "|").map { typed[..<$0].utf16.count } ?? typed.utf16.count
        let text = typed.replacingOccurrences(of: "|", with: "")
        guard let word = CommandSuggestions.word(in: text, caret: caret, agent: agent) else { return [] }
        return CommandSuggestions.matches(word.word, in: commands).map(\.id)
    }

    func testSlashAloneListsEverySlashCommandInTheMacsOrder() {
        XCTAssertEqual(ids("/"), ["/compact", "/review", "/frontend:review", "/release-notes"])
    }

    func testPrefixesFirstThenContains() {
        XCTAssertEqual(ids("/re"), ["/review", "/release-notes", "/frontend:review"])
        XCTAssertEqual(ids("/notes"), ["/release-notes"])
        XCTAssertEqual(ids("/COMP"), ["/compact"])
        XCTAssertEqual(ids("/zzz"), [])
    }

    func testTheWordAtTheCaretAnywhereInTheText() {
        XCTAssertEqual(ids("then /comp"), ["/compact"])
        XCTAssertEqual(ids("/comp| and more"), ["/compact"])
        XCTAssertEqual(ids("/compact |"), [])
        XCTAssertEqual(ids("path/to"), [])
    }

    func testDollarIsCodexsSkills() {
        XCTAssertEqual(ids("$", .codex), ["$repo-lint"])
        XCTAssertEqual(ids("$lint", .codex), ["$repo-lint"])
        XCTAssertEqual(ids("$", .claude), [])
    }

    func testPickingReplacesTheWordAndLeavesTheCaretAfterItsSpace() {
        let text = "please /rev now", range = NSRange(location: 7, length: 4)
        let picked = CommandSuggestions.apply(commands[1], to: text, at: range)
        XCTAssertEqual(picked.text, "please /review now")
        XCTAssertEqual(picked.caret, 15)
        let atEnd = CommandSuggestions.apply(commands[0], to: "/co", at: NSRange(location: 0, length: 3))
        XCTAssertEqual(atEnd.text, "/compact ")
        XCTAssertEqual(atEnd.caret, 9)
    }
}
