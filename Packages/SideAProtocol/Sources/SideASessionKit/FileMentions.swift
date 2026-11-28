import Foundation
import SideAProtocol

/// The `@word` at the caret that names a file, and what choosing a file puts in its place. Finding the files is
/// each app's own: the phone asks the Mac, the Mac looks in the session's folder.
public enum FileMentions {
    public struct Row: Identifiable, Hashable, Sendable {
        public let path: String
        public init(path: String) { self.path = path }
        public var id: String { path }
        public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
        public var folder: String { path.split(separator: "/").dropLast().joined(separator: "/") }
    }

    public static func word(in text: String, caret: Int) -> (range: NSRange, query: String)? {
        guard let found = CaretWord.at(caret, in: text), found.word.hasPrefix("@") else { return nil }
        return (found.range, String(found.word.dropFirst()))
    }

    /// The text with the word replaced by the path and a space after it, and the caret after that space. Claude reads
    /// `@path` as the file; Codex takes the bare path, which is what its own `@` leaves in the field. A path with a
    /// space is quoted so it stays one word.
    public static func apply(_ path: String, agent: AgentProvider, to text: String, at range: NSRange) -> (text: String, caret: Int) {
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        return CaretWord.replace(range, in: text, with: agent == .codex ? quoted : "@" + quoted)
    }

    /// What a file dropped on the message field puts in it: a mention when the file is in the session's folder, its
    /// whole path otherwise. Both agents read files by path, and the Mac is the machine the file is on.
    public static func dropped(_ path: String, folder: String?, agent: AgentProvider) -> String {
        let quote = { (text: String) in text.contains(" ") ? "\"\(text)\"" : text }
        guard let folder, !folder.isEmpty, path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") else { return quote(path) }
        let inside = String(path.dropFirst(folder.hasSuffix("/") ? folder.count : folder.count + 1))
        return agent == .codex ? quote(inside) : "@" + quote(inside)
    }
}
