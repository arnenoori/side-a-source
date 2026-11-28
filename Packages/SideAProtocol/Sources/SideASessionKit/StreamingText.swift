import Foundation

/// Where a reply that is still arriving can be cut for display.
public enum StreamingText {
    /// The first word boundary at or after `offset`, so a reveal never stops inside a word.
    public static func wordBoundary(in text: String, atOrAfter offset: Int) -> Int {
        guard offset < text.count else { return text.count }
        var index = text.index(text.startIndex, offsetBy: offset)
        var count = offset
        while index < text.endIndex, !text[index].isWhitespace {
            index = text.index(after: index)
            count += 1
        }
        return count
    }

    /// Where the text's finished blocks end: everything before it can no longer change as more arrives. A blank line
    /// inside an open code fence is not a boundary.
    public static func frozenEnd(of text: String) -> Int {
        var end = 0, offset = 0, inFence = false, previousBlank = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let blank = trimmed.isEmpty
            if !inFence, previousBlank, !blank { end = offset }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            previousBlank = blank && !inFence
            offset += line.count + 1
        }
        return end
    }
}
