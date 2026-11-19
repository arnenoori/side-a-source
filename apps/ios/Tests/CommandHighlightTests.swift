import Foundation
import SideAProtocol
import XCTest
@testable import SideARemote

@MainActor
final class CommandHighlightTests: XCTestCase {
    private let commands = [
        AgentOptions.Option(id: "/compact", label: ""),
        AgentOptions.Option(id: "/review", label: ""),
        AgentOptions.Option(id: "$repo-lint", label: ""),
        AgentOptions.Option(id: "$deploy", label: ""),
    ]

    /// The highlighted words, read back out of the text.
    private func words(_ text: String, _ agent: AgentProvider = .claude) -> [String] {
        let string = text as NSString
        return CommandHighlight.ranges(in: text, agent: agent, commands: commands).map { string.substring(with: $0) }
    }

    func testALeadingKnownCommandIsHighlightedAndItsArgumentsAreNot() {
        XCTAssertEqual(CommandHighlight.ranges(in: "/review the auth change", agent: .claude, commands: commands), [NSRange(location: 0, length: 7)])
        XCTAssertEqual(words("/compact"), ["/compact"])
        XCTAssertEqual(words("  \n/compact now"), ["/compact"], "leading whitespace doesn't make it mid-sentence")
    }

    func testAnUnknownCommandStaysPlain() {
        XCTAssertEqual(words("/foo bar"), [])
        XCTAssertEqual(words("/"), [])
        XCTAssertEqual(words("/rev"), [], "a word still being typed")
        XCTAssertEqual(words("/REVIEW"), [], "the agents match case")
    }

    func testASlashCommandMidSentenceIsNotACommandForEitherAgent() {
        XCTAssertEqual(words("please run /review now"), [])
        XCTAssertEqual(words("please run /review now", .codex), [])
        XCTAssertEqual(words("/review then /compact"), ["/review"])
    }

    func testSkillsAreCodexOnlyAndWorkAnywhere() {
        XCTAssertEqual(words("use $repo-lint and then $deploy", .codex), ["$repo-lint", "$deploy"])
        XCTAssertEqual(words("$deploy", .codex), ["$deploy"])
        XCTAssertEqual(words("use $repo-lint", .claude), [])
        XCTAssertEqual(words("/compact $deploy", .codex), ["/compact", "$deploy"])
    }

    func testAnAmountOrAPathIsNotACommand() {
        XCTAssertEqual(words("it costs $20", .codex), [])
        XCTAssertEqual(words("$20 is the cap", .codex), [])
        XCTAssertEqual(words("edit src/app and /usr/bin", .codex), [])
        XCTAssertEqual(words("src/app"), [])
        XCTAssertEqual(words("/usr/bin/env"), [])
    }

    func testPunctuationThatEndsASentenceIsNotPartOfTheWord() {
        XCTAssertEqual(words("run $deploy, then stop", .codex), ["$deploy"])
        XCTAssertEqual(words("($deploy)", .codex), [], "a word has to start with its sign")
        XCTAssertEqual(words("ask me ($deploy)?", .codex), [])
        XCTAssertEqual(words("then $deploy.", .codex), ["$deploy"])
    }

    func testRangesAreUTF16OffsetsEvenAfterEmojiAndAccents() {
        let text = "/compact 👩‍👩‍👧 then $deploy é$deploy $deploy"
        let found = CommandHighlight.ranges(in: text, agent: .codex, commands: commands)
        let string = text as NSString
        XCTAssertEqual(found.map { string.substring(with: $0) }, ["/compact", "$deploy", "$deploy"])
        XCTAssertEqual(found[0], NSRange(location: 0, length: 8))
        XCTAssertEqual(found[1].location, string.range(of: "then $deploy").location + 5)
    }

    func testWithNoListTheBuiltInsStandIn() {
        XCTAssertEqual(CommandHighlight.ranges(in: "/model", agent: .claude, commands: []), [NSRange(location: 0, length: 6)])
        XCTAssertEqual(CommandHighlight.ranges(in: "/zzz", agent: .claude, commands: []), [])
    }

    func testEmptyTextHasNothing() {
        XCTAssertEqual(words(""), [])
        XCTAssertEqual(words("   "), [])
    }
}
