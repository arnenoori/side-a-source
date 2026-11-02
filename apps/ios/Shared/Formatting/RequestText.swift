import Foundation

/// What a request says, with nothing hiding in it. Bidi overrides, zero-width and other invisible characters, and
/// controls show as escapes, tinted where they are drawn, so what's read is what would run. Applied on the phone, so
/// a Mac that doesn't clean its requests is still safe.
public enum RequestText {
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let escaped: Bool
    }

    /// Enough blank lines or blanks in a row to push the rest of a command off the card.
    static let blankLines = 6
    static let blankRun = 80
    /// What a notification card shows of a request: lines, and about what fits across one.
    static let cardLines = 8
    static let cardColumns = 40

    public static func hasEscapes(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return scalars.indices.contains { hidden(scalars, at: $0) } || padded(text)
    }

    /// Laid out to be missed, whatever the Mac said about it.
    public static func padded(_ text: String) -> Bool {
        var newlines = 0, run = 0
        for scalar in text.unicodeScalars where scalar != "\r" {
            if scalar == "\n" { newlines += 1 } else if !blank(scalar) { newlines = 0 }
            run = blank(scalar) ? run + 1 : 0
            if newlines >= blankLines || run >= blankRun { return true }
        }
        return false
    }

    /// A card shows all of it: long lines count as the lines they wrap to.
    public static func fitsCard(_ text: String) -> Bool {
        guard !padded(text) else { return false }
        return lines(text).reduce(0) { $0 + max(1, ($1.count + cardColumns - 1) / cardColumns) } <= cardLines
    }

    public static func visible(_ text: String) -> String { segments(text).map(\.text).joined() }

    public static func segments(_ text: String) -> [Segment] {
        let scalars = Array(text.unicodeScalars)
        var segments: [Segment] = []
        var plain = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            var end = index
            while end < scalars.count, blank(scalars[end]) { end += 1 }
            let long = end - index >= blankRun
            guard long || hidden(scalars, at: index) else {
                plain.append(scalars[index])
                index += 1
                continue
            }
            if !plain.isEmpty { segments.append(Segment(text: String(plain), escaped: false)) }
            plain = String.UnicodeScalarView()
            segments.append(Segment(text: long ? "\(escape(scalars[index]))×\(end - index)" : escape(scalars[index]), escaped: true))
            index = long ? end : index + 1
        }
        if !plain.isEmpty { segments.append(Segment(text: String(plain), escaped: false)) }
        return segments
    }

    /// Split at every line feed. `components(separatedBy:)` keeps `\r\n` whole, since it's one Character.
    public static func lines(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    private static func escape(_ scalar: Unicode.Scalar) -> String {
        scalar == "\r" ? "\\r" : "\\u{" + String(format: "%04X", scalar.value) + "}"
    }

    /// Draws nothing: every Unicode space separator, tabs, and the Braille and Hangul blanks.
    private static func blank(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\t" || scalar.properties.generalCategory == .spaceSeparator || [0x115F, 0x1160, 0x2800, 0x3164, 0xFFA0].contains(scalar.value)
    }

    private static func hidden(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let scalar = scalars[index]
        switch scalar {
        case "\n", "\t", "\u{FE0E}", "\u{FE0F}": return false
        case "\u{200D}" where joinsEmoji(scalars, at: index): return false
        default: break
        }
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// 👩‍💻 needs its joiner, so one between two emoji stays.
    private static func joinsEmoji(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index > 0, index + 1 < scalars.count else { return false }
        let before = scalars[index - 1], after = scalars[index + 1]
        func emoji(_ scalar: Unicode.Scalar) -> Bool { scalar.value > 0xFF && scalar.properties.isEmoji }
        return (emoji(before) || before == "\u{FE0F}") && emoji(after)
    }
}

/// Whether a link in an agent's text or terminal may open: web pages only, never another app or a pairing link in
/// either form (`sidea-remote://pair`, `https://getsidea.com/pair`).
public enum AgentLink {
    public static func opens(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        var host = (url.host(percentEncoded: false) ?? "").lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard host == "getsidea.com" || host.hasSuffix(".getsidea.com") else { return true }
        return url.standardized.path(percentEncoded: false).lowercased().split(separator: "/").first != "pair"
    }
}
