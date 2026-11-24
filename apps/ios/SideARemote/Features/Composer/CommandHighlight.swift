import Foundation
import SideAProtocol

/// Which words in a message are real commands, so the composer and the sent bubble can tint them as T3 Code and the
/// Codex app do. Only a word the agent would act on counts: a leading `/command` that is in the Mac's list for this
/// agent (both agents read a slash command only at the very start of a message), and for Codex a `$skill` that is a
/// skill in the list, anywhere. The Mac's composer does not tint; these are the same lists its autocomplete offers, held
/// to where the agents really treat the word as a command. A `/` or `$` anywhere else (a path, an amount) stays plain.
enum CommandHighlight {
    static let builtIn = ["/model", "/effort", "/compact", "/clear", "/review"]

    static func ranges(in text: String, agent: AgentProvider, commands: [AgentOptions.Option]) -> [NSRange] {
        let known = Set(commands.isEmpty ? builtIn : commands.map(\.id))
        let string = text as NSString
        var found: [NSRange] = []
        var index = 0
        var first = true
        while index < string.length {
            while index < string.length, isSpace(string.character(at: index)) { index += 1 }
            let start = index
            while index < string.length, !isSpace(string.character(at: index)) { index += 1 }
            guard index > start else { break }
            let isFirst = first
            first = false
            let lead = string.character(at: start)
            let isSlash = lead == 0x2F, isDollar = lead == 0x24
            guard (isSlash && isFirst) || (isDollar && agent == .codex) else { continue }
            if let range = match(NSRange(location: start, length: index - start), in: string, known: known) { found.append(range) }
        }
        return found
    }

    private static func match(_ token: NSRange, in string: NSString, known: Set<String>) -> NSRange? {
        var range = token
        while range.length > 1 {
            if known.contains(string.substring(with: range)) { return range }
            guard closers.contains(string.character(at: range.location + range.length - 1)) else { return nil }
            range.length -= 1
        }
        return nil
    }

    private static let closers: Set<unichar> = Set(",.;:!?)]}\"'".utf16)

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D
    }
}
