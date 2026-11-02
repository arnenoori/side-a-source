import SwiftUI
import UIKit

/// One block of parsed Markdown: what `PresentationIntent` says a run of text is.
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

/// Markdown into blocks, natively (the app and the notification extension share it): `AttributedString(markdown:)` with full syntax, then a walk over
/// each run's `PresentationIntent`. Inline styles stay in the `AttributedString`.
public enum MarkdownParser {
    public static func blocks(_ markdown: String) -> [MarkdownBlock] {
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
            let text = styled(AttributedString(parsed[range]))
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
    /// web links stay tappable (`AgentLink`): agent output must not open a pairing link or another app.
    private static func styled(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs {
            if let inline = run.inlinePresentationIntent, inline.contains(.code) {
                text[run.range].font = .callout.monospaced()
                text[run.range].backgroundColor = Color(.tertiarySystemFill)
            }
            if let link = run.link {
                guard AgentLink.opens(link) else {
                    text[run.range].link = nil
                    continue
                }
                text[run.range].foregroundColor = .primary
                text[run.range].underlineStyle = .single
            }
        }
        return text
    }
}

