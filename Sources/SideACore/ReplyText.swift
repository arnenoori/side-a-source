import Foundation

/// How a reply's words are compared with what a screen or a transcript shows of them. A screen wraps and indents rows
/// and a transcript keeps the text whole, so whitespace never decides a match.
public enum ReplyText {
    static func squash(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    /// For a prompt read back from the screen against the replies typed into it.
    public static func squashPasted(_ text: String) -> String { squash(Hosting.clean(text)) }

    /// For a transcript's message against a reply: photos pasted ahead of it don't count.
    static func key(_ text: String) -> String { squash(Hosting.withoutAttachments(Hosting.clean(text))) }

    /// Claude Code shows such text as `[Pasted text #2 +3 lines]`, not its words.
    public static func long(_ text: String) -> Bool { text.count > 200 || text.contains("\n") }

    // Two placeholder checks, on different input: the composer's own row as drawn, where the placeholder starts it, and a
    // whole prompt already squashed, where it can sit between replies and only one may be there.

    static func startsWithPlaceholder(_ shown: String) -> Bool {
        shown.hasPrefix("[Pasted text #") || shown.hasPrefix("[Pasted Content ")
    }

    public static func placeholder(inSquashed prompt: String) -> Range<String.Index>? {
        guard prompt.components(separatedBy: "[Pasted").count == 2 else { return nil }
        return prompt.range(of: #"\[Pasted(text#\d+|Content)[^\[\]]*\]"#, options: .regularExpression)
    }

    // MARK: Transcript lines

    static func words(_ content: Any?, blocks: Set<String>) -> String? {
        switch content {
        case let text as String: text
        case let parts as [[String: Any]]: parts.compactMap { ($0["type"] as? String).map(blocks.contains) == true ? $0["text"] as? String : nil }.joined(separator: "\n")
        default: nil
        }
    }

    static func at(_ entry: [String: Any]) -> Double {
        (entry["timestamp"] as? String).flatMap(time) ?? Date().timeIntervalSince1970
    }

    // Thread-safe (ISO8601DateFormatter), and a transcript can have thousands of lines to read.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let parse = ISO8601DateFormatter()
        parse.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parse
    }()

    static func time(_ text: String) -> Double? { iso.date(from: text)?.timeIntervalSince1970 }
}
