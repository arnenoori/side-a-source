import SwiftUI
import UIKit

public struct MarkdownBlock: Identifiable, Hashable {
    public enum Kind: Hashable {
        case paragraph
        case heading(Int)
        case code(language: String?)
        case listItem(marker: String, depth: Int)
        case quote
        case rule
        case table(header: [AttributedString], rows: [[AttributedString]])
    }

    public let id: Int
    public let kind: Kind
    public let text: AttributedString

    public init(id: Int, kind: Kind, text: AttributedString) { self.id = id; self.kind = kind; self.text = text }
}

public enum MarkdownParser {
    /// NSCache is thread-safe (so `unsafe` is sound here) and evicts under memory pressure; the limit keeps a streaming
    /// reply's many partial texts from piling up.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 256
        return cache
    }()

    private final class Parsed {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    /// `files`: local paths become `FileLink`s, for a view that opens them in the app.
    public static func blocks(_ markdown: String, files: Bool = false) -> [MarkdownBlock] {
        let key = ((files ? "f" : "-") + markdown) as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = parse(markdown, files: files)
        cache.setObject(Parsed(blocks), forKey: key)
        return blocks
    }

    private static func parse(_ markdown: String, files: Bool) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }

        var blocks: [MarkdownBlock] = []
        var keys: [Int] = []
        var table: (identity: Int, header: [Int: AttributedString], rows: [Int: [Int: AttributedString]])?

        func flushTable() {
            guard let current = table else { return }
            let columns = (current.header.keys.max() ?? -1) + 1
            let header = (0..<columns).map { current.header[$0] ?? "" }
            let rows = current.rows.keys.sorted().map { row in (0..<columns).map { current.rows[row]?[$0] ?? "" } }
            blocks.append(MarkdownBlock(id: blocks.count, kind: .table(header: header, rows: rows), text: ""))
            keys.append(current.identity)
            table = nil
        }

        for (intent, range) in parsed.runs[\.presentationIntent] {
            let text = styled(AttributedString(parsed[range]), files: files)
            guard let intent else {
                keys.append(-1)
                blocks.append(MarkdownBlock(id: blocks.count, kind: .paragraph, text: text))
                continue
            }
            let components = intent.components

            if let tableComponent = components.first(where: { if case .table = $0.kind { true } else { false } }) {
                if table?.identity != tableComponent.identity { flushTable(); table = (tableComponent.identity, [:], [:]) }
                var column = 0, row: Int?
                for component in components {
                    switch component.kind {
                    case .tableCell(let index): column = index
                    case .tableRow(let index): row = index
                    default: break
                    }
                }
                if let row { table?.rows[row, default: [:]][column, default: ""] += text } else { table?.header[column, default: ""] += text }
                continue
            }
            flushTable()

            // Runs of one block arrive one after another, keyed by the innermost component's identity.
            let key = components.first?.identity ?? -1
            if let last = keys.last, last == key, let index = blocks.indices.last {
                blocks[index] = MarkdownBlock(id: blocks[index].id, kind: blocks[index].kind, text: blocks[index].text + text)
            } else {
                keys.append(key)
                blocks.append(MarkdownBlock(id: blocks.count, kind: kind(of: components), text: text))
            }
        }
        flushTable()
        return blocks
    }

    private static func kind(of components: [PresentationIntent.IntentType]) -> MarkdownBlock.Kind {
        let depth = components.filter { if case .listItem = $0.kind { true } else { false } }.count
        for component in components {
            switch component.kind {
            case .header(let level): return .heading(level)
            case .codeBlock(let language): return .code(language: language)
            case .thematicBreak: return .rule
            case .blockQuote: return .quote
            case .listItem(let ordinal):
                let ordered = components.contains { if case .orderedList = $0.kind { true } else { false } }
                return .listItem(marker: ordered ? "\(ordinal)." : (depth > 1 ? "◦" : "•"), depth: depth)
            default: continue
            }
        }
        return .paragraph
    }

    /// Inline code on a quiet fill, links in the label colour and underlined, local paths in mono. Only
    /// web links stay tappable (`AgentLink`): agent output must not open a pairing link or another app. With `files`,
    /// local paths are links too, to the app's own viewer (`FileLink`), never the system.
    private static func styled(_ text: AttributedString, files: Bool) -> AttributedString {
        var text = text
        for run in text.runs {
            var file: String?
            if let inline = run.inlinePresentationIntent, inline.contains(.code) {
                text[run.range].font = .callout.monospaced()
                text[run.range].backgroundColor = Color(.tertiarySystemFill)
                if files, run.link == nil { file = FileLink.path(code: String(text[run.range].characters)) }
            }
            if let link = run.link {
                if files, let path = FileLink.local(link) {
                    file = path
                } else if !AgentLink.opens(link) {
                    text[run.range].link = nil
                    continue
                }
            }
            if let file { text[run.range].link = FileLink.url(file) }
            guard text[run.range].link != nil else { continue }
            text[run.range].foregroundColor = .primary
            text[run.range].underlineStyle = .single
        }
        return text
    }
}

/// A local file named in agent prose: a Markdown link with no scheme or `file:`, or inline code that looks like a
/// path. It travels as a `sidea-file:` link that only the app's own views act on; one the agent wrote itself has a
/// scheme of its own, so it's dropped with the other links that aren't web pages.
public enum FileLink {
    static let scheme = "sidea-file"

    public static func url(_ path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.path = path
        return components.url
    }

    public static func path(_ url: URL) -> String? {
        guard url.scheme == scheme, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, !path.isEmpty else { return nil }
        return path
    }

    /// Without the destination's `#fragment`, `?query` or `:line`.
    static func local(_ link: URL) -> String? {
        let scheme = link.scheme?.lowercased()
        guard scheme == nil || scheme == "file", let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              scheme == nil || [nil, "", "localhost"].contains(components.host) else { return nil }
        let path = withoutLine(components.path)
        return path.isEmpty ? nil : path
    }

    static let known: Set<String> = [
        "md", "markdown", "txt", "rtf", "pdf", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "xml", "plist", "html", "htm", "css",
        "js", "mjs", "cjs", "ts", "tsx", "jsx", "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "py", "rb", "java", "kt",
        "sh", "zsh", "bash", "sql", "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "docx", "doc", "xlsx", "xls", "pptx", "ppt",
        "key", "pages", "numbers", "log", "ipynb", "lock", "xcconfig", "entitlements", "proto", "graphql", "vue", "svelte", "lua", "php",
    ]

    /// `docs/plan.md`, `src/a.swift:42` or `README.md`: one word of path characters ending in an extension, which needs
    /// a folder in front unless it's a known one. Nil for anything else.
    static func path(code: String) -> String? {
        let path = withoutLine(code)
        guard path.count <= 300, !path.hasPrefix("-"), !path.contains("//"),
              path.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-/~@+".unicodeScalars.contains($0) }) else { return nil }
        let name = (path as NSString).lastPathComponent, ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, ext.count <= 12, ext.contains(where: \.isLetter), name.count > ext.count + 1 else { return nil }
        return path.contains("/") || known.contains(ext) ? path : nil
    }

    static func withoutLine(_ path: String) -> String {
        var parts = path.split(separator: ":", omittingEmptySubsequences: false)
        while parts.count > 1, let last = parts.last, !last.isEmpty, last.allSatisfy(\.isNumber) { parts.removeLast() }
        return parts.joined(separator: ":")
    }
}
