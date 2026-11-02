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
        let string = text as NSString
        let caret = min(max(caret, 0), string.length)
        var start = caret
        while start > 0, !isSpace(string.character(at: start - 1)) { start -= 1 }
        var end = caret
        while end < string.length, !isSpace(string.character(at: end)) { end += 1 }
        guard start < caret else { return nil }
        let word = string.substring(with: NSRange(location: start, length: end - start))
        guard word.hasPrefix("/") || codex && word.hasPrefix("$") else { return nil }
        return (NSRange(location: start, length: end - start), word)
    }

    /// Options starting with the word first, then those containing it, in the list's own order.
    static func matches(_ word: String, in options: [Option]) -> [Option] {
        let typed = word.lowercased()
        let sigil = typed.prefix(1)
        let mine = options.filter { $0.id.hasPrefix(sigil) }
        let starts = mine.filter { $0.id.lowercased().hasPrefix(typed) }
        let rest = typed.count > 1 ? mine.filter { !$0.id.lowercased().hasPrefix(typed) && $0.id.lowercased().contains(typed.dropFirst()) } : []
        return Array((starts + rest).prefix(limit))
    }

    /// The text with the word replaced by the chosen command and a space after it.
    static func apply(_ option: Option, to text: String, at range: NSRange) -> String {
        let string = text as NSString
        let after = range.location + range.length
        let space = after < string.length && isSpace(string.character(at: after)) ? "" : " "
        return string.replacingCharacters(in: range, with: option.id + space)
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D
    }
}
