import Foundation
import SideAProtocol

/// "/" commands, and Codex's "$" skills, offered while the word at the caret starts with one: the phone's own lists,
/// matched the same way.
enum ComposerSuggestions {
    typealias Option = AgentOptions.Option

    /// Rows shown at once.
    static let limit = 8

    /// The word the caret is in or just after, when it starts with "/" (either agent) or "$" (Codex).
    static func word(in text: String, caret: Int, codex: Bool) -> (range: NSRange, word: String)? {
        CaretWord.command(in: text, caret: caret, codex: codex)
    }

    /// Options starting with the word first, then those containing it, in the list's own order.
    static func matches(_ word: String, in options: [Option]) -> [Option] { CaretWord.matches(word, in: options, limit: limit) }

    /// The text with the word replaced by the chosen command and a space after it.
    static func apply(_ option: Option, to text: String, at range: NSRange) -> String { CaretWord.replace(range, in: text, with: option.id).text }
}
