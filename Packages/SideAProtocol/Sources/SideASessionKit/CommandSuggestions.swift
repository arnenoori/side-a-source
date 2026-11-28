import Foundation
import SideAProtocol

/// The `/command` or `$skill` being typed at the caret, the options that match it, and what choosing one leaves in
/// the text. One implementation for the phone's composer and the Mac's.
public enum CommandSuggestions {
    public typealias Option = AgentOptions.Option

    public static let limit = 8
    public static let visibleRows = 5

    /// The word the caret is in or just after, when it starts with "/" (either agent) or "$" (Codex).
    public static func word(in text: String, caret: Int, agent: AgentProvider) -> (range: NSRange, word: String)? {
        CaretWord.command(in: text, caret: caret, codex: agent == .codex)
    }

    /// Options starting with the word first, then those containing it, in the list's own order.
    public static func matches(_ word: String, in options: [Option]) -> [Option] { CaretWord.matches(word, in: options, limit: limit) }

    public static func apply(_ option: Option, to text: String, at range: NSRange) -> (text: String, caret: Int) {
        CaretWord.replace(range, in: text, with: option.id)
    }
}
