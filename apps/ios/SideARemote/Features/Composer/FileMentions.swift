import Foundation
import SideAProtocol

/// An `@` word at the caret names a file in the session's folder: the Mac lists the matches and the chosen path takes
/// the word's place, as typing `@` does in Claude Code and Codex at the Mac.
enum FileMentions {
    /// A matched path as its row shows it: the file's name, with its folder as the muted line.
    struct Row: Identifiable, Hashable {
        let path: String
        var id: String { path }
        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
        var folder: String { path.split(separator: "/").dropLast().joined(separator: "/") }
    }

    /// The `@` word the caret (a UTF-16 offset) is in or just after, and what follows the `@`. An address
    /// (`me@example.com`) isn't one: the `@` has to start the word.
    static func word(in text: String, caret: Int) -> (range: NSRange, query: String)? {
        guard let found = CaretWord.at(caret, in: text), found.word.hasPrefix("@") else { return nil }
        return (found.range, String(found.word.dropFirst()))
    }

    /// The text with the word replaced by the path and a space after it, and the caret after that space. Claude reads
    /// `@path` as the file; Codex takes the bare path, which is what its own `@` leaves in the field. A path with a
    /// space is quoted so it stays one word.
    static func apply(_ path: String, agent: AgentProvider, to text: String, at range: NSRange) -> (text: String, caret: Int) {
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        return CaretWord.replace(range, in: text, with: agent == .codex ? quoted : "@" + quoted)
    }
}
