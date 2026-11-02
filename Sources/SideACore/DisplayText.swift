import Foundation
import SideAProtocol

/// Text an agent wrote, made safe to look at: what the phone or the island shows is what is really there. Only ever
/// applied to what is displayed; the command that runs comes from the request's own input.
public enum DisplayText {
    public static func hidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A: false
        case 0x00...0x1F, 0x7F...0x9F: true
        case 0x00AD, 0x061C, 0x180E, 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2064, 0x2066...0x206F, 0xFEFF, 0xFFF9...0xFFFB: true
        case 0xE0000...0xE007F: true
        default: false
        }
    }

    /// Each hidden character as `⟦U+202E⟧`; CRLF becomes LF.
    public static func escaped(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var clean = true
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { clean = false; continue }
            guard hidden(scalar) else { out.append(scalar); continue }
            clean = false
            out.append(contentsOf: "⟦U+\(String(format: "%04X", scalar.value))⟧".unicodeScalars)
        }
        return clean ? text : String(out)
    }

    /// Enough blank lines, blanks or characters on a line to push the rest of a command off the card.
    static let blankLines = 6
    static let spaces = 80
    static let longLine = 1_000

    /// Draws nothing: every Unicode space separator, tabs, and the Braille and Hangul blanks.
    static func blank(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\t" || scalar.properties.generalCategory == .spaceSeparator || [0x115F, 0x1160, 0x2800, 0x3164, 0xFFA0].contains(scalar.value)
    }

    /// Something in it is hidden, or laid out to be missed. `longLines: false` for text that is long by nature, like a diff.
    public static func suspicious(_ text: String, longLines: Bool = true) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var newlines = 0, run = 0, line = 0
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { continue }
            if hidden(scalar) { return true }
            if scalar == "\n" { newlines += 1; line = 0 } else {
                line += 1
                if !blank(scalar) { newlines = 0 }
            }
            if newlines >= blankLines || (longLines && line >= longLine) { return true }
            run = blank(scalar) ? run + 1 : 0
            if run >= spaces { return true }
        }
        return false
    }
}

extension IslandAction {
    /// Every string it shows.
    public var shownText: [String] {
        switch self {
        case .command(let text), .read(let text), .search(let text), .fetch(let text), .plan(let text): [text]
        case .edit(let path, let removed, let added): [path, removed, added]
        case .write(let path, let content): [path, content]
        case .patch(let files, let text): files + [text]
        case .mcp(let server, let tool, let arguments): [server, tool, arguments]
        case .other(let tool, let arguments): [tool, arguments]
        case .question(let questions): questions.flatMap { [$0.question] + [$0.header ?? ""] + $0.options.flatMap { [$0.label, $0.description ?? ""] } }
        }
    }

    /// A command, a path, a search or a link: nothing in these is long by nature.
    public var isOneLiner: Bool {
        switch self {
        case .command, .read, .search, .fetch: true
        default: false
        }
    }

    /// As the phone gets it. A question's words go as they are: the phone sends them back as the answer's key, and Claude
    /// Code matches them exactly. `AllowGate` still rates one with hidden characters by them.
    public var escaped: IslandAction {
        let e = DisplayText.escaped
        return switch self {
        case .command(let text): .command(e(text))
        case .read(let path): .read(path: e(path))
        case .search(let text): .search(e(text))
        case .fetch(let url): .fetch(e(url))
        case .plan(let plan): .plan(e(plan))
        case .edit(let path, let removed, let added): .edit(path: e(path), removed: e(removed), added: e(added))
        case .write(let path, let content): .write(path: e(path), content: e(content))
        case .patch(let files, let text): .patch(files: files.map(e), text: e(text))
        case .mcp(let server, let tool, let arguments): .mcp(server: e(server), tool: e(tool), arguments: e(arguments))
        case .other(let tool, let arguments): .other(tool: e(tool), arguments: e(arguments))
        case .question: self
        }
    }
}
