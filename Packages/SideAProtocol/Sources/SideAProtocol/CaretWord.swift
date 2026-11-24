import Foundation

public enum CaretWord {
    /// `caret` is a UTF-16 offset.
    public static func at(_ caret: Int, in text: String) -> (range: NSRange, word: String)? {
        let string = text as NSString
        let caret = min(max(caret, 0), string.length)
        var start = caret
        while start > 0, !isSpace(string.character(at: start - 1)) { start -= 1 }
        var end = caret
        while end < string.length, !isSpace(string.character(at: end)) { end += 1 }
        guard start < caret else { return nil }
        let range = NSRange(location: start, length: end - start)
        return (range, string.substring(with: range))
    }

    public static func command(in text: String, caret: Int, codex: Bool) -> (range: NSRange, word: String)? {
        guard let found = at(caret, in: text), found.word.hasPrefix("/") || codex && found.word.hasPrefix("$") else { return nil }
        return found
    }

    public static func matches(_ word: String, in options: [AgentOptions.Option], limit: Int) -> [AgentOptions.Option] {
        let typed = word.lowercased()
        let sigil = typed.prefix(1)
        let mine = options.filter { $0.id.hasPrefix(sigil) }
        let starts = mine.filter { $0.id.lowercased().hasPrefix(typed) }
        let rest = typed.count > 1 ? mine.filter { !$0.id.lowercased().hasPrefix(typed) && $0.id.lowercased().contains(typed.dropFirst()) } : []
        return Array((starts + rest).prefix(limit))
    }

    public static func replace(_ range: NSRange, in text: String, with word: String) -> (text: String, caret: Int) {
        let string = text as NSString
        let after = range.location + range.length
        let space = after < string.length && isSpace(string.character(at: after)) ? "" : " "
        return (string.replacingCharacters(in: range, with: word + space), range.location + (word + " ").utf16.count)
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D
    }
}
