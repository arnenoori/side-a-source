import Foundation
import SideAProtocol

enum ComposerSuggestions {
    typealias Option = AgentOptions.Option

    static let limit = 8

    /// The word the caret is in or just after, when it starts with "/" (either agent) or "$" (Codex).
    static func word(in text: String, caret: Int, codex: Bool) -> (range: NSRange, word: String)? {
        CaretWord.command(in: text, caret: caret, codex: codex)
    }

    /// Options starting with the word first, then those containing it, in the list's own order.
    static func matches(_ word: String, in options: [Option]) -> [Option] { CaretWord.matches(word, in: options, limit: limit) }

    static func apply(_ option: Option, to text: String, at range: NSRange) -> String { CaretWord.replace(range, in: text, with: option.id).text }
}
